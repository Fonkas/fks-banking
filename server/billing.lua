---------------------------------------------------------------------------
-- Bills (section 6): /billing writes them, /mybills signs and pays them.
--   unsigned --sign--> unpaid --pay--> paid          unsigned --refuse--> refused          any --government--> deleted
--   * signing stores the character's first and last name with the date (shown as a handwritten signature);
--   * a signed bill can no longer be refused; it stays unpaid until paid;
--   * payment: the full amount in cash on hand (or from a bank account with AllowBankPayment, never frozen);
--   * company bills pay the company through fks-companies; personal bills pay the writer (cash or bank);
--     bank debt bills (defaulted loans, section 5.2) pay the vault of that bank.
---------------------------------------------------------------------------
Bills = {}

local BC = Config.Billing
local COMPANIES = 'fks-companies'

function Bills.Number(id) return ('#%05d'):format(tonumber(id) or 0) end

function Bills.ById(id)
    return MySQL.single.await('SELECT * FROM fks_bills WHERE id = ?', { tonumber(id) or -1 })
end

-- is fks-companies running with Config.FKS_Banking = true?
local warned = false
function Bills.CompaniesLinked()
    if GetResourceState(COMPANIES) ~= 'started' then return false end
    local ok, on = pcall(function() return exports[COMPANIES]:BankingEnabled() end)
    return ok and on == true
end

CreateThread(function()
    Wait(15000)
    if BC.Enabled and next(BC.CompanyJobs) and not Bills.CompaniesLinked() and not warned then
        warned = true
        print(('^3[fks-banking] company bills are off: %s is not running or its Config.FKS_Banking is false^0'):format(COMPANIES))
    end
end)

-- the company a player can bill for: { label } | nil
local function CompanyOf(P)
    if not Bk.JobGrade(BC.CompanyJobs, P.job, P.grade) or not Bills.CompaniesLinked() then return nil end
    local ok, c = pcall(function() return exports[COMPANIES]:GetCompanyByJob(P.job) end)
    if not ok or type(c) ~= 'table' then return nil end
    return { label = c.name or P.jobLabel or P.job, job = P.job }
end

function Bills.Row(r, online)
    local now = os.time()
    return {
        id = r.id, number = Bills.Number(r.id), kind = r.kind, issuer = r.issuer_name, issuerCid = r.issuer_cid,
        issuerLabel = r.issuer_label, job = r.issuer_job, target = r.target_name, targetCid = r.target_cid,
        amount = Bk.Round(r.amount), reason = r.reason, status = r.status, signedName = r.signed_name,
        signedAt = r.signed_at, paidAt = r.paid_at, paidVia = r.paid_via, created = r.created_at,
        daysUnpaid = r.status == 'unpaid' and r.signed_at and math.floor((now - r.signed_at) / 86400) or nil,
        targetSrc = online and online[r.target_cid] or nil, issuerSrc = online and r.issuer_cid and online[r.issuer_cid] or nil,
    }
end

-- generic creation (also used by the exports). o = { kind, issuerCid, issuerName, issuerJob, issuerLabel, bankId,
-- loanId, targetCid, targetName, amount, reason }. Returns the bill id.
function Bills.Create(o)
    local id = MySQL.insert.await([[INSERT INTO fks_bills (kind, issuer_cid, issuer_name, issuer_job, issuer_label, bank_id, loan_id,
        target_cid, target_name, amount, reason, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'unsigned', ?)]], {
        o.kind, o.issuerCid, o.issuerName, o.issuerJob, o.issuerLabel, o.bankId, o.loanId,
        tostring(o.targetCid), o.targetName, Bk.Round(o.amount), o.reason, os.time(),
    })
    if id then
        NotifyCid(o.targetCid, 'bill_received', { Bills.Number(id), o.issuerLabel or o.issuerName, Bk.Fmt(o.amount), BC.MyBillsCommand }, 'inform')
        Webhook('Bills', _L('wh_bill_new'), _L('wh_bill_new_text', Bills.Number(id), o.issuerLabel or o.issuerName, o.targetName, Bk.Fmt(o.amount)),
            { { _L('wh_reason'), o.reason or '-' } })
        TriggerEvent('fks-banking:server:billCreated', id, o.kind, o.targetCid, o.amount)
    end
    return id
