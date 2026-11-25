---------------------------------------------------------------------------
-- Loans (section 5.2)
--   1. a banker proposes: client, amount, interest, installments, interval, collateral;
--   2. the client sees it in the bank menu and signs with their character's name;
--   3. only then the money leaves the vault into the client's account in that bank;
--   4. installments are taken automatically from that account (also when frozen) and go back to the vault;
--   5. MissedPaymentsToDefault missed installments in a row = default: the collateral is executed (bars / item to
--      the vault) and what is still missing becomes a bank debt bill, visible to the government (section 7);
--   6. fully repaid: collateral released and the banker gets the commission (from the vault).
---------------------------------------------------------------------------
Loans = {}

local L = Config.Loans
local HOUR = 3600

local function Row(r)
    return {
        id = r.id, bank = r.bank_id, bankLabel = Bk.BankLabel(r.bank_id), client = r.client_name, cid = r.cid,
        banker = r.banker_name, principal = Bk.Round(r.principal), interest = tonumber(r.interest) or 0,
        total = Bk.Round(r.total_due), installments = r.installments, installment = Bk.Round(r.installment_amount),
        interval = r.interval_hours, collateral = r.collateral_type, bars = r.collateral_bars,
        item = r.collateral_item, itemLabel = r.collateral_item and Bridge.ItemLabel(r.collateral_item) or nil,
        itemAmount = r.collateral_amount, collateralValue = Bk.Round(r.collateral_value), status = r.status,
        paid = Bk.Round(r.paid_amount), paidInstallments = r.paid_installments, missed = r.missed,
        nextDue = r.next_due_at, expires = r.expires_at, signedName = r.signed_name, signedAt = r.signed_at,
        created = r.created_at, closed = r.closed_at,
    }
end
Loans.Row = Row

function Loans.ById(id)
    return MySQL.single.await('SELECT * FROM fks_bank_loans WHERE id = ?', { tonumber(id) or -1 })
end

