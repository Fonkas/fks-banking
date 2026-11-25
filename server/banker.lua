---------------------------------------------------------------------------
-- Banker job (section 5): ranks, services, client management, telegraph, gold exchange, appraisal, vault.
--
-- A banker only works in the bank(s) of their job (Config.Banker.Jobs), standing near its counter
-- (Config.Banker.WorkDistance). Clients must be near the banker (Config.Banker.ClientDistance) and confirm every
-- operation that touches their money or items (AskConsent): a banker can never move a client's money alone.
---------------------------------------------------------------------------
Banker = {}
Telegraph = {}

local B = Config.Banker
local PERMS = { 'openAccounts', 'exchange', 'clients', 'ledger', 'loans', 'telegraph', 'discounts', 'vault', 'bankLedger', 'salaries' }

-- { rank, rankName, perms = { [perm] = true }, maxLoan } | nil
function Banker.Info(P, bank)
    if not B.Enabled or not P or not Bk.BankerOf(P.job, bank.id) then return nil end
    local idx, rank = Bk.Rank(P.grade)
    if not rank then return nil end
    local perms = {}
    for _, p in ipairs(PERMS) do perms[p] = rank[p] == true end
    -- a service that is switched off is no permission
    if not Config.Loans.Enabled then perms.loans = false end
    if not Config.Telegraph.Enabled then perms.telegraph = false end
    if not Config.GoldExchange.Enabled then perms.exchange = perms.exchange and Config.Appraisal.Enabled end
    if not Config.Storage.Enabled then perms.discounts = false end
    if not B.Salaries.Enabled then perms.salaries = false end
    local maxLoan = rank.maxLoan and math.min(rank.maxLoan, Config.Loans.MaxAmount) or Config.Loans.MaxAmount
    return { rank = idx, rankName = rank.name, perms = perms, maxLoan = maxLoan }
end

-- bankers of this bank in the game right now
function Banker.OnlineCount(bankId)
    local n = 0
    for _, id in ipairs(GetPlayers()) do
        local P = Bridge.GetPlayer(tonumber(id))
        if P and Bk.BankerOf(P.job, bankId) then n = n + 1 end
    end
    return n
end

