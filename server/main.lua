---------------------------------------------------------------------------
-- Server core: callbacks (rate limited, character required), per-key locks, online characters, notifications,
-- distance checks and pending deliveries for offline characters.
--
-- Security model: the client only sends WHAT the player wants (bank id, amount typed, target id). The server
-- re-checks everything on every call: character loaded, job / grade, distance to the counter, opening hours,
-- balances, limits and frozen state. Every money change of an account runs inside that account's lock and is
-- written in ONE database transaction together with its history row.
---------------------------------------------------------------------------
local RES = GetCurrentResourceName()

function Debug(fmt, ...)
    if Config.Debug then print(('[fks-banking] ' .. fmt):format(...)) end
end

function Notify(src, msg, kind)
    Bridge.Notify(src, { title = _L('bank_title'), description = msg, type = kind or 'inform' })
end

---------------------------------------------------------------------------
-- Locks: operations on the same key never run at the same time (no duplicated money on fast clicks).
-- WithLocks sorts the keys, so two operations taking the same keys can never deadlock.
---------------------------------------------------------------------------
local locks = {}

function WithLocks(keys, fn, ...)
    table.sort(keys)
    local taken = {}
    for _, key in ipairs(keys) do
        local waited = 0
        while locks[key] do
            Wait(0)
            waited = waited + 1
            if waited > 3000 then          -- a few seconds: never hang a callback
                for _, k in ipairs(taken) do locks[k] = nil end
                return false, _L('busy')
            end
        end
        locks[key] = true
        taken[#taken + 1] = key
    end
    local res = table.pack(pcall(fn, ...))
    for _, k in ipairs(taken) do locks[k] = nil end
    if not res[1] then
        print(('^1[fks-banking] %s failed: %s^0'):format(table.concat(keys, ','), tostring(res[2])))
        return false, _L('error')
    end
    return table.unpack(res, 2, res.n)
end

function WithLock(key, fn, ...) return WithLocks({ key }, fn, ...) end

function AccKey(id) return 'a' .. tostring(id) end
function VaultKey(bankId) return 'v' .. tostring(bankId) end
function CidKey(cid) return 'c' .. tostring(cid) end

---------------------------------------------------------------------------
-- Callbacks: rate limit per player per action + loaded character. fn(src, P, ...) -> ok, result...
---------------------------------------------------------------------------
local lastCall = {}
local function Limited(src, name)
    local now = GetGameTimer()
    local t = lastCall[src]
    if not t then t = {} lastCall[src] = t end
    if t[name] and now - t[name] < Config.RateLimit then return true end
    t[name] = now
    return false
end

function Callback(name, fn, opts)
    lib.callback.register('fks-banking:' .. name, function(src, ...)
        if not (opts and opts.noLimit) and Limited(src, name) then return false, _L('too_fast') end
        local P = Bridge.GetPlayer(src)
        if not P then return false, _L('no_character') end
        local res = table.pack(pcall(fn, src, P, ...))
        if not res[1] then
            print(('^1[fks-banking] callback %s failed: %s^0'):format(name, tostring(res[2])))
            return false, _L('error')
        end
        return table.unpack(res, 2, res.n)
    end)
end

function Actor(P) return { cid = tostring(P.cid), name = P.name } end

---------------------------------------------------------------------------
-- Online characters: [cid] = src (kept by character load / drop, always verified on use)
---------------------------------------------------------------------------
local online = {}

function Online(cid)
    cid = tostring(cid)
    local src = online[cid]
    if src and GetPlayerName(src) then
        local P = Bridge.GetPlayer(src)
        if P and tostring(P.cid) == cid then return src, P end
    end
    online[cid] = nil
    -- not in the map (resource restart): look it up once
    for _, id in ipairs(GetPlayers()) do
        local s = tonumber(id)
        local P = Bridge.GetPlayer(s)
        if P and tostring(P.cid) == cid then
            online[cid] = s
            return s, P
        end
    end
end

-- name of a character, online or offline (framework tables)
function CharacterName(cid)
    local _, P = Online(cid)
    if P then return P.name end
    local fw = Bridge.Framework()
    if fw == 'vorp' then
        local r = MySQL.single.await('SELECT firstname, lastname FROM characters WHERE charidentifier = ?', { tonumber(cid) or cid })
        return r and (('%s %s'):format(r.firstname or '', r.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')) or nil
    elseif fw == 'rsg' then
        local r = MySQL.single.await('SELECT charinfo FROM players WHERE citizenid = ?', { cid })
        local ci = r and r.charinfo and json.decode(r.charinfo)
        return ci and ('%s %s'):format(ci.firstname or '', ci.lastname or '') or nil
    end
end

---------------------------------------------------------------------------
-- Position checks
---------------------------------------------------------------------------
function PedCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

-- is the player at the counter of `bank`? (with Config.Interaction.serverMargin for lag)
function AtBank(src, bank)
    local pos = PedCoords(src)
    return pos ~= nil and bank ~= nil and #(pos - bank.coords) <= bank.distance + Config.Interaction.serverMargin
end

function NearPlayer(src, target, dist)
    if dist <= 0 then return true end
    local a, b = PedCoords(src), PedCoords(target)
    return a ~= nil and b ~= nil and #(a - b) <= dist
end

-- the bank of a call: exists, enabled, the player is at its counter and it is open
-- (gameHour: the client's in-game hour, only used by banks with hours.clock = 'game')
function BankFor(src, bankId, gameHour)
    local bank = Bk.Bank(bankId)
    if not bank then return nil, _L('invalid_bank') end
    if not AtBank(src, bank) then return nil, _L('too_far') end
    if not Bk.IsOpen(bank, gameHour) then return nil, _L('bank_closed') end
    return bank
end

---------------------------------------------------------------------------
-- Gold currency available? (VORP always, RSG only with Config.RSGGoldAccount)
---------------------------------------------------------------------------
function GoldAvailable()
    if not Config.GoldCurrency.Enabled then return false end
    local fw = Bridge.Framework()
    return fw == 'vorp' or (fw == 'rsg' and Config.RSGGoldAccount ~= nil)
end

---------------------------------------------------------------------------
-- Pending deliveries for characters that were offline: cash, items, notifications
---------------------------------------------------------------------------
-- notify now when online, else when they log in. args: values for the locale string
function NotifyCid(cid, key, args, kind)
    local src = Online(cid)
    if src then
        Notify(src, _L(key, table.unpack(args or {})), kind)
        return
    end
    MySQL.insert.await('INSERT INTO fks_bank_pending (cid, kind, message, args, created_at) VALUES (?, ?, ?, ?, ?)',
        { tostring(cid), 'notify', key, json.encode(args or {}), os.time() })
end

-- cash on hand now when online, else on the next login. Returns true when paid now.
function GiveCash(cid, amount, reason, noteKey, noteArgs)
    amount = Bk.Round(amount)
    if amount <= 0 then return true end
    local src, P = Online(cid)
    if P and P.add('cash', amount, reason or 'fks-banking') then
        if noteKey then Notify(src, _L(noteKey, table.unpack(noteArgs or {})), 'success') end
        return true
    end
    MySQL.insert.await('INSERT INTO fks_bank_pending (cid, kind, amount, message, args, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        { tostring(cid), 'cash', amount, noteKey, json.encode(noteArgs or {}), os.time() })
    return false
end

-- an item now when online and it fits, else on the next login
function GiveItem(cid, item, amount, noteKey, noteArgs)
    local src = Online(cid)
    if src and Bridge.CanCarry(src, item, amount) and Bridge.AddItem(src, item, amount) then
        if noteKey then Notify(src, _L(noteKey, table.unpack(noteArgs or {})), 'success') end
        return true
    end
    MySQL.insert.await('INSERT INTO fks_bank_pending (cid, kind, amount, item, message, args, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { tostring(cid), 'item', amount, item, noteKey, json.encode(noteArgs or {}), os.time() })
    return false
end

-- delivers everything waiting for this character (runs on character load)
local function DeliverPending(src, cid)
    local rows = MySQL.query.await('SELECT * FROM fks_bank_pending WHERE cid = ? ORDER BY id', { cid }) or {}
    for _, r in ipairs(rows) do
        local P = Bridge.GetPlayer(src)
        if not P or tostring(P.cid) ~= cid then return end
        local n = math.floor(tonumber(r.amount) or 0)
        local fits = r.kind ~= 'item' or (n > 0 and Bridge.CanCarry(src, r.item, n))
        if not fits then Notify(src, _L('pending_item_full', n, Bridge.ItemLabel(r.item)), 'error') end
        -- claim the row first (DELETE = 1 row): it is delivered once even if two loads race
        local claimed = fits and MySQL.update.await('DELETE FROM fks_bank_pending WHERE id = ?', { r.id }) == 1
        local done = false
        if claimed then
            if r.kind == 'notify' then
                done = true
            elseif r.kind == 'cash' then
                done = P.add('cash', Bk.Round(r.amount), 'fks-banking pending')
            elseif r.kind == 'item' then
                done = Bridge.AddItem(src, r.item, n)
            end
            if not done then   -- the framework / inventory refused it: keep it for the next login
                MySQL.insert.await('INSERT INTO fks_bank_pending (cid, kind, amount, item, message, args, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
                    { r.cid, r.kind, r.amount, r.item, r.message, r.args, r.created_at })
            end
        end
        if done then
            if r.message then
                local ok, args = pcall(json.decode, r.args or '[]')
                Notify(src, _L(r.message, table.unpack(ok and args or {})), r.kind == 'notify' and 'inform' or 'success')
            elseif r.kind == 'cash' then
                Notify(src, _L('pending_cash', Bk.Fmt(r.amount)), 'success')
            end
        end
    end
end

---------------------------------------------------------------------------
-- Character load / drop
---------------------------------------------------------------------------
local loadCbs = {}
function OnLoaded(cb) loadCbs[#loadCbs + 1] = cb end   -- cb(src, cid, P) after the pending deliveries

Bridge.OnCharacterLoaded(function(src)
    CreateThread(function()
        DB.Wait()
        Wait(2000)  -- let the framework finish loading the character
        local P = Bridge.GetPlayer(src)
        if not P then return end
        local cid = tostring(P.cid)
        for c, s in pairs(online) do if s == src and c ~= cid then online[c] = nil end end
        online[cid] = src
        DeliverPending(src, cid)
        for _, cb in ipairs(loadCbs) do
            local ok, err = pcall(cb, src, cid, P)
            if not ok then print(('^1[fks-banking] on load: %s^0'):format(tostring(err))) end
        end
    end)
end)

local dropCbs = {}
function OnDropped(cb) dropCbs[#dropCbs + 1] = cb end   -- cb(src, cid)

AddEventHandler('playerDropped', function()
    local src = source
    lastCall[src] = nil
    for cid, s in pairs(online) do
        if s == src then
            online[cid] = nil
            for _, cb in ipairs(dropCbs) do pcall(cb, src, cid) end
        end
    end
end)

-- resource restart: every character that is already in the game
CreateThread(function()
    DB.Wait()
    Wait(3000)
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local P = Bridge.GetPlayer(src)
        if P then online[tostring(P.cid)] = src end
    end
end)

---------------------------------------------------------------------------
-- Consent: asks a player to confirm something a banker started (transfer, exchange...). Blocks until the
-- player answers or `seconds` pass. Returns true only on an explicit yes from that player.
---------------------------------------------------------------------------
local consents, consentSeq = {}, 0

function AskConsent(target, title, text, seconds)
    consentSeq = consentSeq + 1
    local id = consentSeq
    local p = promise.new()
    consents[id] = { target = target, p = p }
    TriggerClientEvent('fks-banking:client:consent', target, id, title, text)
    SetTimeout((seconds or 30) * 1000, function()
        if consents[id] then consents[id] = nil p:resolve(false) end
    end)
    return Citizen.Await(p)
end

RegisterNetEvent('fks-banking:server:consent', function(id, ok)
    local src = source
    local c = consents[tonumber(id) or -1]
    if not c or c.target ~= src then return end
    consents[id] = nil
    c.p:resolve(ok == true)
end)

---------------------------------------------------------------------------
-- fks-core missing / version check
---------------------------------------------------------------------------
CreateThread(function()
    local state = GetResourceState('fks-core')
    if not Bridge or (state ~= 'started' and state ~= 'starting') then
        print('^1================================================================^0')
        print(('^1[%s] MISSING REQUIRED DEPENDENCY: fks-core^0 (%s)'):format(RES, state))
        print(('^1[%s]^0 then add ^3ensure fks-core^0 before ^3ensure %s^0 in server.cfg'):format(RES, RES))
        print('^1================================================================^0')
        return
    end
    if Config.VersionCheck.enabled then
        Bridge.CheckVersion(Config.VersionCheck.repo, { branch = Config.VersionCheck.branch, interval = Config.VersionCheck.interval })
    end
end)
