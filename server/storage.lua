---------------------------------------------------------------------------
-- Vault boxes (section 4): one rented storage per character per bank, paid from that bank's account.
--   * renting pays the first cycle at once; the next rents are charged automatically every CycleDays;
--   * no money for the rent: the box is "overdue" (warning) for GraceDays, then "locked" (items kept) until the
--     debt is paid at the counter; DeleteAfterDays (optional) removes boxes locked for too long;
--   * frozen accounts keep their box and (ChargeRentWhileFrozen) keep paying the rent;
--   * the rent goes to the bank's vault. Uses the framework's stashes through the fks-core bridge.
---------------------------------------------------------------------------
Storage = {}

local S = Config.Storage
local DAY = 86400

local function Rent(tier, discount)
    return Bk.Round(tier.rent * (100 - math.max(0, math.min(100, tonumber(discount) or 0))) / 100)
end
Storage.Rent = Rent

local function StashId(bankId, cid) return ('fksbank_%s_%s'):format(bankId, cid) end

function Storage.Get(cid, bankId)
    return MySQL.single.await('SELECT * FROM fks_bank_storage WHERE cid = ? AND bank_id = ?', { tostring(cid), bankId })
end

function Storage.ById(id)
    return MySQL.single.await('SELECT * FROM fks_bank_storage WHERE id = ?', { tonumber(id) or -1 })
end