-- what the counter offers right now (automatic mode when no banker is online)
function Banker.Services(bank)
    local auto = B.Enabled and B.AutoModeWhenNoBankers and Banker.OnlineCount(bank.id) == 0
    local mult = auto and B.AutoModeFeeMultiplier or 1
    local s = { auto = auto, mult = mult }
    if Config.Telegraph.Enabled then
        local T = Config.Telegraph
        s.telegraph = { fee = T.FeePercent * mult, minFee = T.MinFee * mult, delay = T.DelayMinutes, max = T.MaxAmount, self = auto }
    end
    if Config.GoldExchange.Enabled then
        local v = Vault.Get(bank.id)
        s.exchange = { buy = Bk.Round(Config.GoldExchange.BuyPrice / mult), sell = Bk.Round(Config.GoldExchange.SellPrice * mult),
                       stock = v.bars, max = Config.GoldExchange.MaxPerTrade, self = auto, item = Config.GoldBars.Item,
                       label = Bridge.ItemLabel(Config.GoldBars.Item) }
    end
    if Config.Appraisal.Enabled then
        local items = {}
        for name, value in pairs(Config.Appraisal.Items) do
            items[#items + 1] = { item = name, label = Bridge.ItemLabel(name), value = Bk.Round(value / mult) }
        end
        table.sort(items, function(a, b) return a.label < b.label end)
        s.appraisal = { items = items, max = Config.Appraisal.MaxPerTrade, self = auto }
    end
    if Config.Loans.Enabled then
        s.loans = { self = auto and B.AutoModeLoans, min = Config.Loans.MinAmount, max = Config.Loans.MaxAmount,
                    minInterest = Config.Loans.MinInterest, maxInterest = Config.Loans.MaxInterest,
                    minInterestNone = math.max(Config.Loans.MinInterest, Config.Loans.MinInterestNoCollateral),
                    minInstallments = Config.Loans.MinInstallments, maxInstallments = Config.Loans.MaxInstallments,
                    intervals = Config.Loans.IntervalOptions, collateral = Config.Loans.Collateral, proposalMinutes = Config.Loans.ProposalMinutes }
    end
    return s
end

-- the banker calling, at the counter of a bank they work in, with a permission
local function Me(src, P, bankId, perm)
    local bank = Bk.Bank(bankId)
    if not bank then return nil, _L('invalid_bank') end
    local info = Banker.Info(P, bank)
    if not info then return nil, _L('not_banker') end
    if perm and not info.perms[perm] then return nil, _L('no_permission') end
    local pos = PedCoords(src)
    if not pos or #(pos - bank.coords) > B.WorkDistance then return nil, _L('banker_too_far') end
    return bank, info
end
Banker.Me = Me

-- a client next to the banker
local function Client(src, target)
    target = tonumber(target)
    if not target or target == src or not GetPlayerName(target) then return nil, _L('invalid_target') end
    local T = Bridge.GetPlayer(target)
    if not T then return nil, _L('player_offline') end
    if not NearPlayer(src, target, B.ClientDistance) then return nil, _L('target_far') end
    return target, T
end

---------------------------------------------------------------------------
-- Client management (section 5.5)
---------------------------------------------------------------------------
Callback('bk:clients', function(src, P, bankId, query)
    local bank, info = Me(src, P, bankId, 'clients')
    if not bank then return false, info end
    query = Bk.Text(query, 60) or ''
    local like = '%' .. query:gsub('[%%_]', '') .. '%'
    local rows = MySQL.query.await([[SELECT a.*, (f.cid IS NOT NULL) AS is_frozen FROM fks_bank_accounts a
        LEFT JOIN fks_bank_frozen f ON f.cid = a.cid
        WHERE a.bank_id = ? AND (a.owner_name LIKE ? OR a.account_number LIKE ? OR a.cid = ?) ORDER BY a.owner_name LIMIT 200]],
        { bank.id, like, like, query }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        list[#list + 1] = { id = r.id, name = r.owner_name, number = r.account_number, cid = r.cid,
                            cash = Bk.Round(r.cash), gold = Bk.Round(r.gold), bars = r.bars, frozen = r.is_frozen == 1 or r.is_frozen == true, created = r.created_at }
    end
    return true, list
end, { noLimit = true })

Callback('bk:client', function(src, P, bankId, accountId)
    local bank, info = Me(src, P, bankId, 'clients')
    if not bank then return false, info end
    local acc = Acc.ById(accountId)
    if not acc or acc.bank_id ~= bank.id then return false, _L('no_account') end
    local d = {
        id = acc.id, name = acc.owner_name, number = acc.account_number, cash = Bk.Round(acc.cash), gold = Bk.Round(acc.gold),
        bars = acc.bars, locked = acc.bars_locked, frozen = IsFrozen(acc.cid), created = acc.created_at,
        history = info.perms.ledger and Acc.History(acc.id, 100) or nil,
        loans = Config.Loans.Enabled and Loans.ForClient(acc.cid, bank.id) or nil,
    }
    if Config.Storage.Enabled then
        local box = Storage.Get(acc.cid, bank.id)
        if box then
            local tier = Bk.Tier(box.tier) or Config.Storage.Tiers[1]
            d.storage = { id = box.id, tier = tier.id, rent = Storage.Rent(tier, box.discount), base = tier.rent, discount = box.discount,
                          status = box.status, debt = Bk.Round(box.debt), nextDue = box.next_due_at }
        end
    end
    return true, d
end, { noLimit = true })

-- assisted account opening: the client confirms and pays the usual fee
Callback('bk:open', function(src, P, bankId, target)
    local bank, info = Me(src, P, bankId, 'openAccounts')
    if not bank then return false, info end
    local tsrc, T = Client(src, target)
    if not tsrc then return false, T end
    if Acc.Get(T.cid, bank.id) then return false, _L('client_has_account') end
    local fee = Config.Accounts.OpeningFee
    if not AskConsent(tsrc, _L('consent_open_title', bank.label), _L('consent_open_text', P.name, Bk.Fmt(fee))) then
        return false, _L('client_refused')
    end
    local ok, msg = Acc.Open(tsrc, T, bank, Actor(P))
    if ok then Notify(tsrc, msg, 'success') end
    return ok, ok and _L('account_opened_for', T.name) or msg
end)

-- discount on a client's vault box rent
Callback('bk:discount', function(src, P, bankId, storageId, pct)
    local bank, info = Me(src, P, bankId, 'discounts')
    if not bank then return false, info end
    local box = Storage.ById(storageId)
    if not box or box.bank_id ~= bank.id then return false, _L('no_storage') end
    pct = tonumber(pct)
    if not pct or pct ~= pct or pct < 0 or pct > B.MaxRentDiscount or pct ~= math.floor(pct) then
        return false, _L('discount_range', B.MaxRentDiscount)
    end
    MySQL.update.await('UPDATE fks_bank_storage SET discount = ? WHERE id = ?', { pct, box.id })
    NotifyCid(box.cid, 'discount_notice', { pct, bank.label }, 'success')
    return true, _L('discount_set', pct)
end)

---------------------------------------------------------------------------
-- Loans (banker side)
---------------------------------------------------------------------------
Callback('bk:loan', function(src, P, bankId, o)
    local bank, info = Me(src, P, bankId, 'loans')
    if not bank then return false, info end
    if type(o) ~= 'table' then return false, _L('error') end
    return Loans.Propose(src, P, bank, o, false)
end)

Callback('bk:loanCancel', function(src, P, bankId, loanId)
    local bank, info = Me(src, P, bankId, 'loans')
    if not bank then return false, info end
    return Loans.Cancel(P, bank, loanId)
end)

Callback('bk:loans', function(src, P, bankId)
    local bank, info = Me(src, P, bankId, 'loans')
    if not bank then return false, info end
    return true, Loans.ForBank(bank.id)
end, { noLimit = true })

-- automatic mode: the client asks for a loan at the counter (only with AutoModeLoans)
Callback('loan:self', function(src, P, bankId, o, gameHour)
    local bank, err = BankFor(src, bankId, gameHour)
    if not bank then return false, err end
    local s = Banker.Services(bank)
    if not (s.loans and s.loans.self) then return false, _L('needs_banker') end
    if type(o) ~= 'table' then return false, _L('error') end
    if o.collateral == 'item' then return false, _L('invalid_collateral') end   -- nobody to check an item
    return Loans.Propose(src, P, bank, o, true)
end)

---------------------------------------------------------------------------
-- Telegraph (section 5.3)
---------------------------------------------------------------------------
local function Fee(amount, mult)
    local T = Config.Telegraph
    return Bk.Round(math.max(T.MinFee, amount * T.FeePercent / 100) * mult)
end

-- moves `amount` from account `fromId` to account number `toNumber` (+ fee from the sender to the sending vault)
function Telegraph.Send(fromId, toNumber, amount, mult, banker, senderName)
    local T = Config.Telegraph
    amount = Bk.Money(amount)
    if not amount or amount > T.MaxAmount then return false, _L('telegraph_max', Bk.Fmt(T.MaxAmount)) end
    local from = Acc.ById(fromId)
    if not from then return false, _L('no_account') end
    if IsFrozen(from.cid) then return false, _L('client_frozen') end
    local to = Acc.ByNumber(toNumber)
    if not to then return false, _L('telegraph_no_target') end
    if to.id == from.id then return false, _L('telegraph_same') end
    if IsFrozen(to.cid) then return false, _L('telegraph_target_frozen') end
    local fee = Fee(amount, mult)
    local total = Bk.Round(amount + fee)
    local now = os.time()
    local arrives = now + T.DelayMinutes * 60

    return WithLocks({ AccKey(from.id), VaultKey(from.bank_id) }, function()
        local extra = Vault.Q(from.bank_id, fee, 'transfer_fee', _L('vl_transfer_fee', from.account_number, to.account_number), banker)
        extra[#extra + 1] = { query = [[INSERT INTO fks_bank_transfers (from_account, to_account, from_bank, to_bank, from_cid, to_cid, amount, fee,
            banker_cid, banker_name, status, arrives_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)]],
            values = { from.id, to.id, from.bank_id, to.bank_id, from.cid, to.cid, amount, fee, banker and banker.cid or nil, banker and banker.name or nil, arrives, now } }
        local ok, res = Acc.Apply(from.id, 'cash', -total, 'transfer_out',
            _L('tx_transfer_out', Bk.Fmt(amount), to.account_number, to.owner_name, Bk.Fmt(fee)), banker, extra)
        if not ok then return false, res end
        Webhook('Banker', _L('wh_transfer'), _L('wh_transfer_text', from.owner_name, Bk.Fmt(amount), to.owner_name, Bk.BankLabel(from.bank_id), Bk.BankLabel(to.bank_id)),
            { { _L('wh_fee'), Bk.Fmt(fee) }, { _L('wh_banker'), banker and banker.name or _L('auto_mode') } })
        if T.DelayMinutes <= 0 then SetTimeout(0, function() Telegraph.Deliver() end) end
        return true, _L('telegraph_sent', Bk.Fmt(amount), to.owner_name, Bk.Span(arrives - now))
    end)
