---------------------------------------------------------------------------
-- Client core: server calls, notifications, bank blips / NPCs / native prompts, consent dialogs and the shared
-- `close` / `page` handlers of the fks-core UI. Every screen is drawn by fks-core (no NUI of our own).
---------------------------------------------------------------------------
function Notify(msg, kind)
    Bridge.Notify({ title = _L('bank_title'), description = msg, type = kind or 'inform' })
end

-- server callback: ok, ... (a failed callback never throws)
function Call(name, ...)
    local res = table.pack(pcall(lib.callback.await, 'fks-banking:' .. name, false, ...))
    if not res[1] then return false, _L('error') end
    return table.unpack(res, 2, res.n)
end

-- in-game hour (banks with hours.clock = 'game')
function GameHour() return GetClockHours() end

function Fmt(n) return Bk.Fmt(n) end

-- Our own menu icons: img/icons/<name>.svg, sent to fks-core as SVG markup (it draws them like its own icons, in
-- the theme colours). Read once; a missing file falls back to the core 'box' icon.
local icons = {}
function Icon(name)
    local svg = icons[name]
    if svg == nil then
        svg = LoadResourceFile(GetCurrentResourceName(), ('img/icons/%s.svg'):format(name)) or false
        if svg then
            svg = svg:gsub('<%?xml.-%?>', '')
            svg = svg:gsub('%s+', ' ')
            svg = svg:match('^%s*(.-)%s*$')
            if svg:sub(1, 4) ~= '<svg' then svg = false end
        end
        if not svg then print(('^3[fks-banking] icon img/icons/%s.svg is missing^0'):format(name)) end
        icons[name] = svg
    end
    return svg or 'box'
end

-- result of a server call as a UI answer: error toast or success toast + optional extra fields
function Answer(ok, msg, extra)
    if not ok then return { ok = false, error = msg or _L('error') } end
    local r = extra or {}
    if msg then r.toast = { text = msg, type = 'success' } end
    return r
end