-- loans of a client in a bank: open ones + the last closed ones
function Loans.ForClient(cid, bankId)
    local rows = MySQL.query.await([[SELECT * FROM fks_bank_loans WHERE cid = ? AND bank_id = ?
        ORDER BY FIELD(status, 'proposed', 'active', 'defaulted') DESC, id DESC LIMIT 20]], { tostring(cid), bankId }) or {}
    local list = {}
    for _, r in ipairs(rows) do list[#list + 1] = Row(r) end
    return list
end

function Loans.ForBank(bankId)
    local rows = MySQL.query.await([[SELECT * FROM fks_bank_loans WHERE bank_id = ? ORDER BY id DESC LIMIT 200]], { bankId }) or {}
    local list = {}
    for _, r in ipairs(rows) do list[#list + 1] = Row(r) end
    return list
end

local function ActiveCount(cid)
    return tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM fks_bank_loans WHERE cid = ? AND status IN ('proposed', 'active')", { tostring(cid) })) or 0
end

---------------------------------------------------------------------------
-- Proposal (banker, or the client in automatic mode)
--   o = { target (server id), amount, interest, installments, interval, collateral = 'none'|'bars'|'item',
--         bars, item, itemAmount, itemValue }
---------------------------------------------------------------------------
function Loans.Propose(src, P, bank, o, auto)
    if not L.Enabled then return false, _L('feature_off') end
    local banker = not auto and Banker.Info(P, bank)
    if not auto and not (banker and banker.perms.loans) then return false, _L('no_permission') end

    local target = tonumber(o.target)
    local T = target and Bridge.GetPlayer(target)
    if auto then target, T = src, P end
    if not T then return false, _L('player_offline') end
    if not auto and target == src then return false, _L('not_yourself') end
    if not auto and not NearPlayer(src, target, Config.Banker.ClientDistance) then return false, _L('target_far') end

    local amount = Bk.Money(o.amount)
    if not amount or amount < L.MinAmount or amount > L.MaxAmount then return false, _L('loan_amount_range', Bk.Fmt(L.MinAmount), Bk.Fmt(L.MaxAmount)) end
    if banker and banker.maxLoan and amount > banker.maxLoan then return false, _L('loan_rank_max', Bk.Fmt(banker.maxLoan)) end
    local interest = tonumber(o.interest)
    if not interest or interest ~= interest then return false, _L('invalid_amount') end
    interest = math.floor(interest * 100 + 0.5) / 100
    local kind = o.collateral
    if kind ~= 'none' and kind ~= 'bars' and kind ~= 'item' then return false, _L('invalid_collateral') end
    if not L.Collateral[kind] then return false, _L('invalid_collateral') end
    local minInterest = kind == 'none' and math.max(L.MinInterest, L.MinInterestNoCollateral) or L.MinInterest
    if interest < minInterest or interest > L.MaxInterest then return false, _L('loan_interest_range', minInterest, L.MaxInterest) end
    local n = Bk.Int(o.installments, L.MaxInstallments)
    if not n or n < L.MinInstallments then return false, _L('loan_installments_range', L.MinInstallments, L.MaxInstallments) end
    local interval = tonumber(o.interval)
    local okInterval = false
    for _, h in ipairs(L.IntervalOptions) do if h == interval then okInterval = true end end
    if not okInterval then return false, _L('invalid_interval') end

    local cid = tostring(T.cid)
    if IsFrozen(cid) then return false, _L('client_frozen') end
    local acc = Acc.Get(cid, bank.id)
    if not acc then return false, _L('client_no_account') end
    if ActiveCount(cid) >= L.MaxActivePerClient then return false, _L('loan_max_active', L.MaxActivePerClient) end

    local bars, item, itemAmount, value = 0, nil, 0, 0
    if kind == 'bars' then
        bars = Bk.Int(o.bars, Config.GoldBars.MaxPerAccount)
        if not bars or not Config.GoldBars.Enabled then return false, _L('invalid_collateral') end
        if (tonumber(acc.bars) or 0) - (tonumber(acc.bars_locked) or 0) < bars then return false, _L('client_not_enough_bars') end
        value = Bk.Round(bars * Config.GoldExchange.BuyPrice)
    elseif kind == 'item' then
        item = Bk.Text(o.item, 60)
        itemAmount = Bk.Int(o.itemAmount, 10000)
        if not item or not itemAmount or not Bridge.ItemExists(item) then return false, _L('invalid_item') end
        if item == Config.GoldBars.Item then return false, _L('item_use_bars') end
        if Bridge.ItemCount(target, item) < itemAmount then return false, _L('client_no_item') end
        value = Bk.Money(o.itemValue, true) or 0
    end

    local total = Bk.Round(amount * (1 + interest / 100))
    local installment = Bk.Round(math.ceil(total / n * 100) / 100)
    local now = os.time()
    local id = MySQL.insert.await([[INSERT INTO fks_bank_loans
        (bank_id, cid, client_name, account_id, banker_cid, banker_name, principal, interest, total_due, installments,
         installment_amount, interval_hours, collateral_type, collateral_bars, collateral_item, collateral_amount,
         collateral_value, status, expires_at, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'proposed', ?, ?)]], {
        bank.id, cid, T.name, acc.id, (not auto) and tostring(P.cid) or nil, (not auto) and P.name or nil, amount, interest, total, n,
        installment, interval, kind, bars, item, itemAmount, value, now + L.ProposalMinutes * 60, now,
    })
    if not id then return false, _L('error') end
    if not auto then Notify(target, _L('loan_proposed_client', Bk.Fmt(amount), bank.label), 'inform') end
    Webhook('Banker', _L('wh_loan_proposed'), _L('wh_loan_proposed_text', auto and _L('auto_mode') or P.name, T.name, Bk.Fmt(amount), bank.label),
        { { _L('wh_interest'), interest .. '%' }, { _L('wh_installments'), ('%d x %s / %dh'):format(n, Bk.Fmt(installment), interval) }, { _L('wh_collateral'), _L('collateral_' .. kind) } })
    return true, auto and _L('loan_proposed_self') or _L('loan_proposed', T.name), id
end

---------------------------------------------------------------------------
-- Signing (the client, at the counter of that bank)
---------------------------------------------------------------------------
local function SignedName(P)
    local name = ('%s %s'):format(P.firstname or '', P.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    return name ~= '' and name or P.name
end
Loans.SignedName = SignedName

Callback('loan:sign', function(src, P, loanId, gameHour)
    if not L.Enabled then return false, _L('feature_off') end
    local loan = Loans.ById(loanId)
    if not loan or loan.cid ~= tostring(P.cid) or loan.status ~= 'proposed' then return false, _L('loan_invalid') end
    local bank, err = BankFor(src, loan.bank_id, gameHour)
    if not bank then return false, err end
    if IsFrozen(P.cid) then return false, _L('account_frozen') end

    return WithLocks({ AccKey(loan.account_id), VaultKey(loan.bank_id), 'l' .. loan.id }, function()
        loan = Loans.ById(loan.id)
        if loan.status ~= 'proposed' then return false, _L('loan_invalid') end
        local now = os.time()
        if loan.expires_at and now > loan.expires_at then
            MySQL.update.await("UPDATE fks_bank_loans SET status = 'expired', closed_at = ? WHERE id = ?", { now, loan.id })
            return false, _L('loan_expired')
        end
        local acc = Acc.ById(loan.account_id)
        if not acc then return false, _L('no_account') end
        local signed = SignedName(P)

        -- collateral
        local extra = {}
        if loan.collateral_type == 'bars' then
            if (tonumber(acc.bars) or 0) - (tonumber(acc.bars_locked) or 0) < loan.collateral_bars then return false, _L('client_not_enough_bars') end
            extra[#extra + 1] = { query = 'UPDATE fks_bank_accounts SET bars_locked = bars_locked + ? WHERE id = ?', values = { loan.collateral_bars, acc.id } }
        end
        local vq, verr = Vault.Q(loan.bank_id, -loan.principal, 'loan', _L('vl_loan', loan.id, loan.client_name), loan.banker_cid and { cid = loan.banker_cid, name = loan.banker_name } or nil)
        if not vq then return false, _L('loan_vault_empty') end
        for _, q in ipairs(vq) do extra[#extra + 1] = q end
        extra[#extra + 1] = { query = [[UPDATE fks_bank_loans SET status = 'active', signed_name = ?, signed_at = ?, next_due_at = ?, expires_at = NULL
            WHERE id = ? AND status = 'proposed']], values = { signed, now, now + loan.interval_hours * HOUR, loan.id } }

        local tookItem = false
        if loan.collateral_type == 'item' then
            if Bridge.ItemCount(src, loan.collateral_item) < loan.collateral_amount then return false, _L('client_no_item') end
            if not Bridge.RemoveItem(src, loan.collateral_item, loan.collateral_amount) then return false, _L('client_no_item') end
            tookItem = true
            extra[#extra + 1] = { query = [[INSERT INTO fks_bank_vault_items (bank_id, item, amount, loan_id, owner_cid, status, created_at)
                VALUES (?, ?, ?, ?, ?, 'held', ?)]], values = { loan.bank_id, loan.collateral_item, loan.collateral_amount, loan.id, loan.cid, now } }
        end

        local ok, res = Acc.Apply(acc.id, 'cash', loan.principal, 'loan', _L('tx_loan', loan.id), nil, extra)
        if not ok then
            if tookItem then Bridge.AddItem(src, loan.collateral_item, loan.collateral_amount) end
            return false, res
        end
        if loan.banker_cid then NotifyCid(loan.banker_cid, 'loan_signed_banker', { loan.client_name, Bk.Fmt(loan.principal) }, 'success') end
        Webhook('Banker', _L('wh_loan_signed'), _L('wh_loan_signed_text', signed, loan.id, Bk.Fmt(loan.principal), bank.label))
        return true, _L('loan_signed', Bk.Fmt(loan.principal)), signed
    end)
end)

Callback('loan:decline', function(src, P, loanId)
    local loan = Loans.ById(loanId)
    if not loan or loan.cid ~= tostring(P.cid) or loan.status ~= 'proposed' then return false, _L('loan_invalid') end
    MySQL.update.await("UPDATE fks_bank_loans SET status = 'declined', closed_at = ? WHERE id = ? AND status = 'proposed'", { os.time(), loan.id })
    if loan.banker_cid then NotifyCid(loan.banker_cid, 'loan_declined_banker', { loan.client_name }, 'error') end
    return true, _L('loan_declined')
end)

-- the banker cancels a proposal not signed yet
function Loans.Cancel(P, bank, loanId)
    local loan = Loans.ById(loanId)
    if not loan or loan.bank_id ~= bank.id or loan.status ~= 'proposed' then return false, _L('loan_invalid') end
    MySQL.update.await("UPDATE fks_bank_loans SET status = 'declined', closed_at = ? WHERE id = ? AND status = 'proposed'", { os.time(), loan.id })
    NotifyCid(loan.cid, 'loan_cancelled_client', { bank.label }, 'inform')
    return true, _L('loan_cancelled')
end

---------------------------------------------------------------------------
-- Installments, full payment, default
---------------------------------------------------------------------------
local function Close(loan, now)
    -- collateral back
    if loan.collateral_type == 'bars' and loan.collateral_bars > 0 then
        MySQL.update.await('UPDATE fks_bank_accounts SET bars_locked = GREATEST(bars_locked - ?, 0) WHERE id = ?', { loan.collateral_bars, loan.account_id })
    elseif loan.collateral_type == 'item' then
        local n = MySQL.update.await("DELETE FROM fks_bank_vault_items WHERE loan_id = ? AND status = 'held'", { loan.id })
        if n and n > 0 then GiveItem(loan.cid, loan.collateral_item, loan.collateral_amount, 'loan_item_back', { loan.collateral_amount, Bridge.ItemLabel(loan.collateral_item) }) end
    end
    NotifyCid(loan.cid, 'loan_paid_off', { loan.id, Bk.BankLabel(loan.bank_id) }, 'success')
    -- commission for the banker (from the vault)
    if loan.banker_cid and L.CommissionPercent > 0 then
        local base = L.CommissionBase == 'principal' and loan.principal or (loan.total_due - loan.principal)
        local fee = Bk.Round(base * L.CommissionPercent / 100)
        if fee >= 0.01 then
            local ok = Vault.Apply(loan.bank_id, -fee, 'commission', _L('vl_commission', loan.banker_name, loan.id), { cid = loan.banker_cid, name = loan.banker_name })
            if ok then GiveCash(loan.banker_cid, fee, 'fks-banking commission', 'commission_paid', { Bk.Fmt(fee), loan.id })
            else NotifyCid(loan.banker_cid, 'commission_no_funds', { loan.id }, 'error') end
        end
    end
    Webhook('Banker', _L('wh_loan_paid'), _L('wh_loan_paid_text', loan.client_name, loan.id, Bk.Fmt(loan.total_due), Bk.BankLabel(loan.bank_id)))
end

local function Default(loan, now)
    local bankLabel = Bk.BankLabel(loan.bank_id)
    MySQL.update.await("UPDATE fks_bank_loans SET status = 'defaulted', closed_at = ? WHERE id = ?", { now, loan.id })
    -- execute the collateral
    if loan.collateral_type == 'bars' and loan.collateral_bars > 0 then
        WithLocks({ AccKey(loan.account_id), VaultKey(loan.bank_id) }, function()
            local acc = Acc.ById(loan.account_id)
            if not acc then return end
            GoldBars.Settle(acc, now, false)          -- pay what they earned up to now, then take them
            local n = math.min(loan.collateral_bars, tonumber(acc.bars) or 0)
            -- unlock first so the bars can leave the account (we hold the account lock)
            MySQL.update.await('UPDATE fks_bank_accounts SET bars_locked = GREATEST(bars_locked - ?, 0) WHERE id = ?', { loan.collateral_bars, acc.id })
            if n > 0 then
                local extra = Vault.Q(loan.bank_id, 0, 'seized', _L('vl_seized_bars', n, loan.id), nil, n)
                Acc.Apply(acc.id, 'bars', -n, 'seized', _L('tx_seized_bars', n, loan.id), nil, extra)
            end
        end)
    elseif loan.collateral_type == 'item' then
        MySQL.update.await("UPDATE fks_bank_vault_items SET status = 'stock', owner_cid = NULL WHERE loan_id = ? AND status = 'held'", { loan.id })
    end
    local missing = Bk.Round(loan.total_due - loan.paid_amount - loan.collateral_value)
    local billId
    if missing >= 0.01 then
        billId = Bills.CreateBankDebt(loan, missing)
        MySQL.update.await('UPDATE fks_bank_loans SET debt_bill_id = ? WHERE id = ?', { billId, loan.id })
    end
    NotifyCid(loan.cid, missing >= 0.01 and 'loan_defaulted_debt' or 'loan_defaulted', { loan.id, bankLabel, Bk.Fmt(missing) }, 'error')
    if loan.banker_cid then NotifyCid(loan.banker_cid, 'loan_defaulted_banker', { loan.client_name, loan.id }, 'error') end
    Webhook('Banker', _L('wh_loan_default'), _L('wh_loan_default_text', loan.client_name, loan.id, bankLabel, Bk.Fmt(missing)))
end

local function Installment(loan, now)
    WithLocks({ AccKey(loan.account_id), VaultKey(loan.bank_id), 'l' .. loan.id }, function()
        loan = Loans.ById(loan.id)
        if not loan or loan.status ~= 'active' or (loan.next_due_at or 0) > now then return end
        local due = Bk.Round(math.min(loan.installment_amount, loan.total_due - loan.paid_amount))
        local acc = Acc.ById(loan.account_id)
        local nextDue = loan.next_due_at + loan.interval_hours * HOUR
        if acc and due > 0 and (tonumber(acc.cash) or 0) + 0.0001 >= due then
            local paid = Bk.Round(loan.paid_amount + due)
            local extra = Vault.Q(loan.bank_id, due, 'installment', _L('vl_installment', loan.id, loan.client_name), nil)
            local done = paid + 0.0001 >= loan.total_due
            extra[#extra + 1] = { query = [[UPDATE fks_bank_loans SET paid_amount = ?, paid_installments = paid_installments + 1, missed = 0,
                next_due_at = ?, status = ?, closed_at = IF(status = 'paid', ?, closed_at) WHERE id = ?]],
                values = { paid, nextDue, done and 'paid' or 'active', now, loan.id } }
            local ok = Acc.Apply(acc.id, 'cash', -due, 'installment', _L('tx_installment', loan.paid_installments + 1, loan.installments, loan.id), nil, extra)
            if ok then
                if paid + 0.0001 >= loan.total_due then
                    loan.paid_amount = paid
                    SetTimeout(0, function() Close(loan, now) end)
                end
                return
            end
        end
        local missed = loan.missed + 1
        MySQL.update.await('UPDATE fks_bank_loans SET missed = ?, next_due_at = ? WHERE id = ?', { missed, nextDue, loan.id })
        if missed >= L.MissedPaymentsToDefault then
            loan.missed = missed
            SetTimeout(0, function() Default(loan, now) end)
        else
            NotifyCid(loan.cid, 'loan_missed', { loan.id, Bk.BankLabel(loan.bank_id), missed, L.MissedPaymentsToDefault }, 'error')
        end
    end)
end

CreateThread(function()
    DB.Wait()
    Wait(20000)
    while true do
        if L.Enabled then
            local now = os.time()
            MySQL.update.await("UPDATE fks_bank_loans SET status = 'expired', closed_at = ? WHERE status = 'proposed' AND expires_at < ?", { now, now })
            for _, loan in ipairs(MySQL.query.await("SELECT * FROM fks_bank_loans WHERE status = 'active' AND next_due_at <= ?", { now }) or {}) do
                Installment(loan, now)
            end
        end
        Wait(60000)
    end
end)