end

-- delivers every transfer that arrived
function Telegraph.Deliver()
    local now = os.time()
    for _, t in ipairs(MySQL.query.await("SELECT * FROM fks_bank_transfers WHERE status = 'pending' AND arrives_at <= ?", { now }) or {}) do
        WithLock(AccKey(t.to_account), function()
            local fresh = MySQL.single.await('SELECT status FROM fks_bank_transfers WHERE id = ?', { t.id })
            if not fresh or fresh.status ~= 'pending' then return end
            local from = Acc.ById(t.from_account)
            local ok = Acc.Apply(t.to_account, 'cash', t.amount, 'transfer_in',
                _L('tx_transfer_in', Bk.Fmt(t.amount), from and from.owner_name or '?', Bk.BankLabel(t.from_bank)), nil, {
                    { query = "UPDATE fks_bank_transfers SET status = 'done' WHERE id = ? AND status = 'pending'", values = { t.id } },
                })
            if ok then NotifyCid(t.to_cid, 'telegraph_received', { Bk.Fmt(t.amount), Bk.BankLabel(t.to_bank) }, 'success') end
        end)
    end
end

CreateThread(function()
    DB.Wait()
    Wait(12000)
    while true do
        if Config.Telegraph.Enabled then Telegraph.Deliver() end
        Wait(30000)
    end
end)

