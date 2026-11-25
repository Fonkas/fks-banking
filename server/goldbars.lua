---------------------------------------------------------------------------
-- Gold bars (section 3): an inventory item kept in an account that earns cash over time.
--
-- Earnings are computed ONLY on the server, from timestamps in the database (last_payout_at), never from client
-- timers:
--   * a loop pays the accounts of ONLINE characters every PayoutIntervalHours;
--   * on logout, offline_since is stored; on login the offline time is paid, at most MaxOfflineHours of it;
--   * before any change of the number of bars, what was earned so far is paid (new bars never earn backwards);
--   * frozen accounts earn nothing and that time is lost (last_payout_at moves on without paying);
--   * cents below $0.01 are kept in yield_fraction until they add up;
--   * DailyCapPerAccount limits what one account earns per real day.
---------------------------------------------------------------------------
GoldBars = {}

local GB = Config.GoldBars

-- what an account would earn in one payout (for the menu)
local function PerPayout(bars) return Bk.Round(bars * GB.RatePerBarPerHour * GB.PayoutIntervalHours) end

--[[
    Pays what an account earned up to `now`. MUST run inside the account lock. `login` = the owner just logged in
    (part of the time since the last payout was offline). Returns the amount credited.
]]
local function Settle(acc, now, login)
    local last = tonumber(acc.last_payout_at) or now
    local bars = tonumber(acc.bars) or 0
    local reset = { query = 'UPDATE fks_bank_accounts SET last_payout_at = ?, offline_since = NULL WHERE id = ?', values = { now, acc.id } }

    if bars <= 0 or last >= now or tonumber(acc.frozen) == 1 or IsFrozen(acc.cid) then
        MySQL.update.await(reset.query, reset.values)   -- nothing earned (or frozen: that time is lost)
        return 0
    end

    local seconds
    if login then
        local off = math.max(tonumber(acc.offline_since) or last, last)
        local onlinePart = off - last
        local offlinePart = GB.MaxOfflineHours > 0 and math.min(now - off, GB.MaxOfflineHours * 3600) or 0
        seconds = onlinePart + offlinePart
    else
        seconds = now - last
    end
    local hours = math.max(0, seconds) / 3600
    local earned = bars * GB.RatePerBarPerHour * hours

    -- daily cap: a normal payout uses what is left of today's cap; a lump (offline, > 1 day) gets cap per day
    local day = Bk.Day(now)
    local today = acc.yield_day == day and (tonumber(acc.yield_today) or 0) or 0
    if GB.DailyCapPerAccount > 0 then
        local limit = hours <= 24 and (GB.DailyCapPerAccount - today) or (GB.DailyCapPerAccount * hours / 24)
        earned = math.max(0, math.min(earned, limit))
    end
    local newToday = today + earned
    if GB.DailyCapPerAccount > 0 then newToday = math.min(newToday, GB.DailyCapPerAccount) end

    local frac = (tonumber(acc.yield_fraction) or 0) + earned
    local credit = math.floor(frac * 100 + 1e-7) / 100
    frac = frac - credit

    local queries = {
        { query = [[UPDATE fks_bank_accounts SET last_payout_at = ?, offline_since = NULL, yield_fraction = ?,
            yield_day = ?, yield_today = ? WHERE id = ?]], values = { now, frac, day, newToday, acc.id } },
    }
    if credit >= 0.01 then
        local after = Bk.Round((tonumber(acc.cash) or 0) + credit)
        queries[#queries + 1] = { query = 'UPDATE fks_bank_accounts SET cash = ? WHERE id = ?', values = { after, acc.id } }
        queries[#queries + 1] = DB.TxQuery(acc, 'yield', 'cash', credit, after, _L('tx_yield', bars, Bk.Span(seconds)), nil)
        acc.cash = after
    end
    if not MySQL.transaction.await(queries) then return 0 end
    acc.last_payout_at, acc.yield_fraction, acc.yield_day, acc.yield_today = now, frac, day, newToday
    Debug('bars account %s: %d bars, %.2f h -> +%.2f (fraction %.6f)', acc.id, bars, hours, credit, frac)
    return credit >= 0.01 and credit or 0
end
GoldBars.Settle = Settle

-- settle inside the lock (used before every bars change and by the loops)
function GoldBars.SettleId(id, login)
    return WithLock(AccKey(id), function()
        local acc = Acc.ById(id)
        if not acc then return 0 end
        return Settle(acc, os.time(), login)
    end)
end

-- menu data
function GoldBars.Info(src, acc)
    local bars = acc and tonumber(acc.bars) or 0
    local last = acc and tonumber(acc.last_payout_at) or os.time()
    local day = Bk.Day()
    return {
        item = GB.Item, label = Bridge.ItemLabel(GB.Item), onHand = Bridge.ItemCount(src, GB.Item),
        max = GB.MaxPerAccount, rate = GB.RatePerBarPerHour, interval = GB.PayoutIntervalHours, cap = GB.DailyCapPerAccount,
        perPayout = PerPayout(bars), perDay = Bk.Round(math.min(bars * GB.RatePerBarPerHour * 24, GB.DailyCapPerAccount > 0 and GB.DailyCapPerAccount or math.huge)),
        nextIn = bars > 0 and math.max(0, last + math.floor(GB.PayoutIntervalHours * 3600) - os.time()) or nil,
        today = acc and acc.yield_day == day and Bk.Round(acc.yield_today) or 0,
        banks = Bk.BankCount(), offlineHours = GB.MaxOfflineHours,
    }
end

---------------------------------------------------------------------------
-- Deposit / withdraw bars
---------------------------------------------------------------------------
Callback('bars:deposit', function(src, P, bankId, value, gameHour)
    if not GB.Enabled then return false, _L('feature_off') end
    local acc, bank = Acc.Mine(src, P, bankId, gameHour)
    if not acc then return false, bank end
    local n = Bk.Int(value, GB.MaxPerAccount)
    if not n then return false, _L('invalid_amount') end

    return WithLock(AccKey(acc.id), function()
        acc = Acc.ById(acc.id)
        if (tonumber(acc.bars) or 0) + n > GB.MaxPerAccount then
            return false, _L('bars_max', GB.MaxPerAccount, math.max(0, GB.MaxPerAccount - acc.bars))
        end
        if Bridge.ItemCount(src, GB.Item) < n then return false, _L('not_enough_bars_item') end
        Settle(acc, os.time(), false)                      -- earnings so far, at the old number of bars
        if not Bridge.RemoveItem(src, GB.Item, n) then return false, _L('not_enough_bars_item') end
        local ok, res = Acc.Apply(acc.id, 'bars', n, 'bars_in', _L('tx_bars_in', n), Actor(P))
        if not ok then
            Bridge.AddItem(src, GB.Item, n)                -- nothing was written: give them back
            return false, res
        end
        return true, _L('bars_deposited', n, bank.label)
    end)
end)

Callback('bars:withdraw', function(src, P, bankId, value, gameHour)
    if not GB.Enabled then return false, _L('feature_off') end
    local acc, bank = Acc.Mine(src, P, bankId, gameHour)
    if not acc then return false, bank end
    local n = Bk.Int(value, GB.MaxPerAccount)
    if not n then return false, _L('invalid_amount') end

    return WithLock(AccKey(acc.id), function()
        acc = Acc.ById(acc.id)
        local free = (tonumber(acc.bars) or 0) - (tonumber(acc.bars_locked) or 0)
        if n > free then return false, free < (tonumber(acc.bars) or 0) and _L('bars_locked_err') or _L('account_no_bars') end
        if not Bridge.CanCarry(src, GB.Item, n) then return false, _L('inventory_full') end
        Settle(acc, os.time(), false)
        local ok, res = Acc.Apply(acc.id, 'bars', -n, 'bars_out', _L('tx_bars_out', n), Actor(P))
        if not ok then return false, res end
        if not Bridge.AddItem(src, GB.Item, n) then
            Acc.Apply(acc.id, 'bars', n, 'refund', _L('tx_withdraw_failed'), nil)
            return false, _L('inventory_full')
        end
        return true, _L('bars_withdrew', n)
    end)
end)

---------------------------------------------------------------------------
-- Loops: online payouts every interval; offline time on login; logout time stored
---------------------------------------------------------------------------
local function OnlineCids()
    local list = {}
    for _, id in ipairs(GetPlayers()) do
        local P = Bridge.GetPlayer(tonumber(id))
        if P then list[#list + 1] = tostring(P.cid) end
    end
    return list
end

CreateThread(function()
    DB.Wait()
    Wait(10000)
    while true do
        if GB.Enabled then
            local cids = OnlineCids()
            if #cids > 0 then
                local due = os.time() - math.floor(GB.PayoutIntervalHours * 3600)
                local rows = MySQL.query.await(('SELECT id FROM fks_bank_accounts WHERE bars > 0 AND (last_payout_at IS NULL OR last_payout_at <= ?) AND cid IN (%s)')
                    :format(('?,'):rep(#cids):sub(1, -2)), { due, table.unpack(cids) }) or {}
                for _, r in ipairs(rows) do
                    local credit = GoldBars.SettleId(r.id, false)
                    if credit and credit > 0 and GB.NotifyPayout then
                        local acc = Acc.ById(r.id)
                        local src = acc and Online(acc.cid)
                        if src then Notify(src, _L('bars_payout', Bk.Fmt(credit), Bk.BankLabel(acc.bank_id)), 'success') end
                    end
                end
            end
        end
        Wait(GB.CheckEverySeconds * 1000)
    end
end)

OnLoaded(function(src, cid)
    if not GB.Enabled then return end
    local total = 0
    for _, r in ipairs(MySQL.query.await('SELECT id FROM fks_bank_accounts WHERE cid = ? AND bars > 0', { cid }) or {}) do
        total = total + (GoldBars.SettleId(r.id, true) or 0)
    end
    if total > 0 then Notify(src, _L('bars_offline_payout', Bk.Fmt(total)), 'success') end
end)

OnDropped(function(_, cid)
    MySQL.update('UPDATE fks_bank_accounts SET offline_since = ? WHERE cid = ? AND bars > 0 AND offline_since IS NULL', { os.time(), cid })
end)