-- menu data
function Storage.Info(cid, bank)
    local tiers = {}
    for _, t in ipairs(S.Tiers) do tiers[#tiers + 1] = { id = t.id, space = t.space, rent = t.rent } end
    local d = { tiers = tiers, cycle = S.CycleDays, grace = S.GraceDays }
    local row = Storage.Get(cid, bank.id)
    if row then
        local tier = Bk.Tier(row.tier) or S.Tiers[1]
        d.box = {
            id = row.id, tier = tier.id, space = tier.space, rent = Rent(tier, row.discount), discount = row.discount,
            nextDue = row.next_due_at, status = row.status, debt = Bk.Round(row.debt),
            lockAt = row.status == 'overdue' and row.overdue_since and (row.overdue_since + S.GraceDays * DAY) or nil,
        }
    end
    return d
end

---------------------------------------------------------------------------
-- Rent / open / change tier / pay debt / end the rental
---------------------------------------------------------------------------
Callback('storage:rent', function(src, P, bankId, tierId, gameHour)
    if not S.Enabled then return false, _L('feature_off') end
    local acc, bank = Acc.Mine(src, P, bankId, gameHour)
    if not acc then return false, bank end
    local tier = Bk.Tier(tierId)
    if not tier then return false, _L('invalid_tier') end

    return WithLocks({ AccKey(acc.id), VaultKey(bank.id) }, function()
        if Storage.Get(P.cid, bank.id) then return false, _L('storage_exists') end
        local rent = Rent(tier, 0)
        local now = os.time()
        local extra = Vault.Q(bank.id, rent, 'rent', _L('vl_rent', P.name, _L('tier_' .. tier.id)), Actor(P))
        extra[#extra + 1] = { query = [[INSERT INTO fks_bank_storage (bank_id, cid, account_id, tier, stash_id, next_due_at, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?, 'active', ?)]], values = { bank.id, tostring(P.cid), acc.id, tier.id, StashId(bank.id, P.cid), now + S.CycleDays * DAY, now } }
        local ok, res = Acc.Apply(acc.id, 'cash', -rent, 'rent', _L('tx_rent_first', _L('tier_' .. tier.id)), Actor(P), extra)
        if not ok then return false, res end
        return true, _L('storage_rented', _L('tier_' .. tier.id), Bk.Fmt(rent))
    end)
end)

Callback('storage:open', function(src, P, bankId, gameHour)
    if not S.Enabled then return false, _L('feature_off') end
    local bank, err = BankFor(src, bankId, gameHour)
    if not bank then return false, err end
    local row = Storage.Get(P.cid, bank.id)
    if not row then return false, _L('no_storage') end
    if row.status == 'locked' then return false, _L('storage_locked', Bk.Fmt(row.debt)) end
    local tier = Bk.Tier(row.tier) or S.Tiers[1]
    Bridge.OpenStash(src, row.stash_id, _L('storage_label', bank.label), tier.space, tier.weight, tier.space)
    return true
end)

Callback('storage:tier', function(src, P, bankId, tierId, gameHour)
    if not S.Enabled then return false, _L('feature_off') end
    local acc, bank = Acc.Mine(src, P, bankId, gameHour)
    if not acc then return false, bank end
    local tier, idx = Bk.Tier(tierId)
    if not tier then return false, _L('invalid_tier') end

    return WithLocks({ AccKey(acc.id), VaultKey(bank.id) }, function()
        local row = Storage.Get(P.cid, bank.id)
        if not row then return false, _L('no_storage') end
        if row.status ~= 'active' then return false, _L('storage_pay_first') end
        local cur, curIdx = Bk.Tier(row.tier)
        cur, curIdx = cur or S.Tiers[1], curIdx or 1
        if cur.id == tier.id then return false, _L('storage_same_tier') end
        if idx < curIdx then
            -- smaller: only when the items fit
            local used = Bridge.StashUsage(row.stash_id)
            if used > tier.space then return false, _L('storage_too_full', used, tier.space) end
            MySQL.update.await('UPDATE fks_bank_storage SET tier = ? WHERE id = ?', { tier.id, row.id })
            return true, _L('storage_tier_changed', _L('tier_' .. tier.id), Bk.Fmt(Rent(tier, row.discount)))
        end
        -- bigger: pays the difference for the days left of this cycle
        local left = math.max(0, row.next_due_at - os.time()) / (S.CycleDays * DAY)
        local diff = Bk.Round((Rent(tier, row.discount) - Rent(cur, row.discount)) * left)
        local extra = { { query = 'UPDATE fks_bank_storage SET tier = ? WHERE id = ?', values = { tier.id, row.id } } }
        if diff >= 0.01 then
            for _, q in ipairs(Vault.Q(bank.id, diff, 'rent', _L('vl_rent_upgrade', P.name, _L('tier_' .. tier.id)), Actor(P))) do extra[#extra + 1] = q end
            local ok, res = Acc.Apply(acc.id, 'cash', -diff, 'rent', _L('tx_rent_upgrade', _L('tier_' .. tier.id)), Actor(P), extra)
            if not ok then return false, res end
        elseif not MySQL.transaction.await(extra) then
            return false, _L('error')
        end
        return true, _L('storage_upgraded', _L('tier_' .. tier.id), Bk.Fmt(diff))
    end)
end)

-- pays the debt of an overdue / locked box: from the account (not frozen) or with cash on hand
Callback('storage:pay', function(src, P, bankId, from, gameHour)
    if not S.Enabled then return false, _L('feature_off') end
    local bank, err = BankFor(src, bankId, gameHour)
    if not bank then return false, err end
    local row = Storage.Get(P.cid, bank.id)
    if not row or row.debt <= 0 then return false, _L('storage_no_debt') end

    return WithLocks({ AccKey(row.account_id), VaultKey(bank.id) }, function()
        row = Storage.ById(row.id)
        local debt = Bk.Round(row.debt)
        if debt <= 0 then return false, _L('storage_no_debt') end
        local extra = Vault.Q(bank.id, debt, 'rent', _L('vl_rent_debt', P.name), Actor(P))
        extra[#extra + 1] = { query = "UPDATE fks_bank_storage SET debt = 0, status = 'active', overdue_since = NULL WHERE id = ?", values = { row.id } }
        if from == 'account' then
            if IsFrozen(P.cid) then return false, _L('account_frozen') end
            local ok, res = Acc.Apply(row.account_id, 'cash', -debt, 'rent', _L('tx_rent_debt'), Actor(P), extra)
            if not ok then return false, res end
        else
            if P.money('cash') + 0.0001 < debt then return false, _L('not_enough_cash') end
            if not P.remove('cash', debt, 'fks-banking rent debt') then return false, _L('not_enough_cash') end
            if not MySQL.transaction.await(extra) then
                P.add('cash', debt, 'fks-banking rent refund')
                return false, _L('error')
            end
        end
        return true, _L('storage_debt_paid', Bk.Fmt(debt))
    end)
end)

-- ends the rental (box must be empty and without debt)
Callback('storage:cancel', function(src, P, bankId, gameHour)
    if not S.Enabled then return false, _L('feature_off') end
    local bank, err = BankFor(src, bankId, gameHour)
    if not bank then return false, err end
    local row = Storage.Get(P.cid, bank.id)
    if not row then return false, _L('no_storage') end
    if row.debt > 0 then return false, _L('storage_pay_first') end
    if Bridge.StashUsage(row.stash_id) > 0 then return false, _L('storage_not_empty') end
    MySQL.update.await('DELETE FROM fks_bank_storage WHERE id = ?', { row.id })
    Bridge.DeleteStash(row.stash_id)
    return true, _L('storage_cancelled')
end)

---------------------------------------------------------------------------
-- Rent loop: due rents, grace period, lock, cleanup and automatic settling of debts
---------------------------------------------------------------------------
local function Label(row) return Bk.BankLabel(row.bank_id) end

local function Charge(row, now)
    local tier = Bk.Tier(row.tier) or S.Tiers[1]
    local rent = Rent(tier, row.discount)
    local frozen = IsFrozen(row.cid)
    WithLocks({ AccKey(row.account_id), VaultKey(row.bank_id) }, function()
        row = Storage.ById(row.id)
        if not row or row.next_due_at > now then return end
        local acc = Acc.ById(row.account_id)
        local nextDue = row.next_due_at + S.CycleDays * DAY
        local canPay = acc and (not frozen or S.ChargeRentWhileFrozen) and (tonumber(acc.cash) or 0) + 0.0001 >= rent
        if canPay then
            local extra = Vault.Q(row.bank_id, rent, 'rent', _L('vl_rent', acc.owner_name, _L('tier_' .. tier.id)), nil)
            extra[#extra + 1] = { query = 'UPDATE fks_bank_storage SET next_due_at = ? WHERE id = ?', values = { nextDue, row.id } }
            local ok = Acc.Apply(acc.id, 'cash', -rent, 'rent', _L('tx_rent', _L('tier_' .. tier.id)), nil, extra)
            if ok then return end
        end
        -- not paid: debt grows, the box goes overdue (it locks later, in Grace())
        MySQL.update.await([[UPDATE fks_bank_storage SET debt = debt + ?, next_due_at = ?,
            status = IF(status = 'locked', 'locked', 'overdue'), overdue_since = COALESCE(overdue_since, ?) WHERE id = ?]],
            { rent, nextDue, now, row.id })
        NotifyCid(row.cid, 'storage_overdue', { Label(row), Bk.Fmt(rent), S.GraceDays }, 'error')
    end)
end

-- a debt the account can now cover is paid automatically
local function AutoSettle(row)
    if IsFrozen(row.cid) and not S.ChargeRentWhileFrozen then return end
    WithLocks({ AccKey(row.account_id), VaultKey(row.bank_id) }, function()
        row = Storage.ById(row.id)
        if not row or row.debt <= 0 then return end
        local acc = Acc.ById(row.account_id)
        local debt = Bk.Round(row.debt)
        if not acc or (tonumber(acc.cash) or 0) + 0.0001 < debt then return end
        local extra = Vault.Q(row.bank_id, debt, 'rent', _L('vl_rent_debt', acc.owner_name), nil)
        extra[#extra + 1] = { query = "UPDATE fks_bank_storage SET debt = 0, status = 'active', overdue_since = NULL WHERE id = ?", values = { row.id } }
        if Acc.Apply(acc.id, 'cash', -debt, 'rent', _L('tx_rent_debt'), nil, extra) then
            NotifyCid(row.cid, 'storage_debt_auto', { Label(row), Bk.Fmt(debt) }, 'success')
        end
    end)
end

local function Grace(row, now)
    if row.status == 'overdue' and row.overdue_since and now - row.overdue_since >= S.GraceDays * DAY then
        MySQL.update.await("UPDATE fks_bank_storage SET status = 'locked' WHERE id = ? AND status = 'overdue'", { row.id })
        NotifyCid(row.cid, 'storage_locked_notice', { Label(row), Bk.Fmt(row.debt) }, 'error')
    elseif row.status == 'locked' and S.DeleteAfterDays > 0 and row.overdue_since
        and now - row.overdue_since >= (S.GraceDays + S.DeleteAfterDays) * DAY then
        MySQL.update.await('DELETE FROM fks_bank_storage WHERE id = ?', { row.id })
        Bridge.DeleteStash(row.stash_id)
        NotifyCid(row.cid, 'storage_deleted_notice', { Label(row) }, 'error')
        Debug('storage %s deleted (abandoned)', row.id)
    end
end

CreateThread(function()
    DB.Wait()
    Wait(15000)
    while true do
        if S.Enabled then
            local now = os.time()
            for _, row in ipairs(MySQL.query.await('SELECT * FROM fks_bank_storage WHERE next_due_at <= ?', { now }) or {}) do
                Charge(row, now)
            end
            for _, row in ipairs(MySQL.query.await("SELECT * FROM fks_bank_storage WHERE status <> 'active' OR debt > 0") or {}) do
                if row.debt > 0 then AutoSettle(row) end
                local fresh = Storage.ById(row.id)
                if fresh and fresh.status ~= 'active' then Grace(fresh, now) end
            end
        end
        Wait(60000)
    end
end)