Callback('bk:telegraph', function(src, P, bankId, target, toNumber, amount)
    local bank, info = Me(src, P, bankId, 'telegraph')
    if not bank then return false, info end
    local tsrc, T = Client(src, target)
    if not tsrc then return false, T end
    local acc = Acc.Get(T.cid, bank.id)
    if not acc then return false, _L('client_no_account') end
    local value = Bk.Money(amount)
    if not value then return false, _L('invalid_amount') end
    local to = Acc.ByNumber(toNumber)
    if not to then return false, _L('telegraph_no_target') end
    local fee = Fee(value, 1)
    if not AskConsent(tsrc, _L('consent_telegraph_title'), _L('consent_telegraph_text', Bk.Fmt(value), to.owner_name, Bk.BankLabel(to.bank_id), Bk.Fmt(fee))) then
        return false, _L('client_refused')
    end
    local ok, msg = Telegraph.Send(acc.id, to.account_number, value, 1, Actor(P))
    if ok then Notify(tsrc, msg, 'success') end
    return ok, msg
end)

-- automatic mode (no banker online): the client sends it themselves, with the higher fee
Callback('tele:self', function(src, P, bankId, toNumber, amount, gameHour)
    local bank, err = BankFor(src, bankId, gameHour)
    if not bank then return false, err end
    local s = Banker.Services(bank)
    if not (s.telegraph and s.telegraph.self) then return false, _L('needs_banker') end
    local acc = Acc.Get(P.cid, bank.id)
    if not acc then return false, _L('no_account') end
    if IsFrozen(P.cid) then return false, _L('account_frozen') end
    return Telegraph.Send(acc.id, toNumber, amount, s.mult, nil)
end)

