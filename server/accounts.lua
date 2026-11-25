---------------------------------------------------------------------------
-- Accounts (section 2): one per character per bank. Cash and gold deposits / withdrawals, history, frozen state.
-- Every balance change goes through Acc.Apply inside the account lock (AccKey).
---------------------------------------------------------------------------
Acc = {}

local FIELDS = { cash = 'cash', gold = 'gold', bars = 'bars' }

function Acc.ById(id)
    return MySQL.single.await('SELECT * FROM fks_bank_accounts WHERE id = ?', { tonumber(id) or -1 })
end

function Acc.Get(cid, bankId)
    return MySQL.single.await('SELECT * FROM fks_bank_accounts WHERE cid = ? AND bank_id = ?', { tostring(cid), bankId })
end

function Acc.ByNumber(number)
    if type(number) ~= 'string' then return nil end
    number = number:upper():gsub('%s+', '')
    if not number:match('^[%u%d]+%-%d+$') then return nil end
    return MySQL.single.await('SELECT * FROM fks_bank_accounts WHERE account_number = ?', { number })
end

function Acc.All(cid)
    return MySQL.query.await('SELECT * FROM fks_bank_accounts WHERE cid = ? ORDER BY id', { tostring(cid) }) or {}
end

--[[
    Changes one balance of an account. MUST run inside the account lock (and the vault lock when `extra` touches
    the vault). Re-reads the row, refuses to go below zero (or below the locked bars), writes the balance, the
    history row and the `extra` queries in ONE transaction.
      field   'cash' | 'gold' | 'bars'      delta  signed
      returns ok, account | error
]]
function Acc.Apply(id, field, delta, kind, desc, actor, extra)
    local col = FIELDS[field]
    if not col then return false, _L('error') end
    local acc = Acc.ById(id)
    if not acc then return false, _L('no_account') end
    local before = tonumber(acc[col]) or 0
    local after = col == 'bars' and math.floor(before + delta) or Bk.Round(before + delta)
    if after < 0 then
        return false, (col == 'cash' and _L('account_no_funds')) or (col == 'gold' and _L('account_no_gold')) or _L('account_no_bars')
    end
    if col == 'bars' and after < (tonumber(acc.bars_locked) or 0) then return false, _L('bars_locked_err') end
    local queries = {
        { query = ('UPDATE fks_bank_accounts SET %s = ? WHERE id = ?'):format(col), values = { after, acc.id } },
        DB.TxQuery(acc, kind, col, delta, after, desc, actor),
    }
    for _, q in ipairs(extra or {}) do queries[#queries + 1] = q end
    if not MySQL.transaction.await(queries) then return false, _L('error') end
    acc[col] = after
    Debug('account %s %s %s %s -> %s', acc.id, kind, col, delta, after)
    TriggerEvent('fks-banking:server:accountChanged', acc.id, acc.cid, acc.bank_id, col, delta, after, kind)
    return true, acc
end

-- history rows of an account (newest first)
function Acc.History(id, limit)
    local rows = MySQL.query.await('SELECT * FROM fks_bank_transactions WHERE account_id = ? ORDER BY id DESC LIMIT ?',
        { id, limit or Config.Accounts.HistoryLimit }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        list[#list + 1] = { id = r.id, type = r.type, currency = r.currency, amount = tonumber(r.amount) or 0,
                            after = tonumber(r.balance_after) or 0, desc = r.description, actor = r.actor_name, at = r.created_at }
    end
    return list
end

---------------------------------------------------------------------------
-- Frozen characters (section 7.3). Cached in memory; the table is the source of truth.
---------------------------------------------------------------------------
FrozenSet = {}           -- [cid] = { name, bill_id, frozen_by, frozen_at }

CreateThread(function()
    DB.Wait()
    for _, r in ipairs(MySQL.query.await('SELECT * FROM fks_bank_frozen') or {}) do FrozenSet[tostring(r.cid)] = r end
end)

function IsFrozen(cid) return FrozenSet[tostring(cid)] ~= nil end

---------------------------------------------------------------------------
-- Opening an account
---------------------------------------------------------------------------
local function NewNumber(bank)
    for _ = 1, 20 do
        local n = ('%s-%06d'):format(bank.prefix, math.random(0, 999999))
        if not MySQL.scalar.await('SELECT 1 FROM fks_bank_accounts WHERE account_number = ?', { n }) then return n end
    end
    return ('%s-%d'):format(bank.prefix, os.time())
end

-- opens an account for P at bank (cash fee to the vault). actor = the banker for assisted openings
function Acc.Open(src, P, bank, actor)
    local cid = tostring(P.cid)
    return WithLocks({ CidKey(cid), VaultKey(bank.id) }, function()
        if Acc.Get(cid, bank.id) then return false, _L('account_exists') end
        local fee = Config.Accounts.OpeningFee
        if fee > 0 and P.money('cash') + 0.0001 < fee then return false, _L('not_enough_cash_fee', Bk.Fmt(fee)) end
        if fee > 0 and not P.remove('cash', fee, 'fks-banking account fee') then return false, _L('not_enough_cash_fee', Bk.Fmt(fee)) end
        local number = NewNumber(bank)
        local now = os.time()
        local queries = {
            { query = [[INSERT INTO fks_bank_accounts (bank_id, cid, owner_name, account_number, frozen, last_payout_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)]], values = { bank.id, cid, P.name, number, IsFrozen(cid) and 1 or 0, now, now } },
        }
        if fee > 0 then
            local vq, err = Vault.Q(bank.id, fee, 'opening_fee', _L('vl_opening_fee', P.name, number), actor or Actor(P))
            if not vq then P.add('cash', fee) return false, err end
            for _, q in ipairs(vq) do queries[#queries + 1] = q end
        end
        if not MySQL.transaction.await(queries) then
            if fee > 0 then P.add('cash', fee, 'fks-banking account fee refund') end
            return false, _L('error')
        end
        Webhook('Accounts', _L('wh_account_opened'), _L('wh_account_opened_text', P.name, number, bank.label),
            { { _L('wh_fee'), Bk.Fmt(fee) }, actor and { _L('wh_banker'), actor.name } or nil })
        return true, _L('account_opened', number, bank.label)
    end)
end

---------------------------------------------------------------------------
-- Callbacks: open, deposit, withdraw (cash and gold)
---------------------------------------------------------------------------
-- account of the caller at a bank they are standing at, not frozen
local function MyAccount(src, P, bankId, gameHour, allowFrozen)
    local bank, err = BankFor(src, bankId, gameHour)
    if not bank then return nil, err end
    if not allowFrozen and IsFrozen(P.cid) then return nil, _L('account_frozen') end
    local acc = Acc.Get(P.cid, bank.id)
    if not acc then return nil, _L('no_account') end
    return acc, bank
end
Acc.Mine = MyAccount

Callback('acc:open', function(src, P, bankId, gameHour)
    local bank, err = BankFor(src, bankId, gameHour)
    if not bank then return false, err end
    return Acc.Open(src, P, bank)
end)

Callback('acc:deposit', function(src, P, bankId, value, gameHour)
    local acc, bank = MyAccount(src, P, bankId, gameHour)
    if not acc then return false, bank end
    local amount = Bk.Money(value)
    if not amount then return false, _L('invalid_amount') end
    local max = Config.Accounts.MaxDepositPerOperation
    if max > 0 and amount > max then return false, _L('max_deposit', Bk.Fmt(max)) end

    local reserve = Bk.Round(amount * Config.Vault.ReserveRatio)
    local keys = { AccKey(acc.id) }
    if reserve > 0 then keys[#keys + 1] = VaultKey(bank.id) end
    return WithLocks(keys, function()
        if P.money('cash') + 0.0001 < amount then return false, _L('not_enough_cash') end
        if not P.remove('cash', amount, 'fks-banking deposit') then return false, _L('not_enough_cash') end
        local extra
        if reserve > 0 then extra = Vault.Q(bank.id, reserve, 'reserve', _L('vl_reserve', Bk.Fmt(amount), acc.account_number), nil) end
        local ok, res = Acc.Apply(acc.id, 'cash', amount, 'deposit', _L('tx_deposit'), Actor(P), extra)
        if not ok then
            P.add('cash', amount, 'fks-banking deposit refund')   -- nothing was written: give it back
            return false, res
        end
        if amount >= Config.Webhooks.BigAmount then
            Webhook('Accounts', _L('wh_big_deposit'), _L('wh_big_text', P.name, Bk.Fmt(amount), acc.account_number, bank.label))
        end
        return true, _L('deposited', Bk.Fmt(amount))
    end)
end)

Callback('acc:withdraw', function(src, P, bankId, value, gameHour)
    local acc, bank = MyAccount(src, P, bankId, gameHour)
    if not acc then return false, bank end
    local amount = Bk.Money(value)
    if not amount then return false, _L('invalid_amount') end

    return WithLock(AccKey(acc.id), function()
        acc = Acc.ById(acc.id)
        local day = Bk.Day()
        local today = acc.withdrawn_day == day and (tonumber(acc.withdrawn_today) or 0) or 0
        local max = Config.Accounts.MaxWithdrawPerDay
        if max > 0 and today + amount > max + 0.0001 then
            return false, _L('max_withdraw_day', Bk.Fmt(max), Bk.Fmt(math.max(0, max - today)))
        end
        local ok, res = Acc.Apply(acc.id, 'cash', -amount, 'withdraw', _L('tx_withdraw'), Actor(P), {
            { query = 'UPDATE fks_bank_accounts SET withdrawn_day = ?, withdrawn_today = ? WHERE id = ?', values = { day, Bk.Round(today + amount), acc.id } },
        })
        if not ok then return false, res end
        if not P.add('cash', amount, 'fks-banking withdraw') then
            -- the framework refused the cash: put it back in the account
            Acc.Apply(acc.id, 'cash', amount, 'refund', _L('tx_withdraw_failed'), nil, {
                { query = 'UPDATE fks_bank_accounts SET withdrawn_today = GREATEST(withdrawn_today - ?, 0) WHERE id = ?', values = { amount, acc.id } },
            })
            return false, _L('error')
        end
        if amount >= Config.Webhooks.BigAmount then
            Webhook('Accounts', _L('wh_big_withdraw'), _L('wh_big_text', P.name, Bk.Fmt(amount), acc.account_number, bank.label))
        end
        return true, _L('withdrew', Bk.Fmt(amount))
    end)
end)

Callback('gold:deposit', function(src, P, bankId, value, gameHour)
    if not GoldAvailable() then return false, _L('feature_off') end
    local acc, bank = MyAccount(src, P, bankId, gameHour)
    if not acc then return false, bank end
    local amount = Bk.Money(value)
    if not amount then return false, _L('invalid_amount') end
    local max = Config.GoldCurrency.MaxDepositPerOperation
    if max > 0 and amount > max then return false, _L('max_deposit_gold', Bk.Gold(max)) end

    return WithLock(AccKey(acc.id), function()
        if P.money('gold') + 0.0001 < amount then return false, _L('not_enough_gold') end
        if not P.remove('gold', amount, 'fks-banking gold deposit') then return false, _L('not_enough_gold') end
        local ok, res = Acc.Apply(acc.id, 'gold', amount, 'gold_in', _L('tx_gold_in'), Actor(P))
        if not ok then
            P.add('gold', amount, 'fks-banking gold refund')
            return false, res
        end
        return true, _L('gold_deposited', Bk.Gold(amount))
    end)
end)

Callback('gold:withdraw', function(src, P, bankId, value, gameHour)
    if not GoldAvailable() then return false, _L('feature_off') end
    local acc, bank = MyAccount(src, P, bankId, gameHour)
    if not acc then return false, bank end
    local amount = Bk.Money(value)
    if not amount then return false, _L('invalid_amount') end

    return WithLock(AccKey(acc.id), function()
        local ok, res = Acc.Apply(acc.id, 'gold', -amount, 'gold_out', _L('tx_gold_out'), Actor(P))
        if not ok then return false, res end
        if not P.add('gold', amount, 'fks-banking gold withdraw') then
            Acc.Apply(acc.id, 'gold', amount, 'refund', _L('tx_withdraw_failed'), nil)
            return false, _L('error')
        end
        return true, _L('gold_withdrew', Bk.Gold(amount))
    end)
end)

---------------------------------------------------------------------------
-- Everything the bank menu shows, in one call (the client builds the screens from it)
---------------------------------------------------------------------------
function BankData(src, P, bank)
    local cid = tostring(P.cid)
    local acc = Acc.Get(cid, bank.id)
    local d = {
        bank = { id = bank.id, label = bank.label },
        frozen = IsFrozen(cid),
        name = P.name,
        cash = Bk.Round(P.money('cash')),
        openingFee = Config.Accounts.OpeningFee,
        gold = GoldAvailable() and { onHand = Bk.Round(P.money('gold')) } or false,
    }
    if acc then
        d.account = {
            id = acc.id, number = acc.account_number, cash = Bk.Round(acc.cash), gold = Bk.Round(acc.gold),
            bars = tonumber(acc.bars) or 0, locked = tonumber(acc.bars_locked) or 0, created = acc.created_at,
            history = Acc.History(acc.id),
        }
    end
    if Config.GoldBars.Enabled then d.bars = GoldBars.Info(src, acc) end
    if Config.Storage.Enabled then d.storage = Storage.Info(cid, bank) end
    if Config.Loans.Enabled then d.loans = Loans.ForClient(cid, bank.id) end
    d.services = Banker.Services(bank)
    d.banker = Banker.Info(P, bank)
    return d
end

Callback('bank:data', function(src, P, bankId, gameHour)
    local bank, err = BankFor(src, bankId, gameHour)
    if not bank then return false, err end
    return true, BankData(src, P, bank)
end, { noLimit = true })