end

-- the debt of a defaulted loan: an already signed (the loan agreement) bill from the bank, unpaid
function Bills.CreateBankDebt(loan, amount)
    local label = _L('bank_issuer', Bk.BankLabel(loan.bank_id))
    local id = Bills.Create({
        kind = 'bank', issuerName = label, issuerLabel = label, bankId = loan.bank_id, loanId = loan.id,
        targetCid = loan.cid, targetName = loan.client_name, amount = amount, reason = _L('bank_debt_reason', loan.id),
    })
    if id then
        MySQL.update.await("UPDATE fks_bills SET status = 'unpaid', signed_name = ?, signed_at = ? WHERE id = ?",
            { loan.signed_name or loan.client_name, loan.signed_at or os.time(), id })
    end
    return id
end

---------------------------------------------------------------------------
-- /billing
---------------------------------------------------------------------------
local function IsGov(P) return Config.Government.Enabled and Bk.JobGrade(Config.Government.Jobs, P.job, P.grade) end
Bills.IsGov = IsGov

Callback('bill:meta', function(src, P)
    if not BC.Enabled then return false, _L('feature_off') end
    local company = CompanyOf(P)
    return true, {
        company = company and company.label or false, gov = IsGov(P), name = P.name,
        min = BC.MinAmount, max = BC.MaxAmount, reasonMax = BC.ReasonMax, maxDistance = BC.MaxDistance,
    }
end, { noLimit = true })

local lastBill = {}

Callback('bill:create', function(src, P, kind, target, value, reason)
    if not BC.Enabled then return false, _L('feature_off') end
    if lastBill[src] and os.time() - lastBill[src] < BC.Cooldown then return false, _L('bill_cooldown', BC.Cooldown) end
    if kind ~= 'personal' and kind ~= 'company' then return false, _L('error') end
    local company
    if kind == 'company' then
        company = CompanyOf(P)
        if not company then return false, _L('no_permission') end
    end
    target = tonumber(target)
    if not target or target == src or not GetPlayerName(target) then return false, _L('invalid_target') end
    local T = Bridge.GetPlayer(target)
    if not T then return false, _L('player_offline') end
    if not NearPlayer(src, target, BC.MaxDistance) then return false, _L('target_far') end
    local amount = Bk.Money(value)
    if not amount or amount < BC.MinAmount or amount > BC.MaxAmount then return false, _L('bill_amount_range', Bk.Fmt(BC.MinAmount), Bk.Fmt(BC.MaxAmount)) end
    local text = Bk.Text(reason, BC.ReasonMax, 2)
    if not text then return false, _L('bill_reason_required') end
    local open = tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM fks_bills WHERE target_cid = ? AND status = 'unsigned'", { tostring(T.cid) })) or 0
    if open >= BC.MaxUnsignedPerTarget then return false, _L('bill_target_full') end

    lastBill[src] = os.time()
    local id = Bills.Create({
        kind = kind, issuerCid = tostring(P.cid), issuerName = P.name, issuerJob = company and company.job or nil,
        issuerLabel = company and company.label or nil, targetCid = tostring(T.cid), targetName = T.name, amount = amount, reason = text,
    })
    if not id then return false, _L('error') end
    return true, _L('bill_sent', Bills.Number(id), T.name, Bk.Fmt(amount))
end)

AddEventHandler('playerDropped', function() lastBill[source] = nil end)