---------------------------------------------------------------------------
-- Gold exchange and appraisal (section 5.4). Cash on hand; the vault pays / receives.
--   mode 'buy'  = the bank buys bars from the client     mode 'sell' = the bank sells bars to the client
---------------------------------------------------------------------------
local function Exchange(bank, csrc, C, mode, n, mult, actor)
    local G = Config.GoldExchange
    local item = Config.GoldBars.Item
    n = Bk.Int(n, G.MaxPerTrade)
    if not n then return false, _L('exchange_max', G.MaxPerTrade) end
    return WithLock(VaultKey(bank.id), function()
        if mode == 'buy' then
            local price = Bk.Round(n * G.BuyPrice / mult)
            if Bridge.ItemCount(csrc, item) < n then return false, _L('client_not_enough_bars_item') end
            local q, err = Vault.Q(bank.id, -price, 'gold_buy', _L('vl_gold_buy', n, C.name), actor, n)
            if not q then return false, err end
            if not Bridge.RemoveItem(csrc, item, n) then return false, _L('client_not_enough_bars_item') end
            if not MySQL.transaction.await(q) then Bridge.AddItem(csrc, item, n) return false, _L('error') end
            if not C.add('cash', price, 'fks-banking gold sale') then GiveCash(C.cid, price, 'fks-banking gold sale') end
            Webhook('Banker', _L('wh_exchange'), _L('wh_exchange_buy', C.name, n, Bk.Fmt(price), bank.label))
            return true, _L('exchange_bought', n, Bk.Fmt(price))
        elseif mode == 'sell' then
            local price = Bk.Round(n * G.SellPrice * mult)
            if C.money('cash') + 0.0001 < price then return false, _L('client_not_enough_cash') end
            if not Bridge.CanCarry(csrc, item, n) then return false, _L('client_inventory_full') end
            local q, err = Vault.Q(bank.id, price, 'gold_sell', _L('vl_gold_sell', n, C.name), actor, -n)
            if not q then return false, err end
            if not C.remove('cash', price, 'fks-banking gold purchase') then return false, _L('client_not_enough_cash') end
            if not MySQL.transaction.await(q) then C.add('cash', price) return false, _L('error') end
            if not Bridge.AddItem(csrc, item, n) then
                -- the inventory refused: undo (money back, bars back in stock)
                local undo = Vault.Q(bank.id, -price, 'refund', _L('vl_refund'), nil, n)
                if undo then MySQL.transaction.await(undo) end
                C.add('cash', price, 'fks-banking gold refund')
                return false, _L('client_inventory_full')
            end
            Webhook('Banker', _L('wh_exchange'), _L('wh_exchange_sell', C.name, n, Bk.Fmt(price), bank.label))
            return true, _L('exchange_sold', n, Bk.Fmt(price))
        end
        return false, _L('error')
    end)
end