---------------------------------------------------------------------------
-- The `close` and `page` actions have one handler per script: every file adds its own
---------------------------------------------------------------------------
ActiveView = nil           -- 'bank' | 'billing' | 'mybills'
local closeCbs, pageCbs = {}, {}
function OnUIClose(cb) closeCbs[#closeCbs + 1] = cb end
function OnUIPage(cb) pageCbs[#pageCbs + 1] = cb end

UI.On('close', function(d)
    local view = ActiveView
    ActiveView = nil
    for _, cb in ipairs(closeCbs) do cb(d, view) end
end)

UI.On('page', function(d)
    for _, cb in ipairs(pageCbs) do
        local res = cb(d)
        if res then return res end
    end
end)

function OpenView(name, view, opts)
    local ok = UI.Open(view, opts)
    if ok then ActiveView = name end
    return ok
end

-- players near me: options for a `select` ({ value = server id, label = 'ID 12 · 3 m' })
function NearbyPlayers(maxDist)
    local list = {}
    local me = PlayerId()
    local pos = GetEntityCoords(PlayerPedId())
    for _, pl in ipairs(GetActivePlayers()) do
        if pl ~= me then
            local d = #(GetEntityCoords(GetPlayerPed(pl)) - pos)
            if maxDist <= 0 or d <= maxDist then
                local id = GetPlayerServerId(pl)
                list[#list + 1] = { value = tostring(id), label = _L('nearby_player', id, math.floor(d)) }
            end
        end
    end
    table.sort(list, function(a, b) return tonumber(a.value) < tonumber(b.value) end)
    return list
end

-- a select of nearby players, or a plain id input when nobody is around
function TargetField(name, label, maxDist)
    local near = NearbyPlayers(maxDist)
    if #near > 0 then
        return { type = 'dropdown', name = name, label = label, options = near, value = near[1].value }
    end
    return { type = 'input', name = name, label = label, placeholder = _L('player_id_ph'), max = 6 }
end

---------------------------------------------------------------------------
-- Consent: the server asks this player to confirm something a banker started
---------------------------------------------------------------------------
RegisterNetEvent('fks-banking:client:consent', function(id, title, text)
    CreateThread(function()
        PlaySoundFrontend('INFO', 'HUD_SHOP_SOUNDSET', true, 0)
        local ok = UI.Confirm({ title = title, text = text, ok = _L('accept'), cancel = _L('decline') })
        TriggerServerEvent('fks-banking:server:consent', id, ok == true)
    end)
end)

---------------------------------------------------------------------------
-- Native prompts (same helpers as the other FKS scripts)
---------------------------------------------------------------------------
local function Var(text) return CreateVarString(10, 'LITERAL_STRING', text) end

local group = GetRandomIntInRange(0, 0xffffff)
local openPrompt

local function MakePrompt()
    local p = PromptRegisterBegin()
    PromptSetControlAction(p, Config.OpenKey)
    PromptSetText(p, Var(_L('prompt_open')))
    PromptSetEnabled(p, false)
    PromptSetVisible(p, false)
    PromptSetStandardMode(p, true)
    PromptSetGroup(p, group, 0)
    PromptRegisterEnd(p)
    return p
end

---------------------------------------------------------------------------
-- Blips and NPCs
---------------------------------------------------------------------------
local blips, npcs = {}, {}

local function Hash(v) return type(v) == 'number' and v or joaat(v) end

local function DrawBlips()
    for _, b in ipairs(blips) do if DoesBlipExist(b) then RemoveBlip(b) end end
    blips = {}
    for _, bank in ipairs(Bk.BankList) do
        if bank.blip and bank.blip.enabled then
            local c = bank.coords
            local blip = Citizen.InvokeNative(0x554D9D53F696D002, 1664425300, c.x, c.y, c.z)   -- BlipAddForCoords
            SetBlipSprite(blip, Hash(bank.blip.sprite or 'blip_proc_bank'), true)
            Citizen.InvokeNative(0x9CB1A1623062F402, blip, bank.blip.name or bank.label)        -- SetBlipName
            blips[#blips + 1] = blip
        end
    end
end

local function LoadModel(model)
    local hash = Hash(model)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local t = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < t do Wait(10) end
    return HasModelLoaded(hash) and hash or nil
end

local function SpawnNpc(bank)
    local n = bank.npc
    local hash = LoadModel(n.model)
    if not hash then
        print(('^3[fks-banking] NPC model %s of bank %s is not valid^0'):format(tostring(n.model), bank.id))
        return nil
    end
    local c = n.coords or bank.coords
    local ped = CreatePed(hash, c.x, c.y, c.z, n.heading or 0.0, false, false, false, false)
    Citizen.InvokeNative(0x283978A15512B2FE, ped, true)                                  -- SetRandomOutfitVariation
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    TaskStandStill(ped, -1)
    SetModelAsNoLongerNeeded(hash)
    return ped
end

local function RemoveNpc(id)
    if npcs[id] and DoesEntityExist(npcs[id]) then DeleteEntity(npcs[id]) end
    npcs[id] = nil
end

---------------------------------------------------------------------------
-- Counter loop: NPCs near banks, prompt at the counter
---------------------------------------------------------------------------
local function OpenHint(bank)
    local h = bank.hours
    if not h or h.clock == 'real' then return nil end                 -- 'real' is checked by the server
    if Bk.IsOpen(bank, GameHour()) then return nil end
    return _L('prompt_closed', h.open or 0)
end

CreateThread(function()
    DrawBlips()
    openPrompt = MakePrompt()
    while true do
        local sleep = Config.Interaction.checkInterval
        local pos = GetEntityCoords(PlayerPedId())
        local here
        for _, bank in ipairs(Bk.BankList) do
            local d = #(pos - bank.coords)
            if bank.npc and bank.npc.enabled then
                if d <= Config.Interaction.nearBank and not npcs[bank.id] then npcs[bank.id] = SpawnNpc(bank)
                elseif d > Config.Interaction.nearBank + 10.0 and npcs[bank.id] then RemoveNpc(bank.id) end
            end
            if d <= bank.distance then here = bank end
            if d <= Config.Interaction.nearBank then sleep = math.min(sleep, 250) end
        end
        if here and not UI.IsOpen() and not IsEntityDead(PlayerPedId()) then
            -- every frame while at the counter
            local t = GetGameTimer() + sleep
            while GetGameTimer() < t do
                local closed = OpenHint(here)
                PromptSetText(openPrompt, Var(closed or _L('prompt_open')))
                PromptSetEnabled(openPrompt, closed == nil)
                PromptSetVisible(openPrompt, true)
                PromptSetActiveGroupThisFrame(group, Var(here.label))
                if closed == nil and PromptHasStandardModeCompleted(openPrompt) then
                    Bank.Open(here)
                    Wait(500)
                    break
                end
                Wait(0)
            end
            PromptSetVisible(openPrompt, false)
            PromptSetEnabled(openPrompt, false)
        else
            Wait(sleep)
        end
    end
end)

-- closes the panel when the player walks away from the counter
function CloseWhenAway(bank, stillOpen)
    if not Config.Interaction.closeWhenAway then return end
    CreateThread(function()
        while stillOpen() do
            if #(GetEntityCoords(PlayerPedId()) - bank.coords) > bank.distance + Config.Interaction.serverMargin + 2.0 then
                UI.Close()
                break
            end
            Wait(500)
        end
    end)
end

-- Debug only: /bankpos prints where you stand, ready to paste as a bank `coords` or `npc` line (F8 console)
if Config.Debug then
    RegisterCommand('bankpos', function()
        local ped = PlayerPedId()
        local c = GetEntityCoords(ped)
        local h = GetEntityHeading(ped)
        -- the counter uses the player's position; a clerk stands with its feet 1 m lower
        local counter = ('counter: coords = vector3(%.2f, %.2f, %.2f), heading = %.2f'):format(c.x, c.y, c.z, h)
        local clerk = ('npc: coords = vector3(%.2f, %.2f, %.2f), heading = %.2f'):format(c.x, c.y, c.z - 1.0, h)
        print('[fks-banking] ' .. counter)
        print('[fks-banking] ' .. clerk)
        Notify(clerk)
    end, false)
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, b in ipairs(blips) do if DoesBlipExist(b) then RemoveBlip(b) end end
    for id in pairs(npcs) do RemoveNpc(id) end
    if openPrompt then PromptDelete(openPrompt) end
end)
