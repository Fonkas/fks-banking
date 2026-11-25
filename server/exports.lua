---------------------------------------------------------------------------
-- Server exports for other resources (documented in README.md). `charId` = the character identifier
-- (VORP charidentifier / RSG citizenid). Money changes go through the same locks and history as the game.
--
--   exports['fks-banking']:GetAccountBalance(charId, bankId)              -> cash, gold, bars | nil
--   exports['fks-banking']:GetAccounts(charId)                             -> { { bank, number, cash, gold, bars, frozen } }
--   exports['fks-banking']:AddMoney(charId, bankId, amount, reason)        -> ok, error
--   exports['fks-banking']:RemoveMoney(charId, bankId, amount, reason, ignoreFrozen) -> ok, error
--   exports['fks-banking']:IsFrozen(charId)                                -> bool
--   exports['fks-banking']:FreezeAccounts(charId, byName?)                 -> ok, message
--   exports['fks-banking']:UnfreezeAccounts(charId, byName?)               -> ok, message
--   exports['fks-banking']:CreateBill({ target, amount, reason, issuerName, issuerCid?, kind? }) -> billId | nil, error
--   exports['fks-banking']:GetBills(charId, status?)                       -> { bill rows }
---------------------------------------------------------------------------
local function Res() return GetInvokingResource() or 'console' end

exports('GetAccountBalance', function(charId, bankId)
    local acc = charId and bankId and Acc.Get(charId, bankId)
    if not acc then return nil end
    return Bk.Round(acc.cash), Bk.Round(acc.gold), tonumber(acc.bars) or 0
end)

exports('GetAccounts', function(charId)
    local list = {}
    for _, a in ipairs(Acc.All(charId)) do
        list[#list + 1] = { bank = a.bank_id, label = Bk.BankLabel(a.bank_id), number = a.account_number, cash = Bk.Round(a.cash),
                            gold = Bk.Round(a.gold), bars = a.bars, frozen = IsFrozen(a.cid) }
    end
    return list
end)

exports('AddMoney', function(charId, bankId, amount, reason)
    local acc = charId and bankId and Acc.Get(charId, bankId)
    if not acc then return false, 'no_account' end
    amount = Bk.Money(amount)
    if not amount then return false, 'invalid_amount' end
    return WithLock(AccKey(acc.id), function()
        local ok, err = Acc.Apply(acc.id, 'cash', amount, 'external', Bk.Text(reason, 200) or _L('tx_external', Res()), { name = Res() })
        if not ok then return false, err end
        return true
    end)
end)

exports('RemoveMoney', function(charId, bankId, amount, reason, ignoreFrozen)
    local acc = charId and bankId and Acc.Get(charId, bankId)
    if not acc then return false, 'no_account' end
    if IsFrozen(acc.cid) and not ignoreFrozen then return false, 'frozen' end
    amount = Bk.Money(amount)
    if not amount then return false, 'invalid_amount' end
    return WithLock(AccKey(acc.id), function()
        local ok, err = Acc.Apply(acc.id, 'cash', -amount, 'external', Bk.Text(reason, 200) or _L('tx_external', Res()), { name = Res() })
        if not ok then return false, err end
        return true
    end)
end)

exports('IsFrozen', function(charId) return IsFrozen(charId) end)

exports('FreezeAccounts', function(charId, byName)
    if not charId then return false, 'invalid' end
    return Gov.Freeze(charId, { name = byName or Res() }, nil, nil)
end)

exports('UnfreezeAccounts', function(charId, byName)
    if not charId then return false, 'invalid' end
    return Gov.Unfreeze(charId, { name = byName or Res() })
end)

--[[
    o.target      server id (online player) or character id
    o.amount      money · o.reason text
    o.issuerName  shown as the writer (e.g. 'Sheriff Office') · o.issuerCid optional (gets the money of a personal bill)
    o.kind        'personal' (default; without issuerCid nobody receives the money) | 'company' (o.job = company job)
]]
exports('CreateBill', function(o)
    if type(o) ~= 'table' then return nil, 'invalid' end
    local amount = Bk.Money(o.amount)
    if not amount then return nil, 'invalid_amount' end
    local targetCid, targetName
    local src = tonumber(o.target)
    local T = src and GetPlayerName(src) and Bridge.GetPlayer(src)
    if T then targetCid, targetName = tostring(T.cid), T.name
    else targetCid = tostring(o.target or '') targetName = CharacterName(targetCid) end
    if not targetName or targetCid == '' then return nil, 'invalid_target' end
    local kind = o.kind == 'company' and 'company' or 'personal'
    if kind == 'company' and not (o.job and Bills.CompaniesLinked()) then return nil, 'company_unavailable' end
    local id = Bills.Create({
        kind = kind, issuerCid = o.issuerCid and tostring(o.issuerCid) or nil, issuerName = Bk.Text(o.issuerName, 80) or Res(),
        issuerJob = kind == 'company' and o.job or nil, issuerLabel = Bk.Text(o.issuerLabel, 100),
        targetCid = targetCid, targetName = targetName, amount = amount, reason = Bk.Text(o.reason, Config.Billing.ReasonMax),
    })
    return id
end)

exports('GetBills', function(charId, status)
    local rows
    if status then
        rows = MySQL.query.await('SELECT * FROM fks_bills WHERE target_cid = ? AND status = ? ORDER BY id DESC', { tostring(charId), status })
    else
        rows = MySQL.query.await("SELECT * FROM fks_bills WHERE target_cid = ? AND status <> 'deleted' ORDER BY id DESC", { tostring(charId) })
    end
    local list = {}
    for _, r in ipairs(rows or {}) do list[#list + 1] = Bills.Row(r) end
    return list
end)