local function Appraise(bank, csrc, C, item, n, mult, actor)
    local A = Config.Appraisal
    local value = A.Items[item]
    if not value then return false, _L('invalid_item') end
    n = Bk.Int(n, A.MaxPerTrade)
    if not n then return false, _L('exchange_max', A.MaxPerTrade) end
    local price = Bk.Round(n * value / mult)
    return WithLock(VaultKey(bank.id), function()
        if Bridge.ItemCount(csrc, item) < n then return false, _L('client_no_item') end
        local q, err = Vault.Q(bank.id, -price, 'appraisal', _L('vl_appraisal', n, Bridge.ItemLabel(item), C.name), actor)
        if not q then return false, err end
        q[#q + 1] = { query = "INSERT INTO fks_bank_vault_items (bank_id, item, amount, status, created_at) VALUES (?, ?, ?, 'stock', ?)", values = { bank.id, item, n, os.time() } }
        if not Bridge.RemoveItem(csrc, item, n) then return false, _L('client_no_item') end
        if not MySQL.transaction.await(q) then Bridge.AddItem(csrc, item, n) return false, _L('error') end
        if not C.add('cash', price, 'fks-banking appraisal') then GiveCash(C.cid, price, 'fks-banking appraisal') end
        return true, _L('appraisal_done', n, Bridge.ItemLabel(item), Bk.Fmt(price))
    end)
end

Callback('bk:exchange', function(src, P, bankId, target, mode, n)
    local bank, info = Me(src, P, bankId, 'exchange')
    if not bank then return false, info end
    if not Config.GoldExchange.Enabled then return false, _L('feature_off') end
    local tsrc, T = Client(src, target)
    if not tsrc then return false, T end
    local count = Bk.Int(n, Config.GoldExchange.MaxPerTrade)
    if not count then return false, _L('exchange_max', Config.GoldExchange.MaxPerTrade) end
    local price = mode == 'buy' and count * Config.GoldExchange.BuyPrice or count * Config.GoldExchange.SellPrice
    local text = mode == 'buy' and _L('consent_buy_text', count, Bk.Fmt(price)) or _L('consent_sell_text', count, Bk.Fmt(price))
    if not AskConsent(tsrc, _L('consent_exchange_title'), text) then return false, _L('client_refused') end
    local ok, msg = Exchange(bank, tsrc, T, mode, count, 1, Actor(P))
    if ok then Notify(tsrc, msg, 'success') end
    return ok, msg
end)

Callback('ex:self', function(src, P, bankId, mode, n, gameHour)
    local bank, err = BankFor(src, bankId, gameHour)
    if not bank then return false, err end
    local s = Banker.Services(bank)
    if not (s.exchange and s.exchange.self) then return false, _L('needs_banker') end
    return Exchange(bank, src, P, mode, n, s.mult, nil)
end)

Callback('bk:appraise', function(src, P, bankId, target, item, n)
    local bank, info = Me(src, P, bankId, 'exchange')
    if not bank then return false, info end
    if not Config.Appraisal.Enabled then return false, _L('feature_off') end
    local tsrc, T = Client(src, target)
    if not tsrc then return false, T end
    local value = Config.Appraisal.Items[item]
    local count = Bk.Int(n, Config.Appraisal.MaxPerTrade)
    if not value or not count then return false, _L('invalid_item') end
    if not AskConsent(tsrc, _L('consent_appraisal_title'), _L('consent_appraisal_text', count, Bridge.ItemLabel(item), Bk.Fmt(count * value))) then
        return false, _L('client_refused')
    end
    local ok, msg = Appraise(bank, tsrc, T, item, count, 1, Actor(P))
    if ok then Notify(tsrc, msg, 'success') end
    return ok, msg
end)

Callback('appr:self', function(src, P, bankId, item, n, gameHour)
    local bank, err = BankFor(src, bankId, gameHour)
    if not bank then return false, err end
    local s = Banker.Services(bank)
    if not (s.appraisal and s.appraisal.self) then return false, _L('needs_banker') end
    return Appraise(bank, src, P, item, n, s.mult, nil)
end)

---------------------------------------------------------------------------
-- Vault management (Director): balance, ledger, items, deposit / withdraw, salaries, full bank ledger
---------------------------------------------------------------------------
Callback('bk:vault', function(src, P, bankId)
    local bank, info = Me(src, P, bankId, 'vault')
    if not bank then return false, info end
    local v = Vault.Get(bank.id)
    local items = {}
    for _, r in ipairs(Vault.Items(bank.id)) do
        items[#items + 1] = { id = r.id, item = r.item, label = Bridge.ItemLabel(r.item), amount = r.amount, status = r.status, loan = r.loan_id, at = r.created_at }
    end
    local salaries
    if B.Salaries.Enabled then
        salaries = {}
        for i, r in ipairs(B.Ranks) do salaries[#salaries + 1] = { rank = i - 1, name = r.name, amount = Vault.Salary(bank.id, i - 1) } end
    end
    return true, { balance = v.balance, bars = v.bars, ledger = Vault.Ledger(bank.id, 150), items = items, salaries = salaries,
                   salaryMax = B.Salaries.Max, salaryEvery = B.Salaries.IntervalMinutes, cash = Bk.Round(P.money('cash')) }
end, { noLimit = true })

Callback('bk:vaultMove', function(src, P, bankId, dir, value)
    local bank, info = Me(src, P, bankId, 'vault')
    if not bank then return false, info end
    local amount = Bk.Money(value)
    if not amount then return false, _L('invalid_amount') end
    if dir == 'deposit' then
        return WithLock(VaultKey(bank.id), function()
            if P.money('cash') + 0.0001 < amount then return false, _L('not_enough_cash') end
            if not P.remove('cash', amount, 'fks-banking vault deposit') then return false, _L('not_enough_cash') end
            local q = Vault.Q(bank.id, amount, 'deposit', _L('vl_director_deposit', P.name), Actor(P))
            if not MySQL.transaction.await(q) then P.add('cash', amount) return false, _L('error') end
            Webhook('Banker', _L('wh_vault'), _L('wh_vault_deposit', P.name, Bk.Fmt(amount), bank.label))
            return true, _L('vault_deposited', Bk.Fmt(amount))
        end)
    elseif dir == 'withdraw' then
        local ok, res = Vault.Apply(bank.id, -amount, 'withdraw', _L('vl_director_withdraw', P.name), Actor(P))
        if not ok then return false, res end
        if not P.add('cash', amount, 'fks-banking vault withdraw') then
            Vault.Apply(bank.id, amount, 'refund', _L('vl_refund'), nil)
            return false, _L('error')
        end
        Webhook('Banker', _L('wh_vault'), _L('wh_vault_withdraw', P.name, Bk.Fmt(amount), bank.label))
        return true, _L('vault_withdrew', Bk.Fmt(amount))
    end
    return false, _L('error')
end)

-- takes an item of the bank's own stock (seized collateral / appraised items) into the Director's inventory
Callback('bk:vaultItem', function(src, P, bankId, rowId)
    local bank, info = Me(src, P, bankId, 'vault')
    if not bank then return false, info end
    return WithLock(VaultKey(bank.id), function()
        local r = MySQL.single.await("SELECT * FROM fks_bank_vault_items WHERE id = ? AND bank_id = ? AND status = 'stock'", { tonumber(rowId) or -1, bank.id })
        if not r then return false, _L('invalid_item') end
        if not Bridge.CanCarry(src, r.item, r.amount) then return false, _L('inventory_full') end
        if MySQL.update.await("DELETE FROM fks_bank_vault_items WHERE id = ? AND status = 'stock'", { r.id }) ~= 1 then return false, _L('error') end
        if not Bridge.AddItem(src, r.item, r.amount) then
            MySQL.insert.await("INSERT INTO fks_bank_vault_items (bank_id, item, amount, status, created_at) VALUES (?, ?, ?, 'stock', ?)", { bank.id, r.item, r.amount, r.created_at })
            return false, _L('inventory_full')
        end
        local log = DB.VaultQuery(bank.id, 'item_out', 0, Vault.Get(bank.id).balance, _L('vl_item_out', r.amount, Bridge.ItemLabel(r.item), P.name), Actor(P))
        MySQL.insert.await(log.query, log.values)
        return true, _L('vault_item_taken', r.amount, Bridge.ItemLabel(r.item))
    end)
end)

-- takes gold bars of the vault stock into the Director's inventory (e.g. to move them to another bank)
Callback('bk:vaultBars', function(src, P, bankId, n)
    local bank, info = Me(src, P, bankId, 'vault')
    if not bank then return false, info end
    local item = Config.GoldBars.Item
    n = Bk.Int(n, 10000)
    if not n then return false, _L('invalid_amount') end
    return WithLock(VaultKey(bank.id), function()
        if not Bridge.CanCarry(src, item, n) then return false, _L('inventory_full') end
        local q, err = Vault.Q(bank.id, 0, 'item_out', _L('vl_bars_out', n, P.name), Actor(P), -n)
        if not q then return false, err end
        if not MySQL.transaction.await(q) then return false, _L('error') end
        if not Bridge.AddItem(src, item, n) then
            local undo = Vault.Q(bank.id, 0, 'refund', _L('vl_refund'), nil, n)
            if undo then MySQL.transaction.await(undo) end
            return false, _L('inventory_full')
        end
        return true, _L('vault_bars_taken', n)
    end)
end)

Callback('bk:salary', function(src, P, bankId, rank, value)
    local bank, info = Me(src, P, bankId, 'salaries')
    if not bank then return false, info end
    rank = math.floor(tonumber(rank) or -1)
    if rank < 0 or rank >= #B.Ranks then return false, _L('error') end
    local amount = Bk.Money(value, true)
    if not amount or amount > B.Salaries.Max then return false, _L('salary_range', Bk.Fmt(B.Salaries.Max)) end
    return WithLock(VaultKey(bank.id), function()
        local v = Vault.Get(bank.id)
        v.salaries[tostring(rank)] = amount
        MySQL.update.await('UPDATE fks_bank_vaults SET salaries = ? WHERE bank_id = ?', { json.encode(v.salaries), bank.id })
        return true, _L('salary_set', B.Ranks[rank + 1].name, Bk.Fmt(amount))
    end)
end)

Callback('bk:bankLedger', function(src, P, bankId)
    local bank, info = Me(src, P, bankId, 'bankLedger')
    if not bank then return false, info end
    local rows = MySQL.query.await([[SELECT t.*, a.owner_name, a.account_number FROM fks_bank_transactions t
        JOIN fks_bank_accounts a ON a.id = t.account_id WHERE t.bank_id = ? ORDER BY t.id DESC LIMIT 300]], { bank.id }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        list[#list + 1] = { id = r.id, name = r.owner_name, number = r.account_number, type = r.type, currency = r.currency,
                            amount = tonumber(r.amount) or 0, after = tonumber(r.balance_after) or 0, desc = r.description, actor = r.actor_name, at = r.created_at }
    end
    return true, list
end, { noLimit = true })

---------------------------------------------------------------------------
-- Salaries (from the vault, to bankers online)
---------------------------------------------------------------------------
CreateThread(function()
    DB.Wait()
    while true do
        Wait(math.max(1, B.Salaries.IntervalMinutes) * 60000)
        if B.Enabled and B.Salaries.Enabled then
            for _, id in ipairs(GetPlayers()) do
                local src = tonumber(id)
                local P = Bridge.GetPlayer(src)
                if P and Config.Banker.Jobs[P.job] then
                    -- paid by the first bank of their job
                    local banks = Config.Banker.Jobs[P.job]
                    local bankId = banks == 'all' and (Bk.BankList[1] and Bk.BankList[1].id) or (type(banks) == 'table' and banks[1])
                    local idx = Bk.Rank(P.grade)
                    if bankId and Bk.Bank(bankId) and idx then
                        local amount = Vault.Salary(bankId, idx)
                        if amount > 0 then
                            local ok = Vault.Apply(bankId, -amount, 'salary', _L('vl_salary', P.name), Actor(P))
                            if ok and P.add('cash', amount, 'fks-banking salary') then
                                Notify(src, _L('salary_paid', Bk.Fmt(amount), Bk.BankLabel(bankId)), 'success')
                            elseif ok then
                                Vault.Apply(bankId, amount, 'refund', _L('vl_refund'), nil)
                            else
                                Notify(src, _L('salary_no_funds', Bk.BankLabel(bankId)), 'error')
                            end
                        end
                    end
                end
            end
        end
    end
end)