---------------------------------------------------------------------------
-- /mybills
---------------------------------------------------------------------------
Callback('bill:mine', function(src, P)
    if not BC.Enabled then return false, _L('feature_off') end
    local cid = tostring(P.cid)
    local d = { toSign = {}, toPay = {}, history = {}, issued = {}, cash = Bk.Round(P.money('cash')), accounts = false }
    for _, r in ipairs(MySQL.query.await("SELECT * FROM fks_bills WHERE target_cid = ? AND status IN ('unsigned', 'unpaid') ORDER BY id DESC", { cid }) or {}) do
        local row = Bills.Row(r)
        if r.status == 'unsigned' then d.toSign[#d.toSign + 1] = row else d.toPay[#d.toPay + 1] = row end
    end
    for _, r in ipairs(MySQL.query.await("SELECT * FROM fks_bills WHERE target_cid = ? AND status IN ('paid', 'refused') ORDER BY id DESC LIMIT 50", { cid }) or {}) do
        d.history[#d.history + 1] = Bills.Row(r)
    end
    for _, r in ipairs(MySQL.query.await('SELECT * FROM fks_bills WHERE issuer_cid = ? ORDER BY id DESC LIMIT 50', { cid }) or {}) do
        d.issued[#d.issued + 1] = Bills.Row(r)
    end
    if BC.AllowBankPayment then
        d.accounts = {}
        if not IsFrozen(cid) then
            for _, a in ipairs(Acc.All(cid)) do
                if Bk.Bank(a.bank_id) then d.accounts[#d.accounts + 1] = { bank = a.bank_id, label = Bk.BankLabel(a.bank_id), cash = Bk.Round(a.cash) } end
            end
        end
    end
    return true, d
end, { noLimit = true })

Callback('bill:sign', function(src, P, id)
    if not BC.Enabled then return false, _L('feature_off') end
    local bill = Bills.ById(id)
    if not bill or bill.target_cid ~= tostring(P.cid) then return false, _L('bill_invalid') end
    local signed = Loans.SignedName(P)
    local n = MySQL.update.await("UPDATE fks_bills SET status = 'unpaid', signed_name = ?, signed_at = ? WHERE id = ? AND status = 'unsigned'",
        { signed, os.time(), bill.id })
    if n ~= 1 then return false, _L('bill_invalid') end
    if bill.issuer_cid then NotifyCid(bill.issuer_cid, 'bill_signed_issuer', { Bills.Number(bill.id), signed }, 'inform') end
    Webhook('Bills', _L('wh_bill_signed'), _L('wh_bill_signed_text', Bills.Number(bill.id), signed, Bk.Fmt(bill.amount)))
    return true, _L('bill_signed', Bills.Number(bill.id)), signed
end)

Callback('bill:refuse', function(src, P, id)
    if not BC.Enabled then return false, _L('feature_off') end
    local bill = Bills.ById(id)
    if not bill or bill.target_cid ~= tostring(P.cid) then return false, _L('bill_invalid') end
    local n = MySQL.update.await("UPDATE fks_bills SET status = 'refused' WHERE id = ? AND status = 'unsigned'", { bill.id })
    if n ~= 1 then return false, _L('bill_cant_refuse') end
    if bill.issuer_cid then NotifyCid(bill.issuer_cid, 'bill_refused_issuer', { Bills.Number(bill.id), P.name }, 'error') end
    return true, _L('bill_refused', Bills.Number(bill.id))
end)

--[[
    via: 'cash' | 'bank:<bankId>'
    The bill, the payer's account (bank payment), the writer's account (bank payout) and the vault (bank debt)
    are all locked before anything moves.
]]
Callback('bill:pay', function(src, P, id, via)
    if not BC.Enabled then return false, _L('feature_off') end
    local bill = Bills.ById(id)
    if not bill or bill.target_cid ~= tostring(P.cid) then return false, _L('bill_invalid') end
    if bill.status ~= 'unpaid' then return false, bill.status == 'unsigned' and _L('bill_sign_first') or _L('bill_invalid') end
    local amount = Bk.Round(bill.amount)
    local keys = { 'b' .. bill.id }

    local payerAcc
    if type(via) == 'string' and via:sub(1, 5) == 'bank:' then
        if not BC.AllowBankPayment then return false, _L('feature_off') end
        if IsFrozen(P.cid) then return false, _L('account_frozen') end
        payerAcc = Acc.Get(P.cid, via:sub(6))
        if not payerAcc or not Bk.Bank(payerAcc.bank_id) then return false, _L('no_account') end
        keys[#keys + 1] = AccKey(payerAcc.id)
    else
        via = 'cash'
    end
    local issuerAcc
    if bill.kind == 'personal' and BC.PersonalPayout == 'bank' and bill.issuer_cid then
        issuerAcc = Acc.Get(bill.issuer_cid, BC.PersonalPayoutBank)
        if issuerAcc and (not payerAcc or issuerAcc.id ~= payerAcc.id) then keys[#keys + 1] = AccKey(issuerAcc.id) end
    elseif bill.kind == 'bank' and bill.bank_id then
        keys[#keys + 1] = VaultKey(bill.bank_id)
    elseif bill.kind == 'company' and not Bills.CompaniesLinked() then
        return false, _L('company_unavailable')
    end

    return WithLocks(keys, function()
        bill = Bills.ById(bill.id)
        if not bill or bill.status ~= 'unpaid' then return false, _L('bill_invalid') end
        local number = Bills.Number(bill.id)
        local mark = { query = "UPDATE fks_bills SET status = 'paid', paid_at = ?, paid_via = ? WHERE id = ? AND status = 'unpaid'",
                       values = { os.time(), via, bill.id } }

        -- 1. take the money from the payer
        local function Refund()
            if payerAcc then Acc.Apply(payerAcc.id, 'cash', amount, 'refund', _L('tx_bill_refund', number), nil)
            else P.add('cash', amount, 'fks-banking bill refund') end
        end
        if payerAcc then
            local ok, res = Acc.Apply(payerAcc.id, 'cash', -amount, 'bill', _L('tx_bill_paid', number, bill.issuer_label or bill.issuer_name), Actor(P))
            if not ok then return false, res end
        else
            if P.money('cash') + 0.0001 < amount then return false, _L('bill_no_cash', Bk.Fmt(amount)) end
            if not P.remove('cash', amount, 'fks-banking bill') then return false, _L('bill_no_cash', Bk.Fmt(amount)) end
        end

        -- 2. give it to whoever wrote it
        if bill.kind == 'company' then
            local ok, res, err = pcall(function()
                return exports[COMPANIES]:AddBillIncome(bill.issuer_job, amount, P.name, number, bill.reason)
            end)
            if not ok or not res then
                Refund()
                print(('^1[fks-banking] fks-companies refused bill %s: %s^0'):format(number, tostring(ok and err or res)))
                return false, _L('company_unavailable')
            end
            MySQL.update.await(mark.query, mark.values)
        elseif bill.kind == 'bank' then
            local q = Vault.Q(bill.bank_id, amount, 'bill', _L('vl_bill', number, P.name), Actor(P))
            q[#q + 1] = mark
            if not MySQL.transaction.await(q) then Refund() return false, _L('error') end
        else
            local paidToBank = false
            if issuerAcc then
                paidToBank = Acc.Apply(issuerAcc.id, 'cash', amount, 'bill_in', _L('tx_bill_received', number, P.name), nil, { mark })
            end
            if not paidToBank then
                if not MySQL.update.await(mark.query, mark.values) then Refund() return false, _L('error') end
                GiveCash(bill.issuer_cid, amount, 'fks-banking bill', 'bill_paid_issuer', { number, P.name, Bk.Fmt(amount) })
            else
                NotifyCid(bill.issuer_cid, 'bill_paid_issuer_bank', { number, P.name, Bk.Fmt(amount), Bk.BankLabel(issuerAcc.bank_id) }, 'success')
            end
        end
        if bill.kind == 'company' and bill.issuer_cid then
            NotifyCid(bill.issuer_cid, 'bill_paid_company', { number, P.name, Bk.Fmt(amount) }, 'success')
        end
        Webhook('Bills', _L('wh_bill_paid'), _L('wh_bill_paid_text', number, P.name, Bk.Fmt(amount), bill.issuer_label or bill.issuer_name),
            { { _L('wh_via'), via } })
        TriggerEvent('fks-banking:server:billPaid', bill.id, bill.kind, bill.target_cid, amount)
        return true, _L('bill_paid', number, Bk.Fmt(amount))
    end)
end)
