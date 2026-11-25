---------------------------------------------------------------------------
-- The vault of each bank (section 5.1): its own balance, gold bar stock and ledger.
--
-- Rules of the money flow:
--   * IN : account opening fees, telegraph fees, exchange margins, vault box rents, loan installments (principal
--          back + interest), bank debt bills, optional reserve share of deposits, Director deposits.
--   * OUT: loans, gold bar purchases, appraisals, banker commissions and salaries, Director withdrawals.
--   An OUT that the vault cannot pay is refused: no money is created.
--
-- Vault.Q must run while the caller holds VaultKey(bankId): it reads the balance and returns the queries to run
-- in the caller's transaction (so an account change and the vault change are written together or not at all).
---------------------------------------------------------------------------
Vault = {}

local ensured = {}

function Vault.Ensure(bankId)
    if ensured[bankId] then return end
    DB.Wait()
    MySQL.insert.await('INSERT IGNORE INTO fks_bank_vaults (bank_id, balance, bars, updated_at) VALUES (?, ?, 0, ?)',
        { bankId, Config.Vault.StartingBalance, os.time() })
    ensured[bankId] = true
end

-- { balance, bars, salaries = { [rank] = amount } }
function Vault.Get(bankId)
    Vault.Ensure(bankId)
    local r = MySQL.single.await('SELECT balance, bars, salaries FROM fks_bank_vaults WHERE bank_id = ?', { bankId }) or {}
    local ok, sal = pcall(json.decode, r.salaries or '{}')
    return { balance = Bk.Round(r.balance), bars = tonumber(r.bars) or 0, salaries = ok and type(sal) == 'table' and sal or {} }
end

--[[
    delta   signed money (+ in / - out)
    bars    signed gold bar stock change (optional)
    returns queries, balanceAfter | nil, error (not enough money / bars)
]]
function Vault.Q(bankId, delta, kind, desc, actor, bars)
    local v = Vault.Get(bankId)
    delta = Bk.Round(delta)
    local after = Bk.Round(v.balance + delta)
    if after < 0 then return nil, _L('vault_no_funds') end
    local barsAfter = v.bars + (bars or 0)
    if barsAfter < 0 then return nil, _L('vault_no_bars') end
    return {
        { query = 'UPDATE fks_bank_vaults SET balance = ?, bars = ?, updated_at = ? WHERE bank_id = ?', values = { after, barsAfter, os.time(), bankId } },
        DB.VaultQuery(bankId, kind, delta, after, desc, actor),
    }, after
end

-- a vault change on its own (takes the vault lock). Returns ok, error / balance
function Vault.Apply(bankId, delta, kind, desc, actor, bars)
    return WithLock(VaultKey(bankId), function()
        local q, after = Vault.Q(bankId, delta, kind, desc, actor, bars)
        if not q then return false, after end
        if not MySQL.transaction.await(q) then return false, _L('error') end
        Debug('vault %s %s %s -> %s', bankId, kind, delta, after)
        return true, after
    end)
end

-- ledger rows (newest first)
function Vault.Ledger(bankId, limit)
    local rows = MySQL.query.await('SELECT * FROM fks_bank_vault_ledger WHERE bank_id = ? ORDER BY id DESC LIMIT ?', { bankId, limit or 100 }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        list[#list + 1] = { id = r.id, type = r.type, amount = Bk.Round(r.amount), after = Bk.Round(r.balance_after),
                            desc = r.description, actor = r.actor_name, at = r.created_at }
    end
    return list
end

-- items in the vault (collateral held, items to give back, bank stock)
function Vault.Items(bankId)
    return MySQL.query.await('SELECT * FROM fks_bank_vault_items WHERE bank_id = ? ORDER BY id DESC', { bankId }) or {}
end

-- banker salary amount of a rank in a bank (Director override or the config default)
function Vault.Salary(bankId, rankIdx)
    local v = Vault.Get(bankId)
    local amount = v.salaries[tostring(rankIdx)]
    if amount == nil then amount = Config.Banker.Salaries.Default[rankIdx] end
    return Bk.Round(math.min(tonumber(amount) or 0, Config.Banker.Salaries.Max))
end

CreateThread(function()
    DB.Wait()
    for _, b in ipairs(Bk.BankList) do Vault.Ensure(b.id) end
end)
