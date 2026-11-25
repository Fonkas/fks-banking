---------------------------------------------------------------------------
-- Database: the tables of sql/install.sql are created on start (CREATE TABLE IF NOT EXISTS), so importing the
-- file by hand is optional. Everything else waits for DB.Wait() before touching the database.
---------------------------------------------------------------------------
DB = { ready = false }

CreateThread(function()
    local sql = LoadResourceFile(GetCurrentResourceName(), 'sql/install.sql')
    if not sql then
        print('^1[fks-banking] sql/install.sql is missing^0')
        return
    end
    sql = sql:gsub('%-%-[^\n]*', '')                  -- comments
    for stmt in (sql .. '\n'):gmatch('(.-);%s*\n') do
        if stmt:find('%S') then
            local ok, err = pcall(MySQL.query.await, stmt)
            if not ok then print(('^1[fks-banking] SQL error: %s^0'):format(tostring(err))) end
        end
    end
    DB.ready = true
end)

function DB.Wait()
    while not DB.ready do Wait(100) end
end

-- a history row of an account, as a query for MySQL.transaction
function DB.TxQuery(acc, kind, currency, amount, after, desc, actor)
    return {
        query = [[INSERT INTO fks_bank_transactions
            (account_id, bank_id, cid, type, currency, amount, balance_after, description, actor_cid, actor_name, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        values = { acc.id, acc.bank_id, acc.cid, kind, currency or 'cash', amount, after, desc,
                   actor and actor.cid or nil, actor and actor.name or nil, os.time() },
    }
end

-- a vault ledger row, as a query
function DB.VaultQuery(bankId, kind, amount, after, desc, actor)
    return {
        query = [[INSERT INTO fks_bank_vault_ledger (bank_id, type, amount, balance_after, description, actor_cid, actor_name, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)]],
        values = { bankId, kind, amount, after, desc, actor and actor.cid or nil, actor and actor.name or nil, os.time() },
    }
end

-- history cleanup (Config.Accounts.HistoryKeepDays), once a day
CreateThread(function()
    DB.Wait()
    while true do
        local days = Config.Accounts.HistoryKeepDays
        if days > 0 then
            MySQL.update.await('DELETE FROM fks_bank_transactions WHERE created_at < ?', { os.time() - days * 86400 })
        end
        Wait(24 * 3600 * 1000)
    end
end)
