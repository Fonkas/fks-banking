---------------------------------------------------------------------------
-- Government (section 7): every bill, search, delete, freeze / unfreeze accounts, action log.
--
-- Freezing a character freezes ALL their accounts in every bank (and any account they open later). Blocked:
-- deposits, withdrawals, gold, gold bars, transfers, loans and bill payments from the bank; the gold bars stop
-- earning. Still working: vault boxes and the automatic rent / loan installments. The player is told at once
-- when online, or on their next login.
---------------------------------------------------------------------------
Gov = {}

local G = Config.Government

local function Log(action, actor, targetCid, targetName, billId, details)
    MySQL.insert.await([[INSERT INTO fks_bank_frozen_log (action, actor_cid, actor_name, actor_job, target_cid, target_name, bill_id, details, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
        action, actor and actor.cid or nil, actor and actor.name or _L('system'), actor and actor.job or nil,
        targetCid, targetName, billId, details, os.time(),
    })
end

-- freezes every account of `cid`. actor = { cid, name, job } | nil (export / console)
function Gov.Freeze(cid, actor, billId, name)
    cid = tostring(cid)
    if IsFrozen(cid) then return false, _L('already_frozen') end
    name = name or CharacterName(cid) or cid
    -- pay the gold bar earnings up to now: from here on the frozen time is lost
    for _, r in ipairs(MySQL.query.await('SELECT id FROM fks_bank_accounts WHERE cid = ? AND bars > 0', { cid }) or {}) do
        GoldBars.SettleId(r.id, false)
    end
    local now = os.time()
    local ok = MySQL.transaction.await({
        { query = 'INSERT INTO fks_bank_frozen (cid, name, bill_id, frozen_by, frozen_at) VALUES (?, ?, ?, ?, ?)',
          values = { cid, name, billId, actor and actor.name or _L('system'), now } },
        { query = 'UPDATE fks_bank_accounts SET frozen = 1 WHERE cid = ?', values = { cid } },
    })
    if not ok then return false, _L('error') end
    FrozenSet[cid] = { cid = cid, name = name, bill_id = billId, frozen_by = actor and actor.name, frozen_at = now }
    Log('freeze', actor, cid, name, billId, billId and _L('log_freeze_bill', Bills.Number(billId)) or nil)
    NotifyCid(cid, 'frozen_notice', {}, 'error')
    Webhook('Government', _L('wh_frozen'), _L('wh_frozen_text', actor and actor.name or _L('system'), name),
        { billId and { _L('wh_bill'), Bills.Number(billId) } or { _L('wh_bill'), '-' } })
    TriggerEvent('fks-banking:server:frozen', cid, true)
    return true, _L('frozen_done', name)
end

function Gov.Unfreeze(cid, actor)
    cid = tostring(cid)
    if not IsFrozen(cid) then return false, _L('not_frozen') end
    local name = FrozenSet[cid] and FrozenSet[cid].name or CharacterName(cid) or cid
    local ok = MySQL.transaction.await({
        { query = 'DELETE FROM fks_bank_frozen WHERE cid = ?', values = { cid } },
        -- the gold bars start earning again from now (the frozen time is not paid)
        { query = 'UPDATE fks_bank_accounts SET frozen = 0, last_payout_at = ?, offline_since = NULL WHERE cid = ?', values = { os.time(), cid } },
    })
    if not ok then return false, _L('error') end
    FrozenSet[cid] = nil
    Log('unfreeze', actor, cid, name, nil, nil)
    NotifyCid(cid, 'unfrozen_notice', {}, 'success')
    Webhook('Government', _L('wh_unfrozen'), _L('wh_unfrozen_text', actor and actor.name or _L('system'), name))
    TriggerEvent('fks-banking:server:frozen', cid, false)
    return true, _L('unfrozen_done', name)
end

local function Me(P)
    if not Bills.IsGov(P) then return nil, _L('no_permission') end
    return { cid = tostring(P.cid), name = P.name, job = P.job }
end

-- server ids of every character online: [cid] = src
local function OnlineMap()
    local map = {}
    for _, id in ipairs(GetPlayers()) do
        local P = Bridge.GetPlayer(tonumber(id))
        if P then map[tostring(P.cid)] = tonumber(id) end
    end
    return map
end

---------------------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------------------
-- scope: 'active' (unsigned + unpaid) | 'all'
Callback('gov:bills', function(src, P, scope)
    local actor, err = Me(P)
    if not actor then return false, err end
    local where = scope == 'all' and "status <> 'deleted'" or "status IN ('unsigned', 'unpaid')"
    local rows = MySQL.query.await(('SELECT * FROM fks_bills WHERE %s ORDER BY id DESC LIMIT ?'):format(where), { G.MaxRows }) or {}
    local online = OnlineMap()
    local list = {}
    for _, r in ipairs(rows) do
        local row = Bills.Row(r, online)
        row.frozen = IsFrozen(r.target_cid)
        list[#list + 1] = row
    end
    return true, list
end, { noLimit = true })

Callback('gov:delete', function(src, P, id)
    local actor, err = Me(P)
    if not actor then return false, err end
    local bill = Bills.ById(id)
    if not bill or bill.status == 'deleted' then return false, _L('bill_invalid') end
    if MySQL.update.await("UPDATE fks_bills SET status = 'deleted' WHERE id = ? AND status <> 'deleted'", { bill.id }) ~= 1 then return false, _L('bill_invalid') end
    local details = _L('log_delete_bill_details', Bills.Number(bill.id), bill.issuer_label or bill.issuer_name, Bk.Fmt(bill.amount), _L('status_' .. bill.status))
    Log('delete_bill', actor, bill.target_cid, bill.target_name, bill.id, details)
    Webhook('Government', _L('wh_bill_deleted'), _L('wh_bill_deleted_text', actor.name, Bills.Number(bill.id), bill.target_name, Bk.Fmt(bill.amount)))
    return true, _L('bill_deleted', Bills.Number(bill.id))
end)

-- freeze the debtor of a bill
Callback('gov:freeze', function(src, P, billId)
    local actor, err = Me(P)
    if not actor then return false, err end
    local bill = Bills.ById(billId)
    if not bill then return false, _L('bill_invalid') end
    return Gov.Freeze(bill.target_cid, actor, bill.id, bill.target_name)
end)

-- unfreeze a character (from a bill, the frozen list or the people search)
Callback('gov:unfreeze', function(src, P, cid)
    local actor, err = Me(P)
    if not actor then return false, err end
    if type(cid) ~= 'string' and type(cid) ~= 'number' then return false, _L('error') end
    return Gov.Unfreeze(cid, actor)
end)

-- every frozen character
Callback('gov:frozen', function(src, P)
    local actor, err = Me(P)
    if not actor then return false, err end
    local online = OnlineMap()
    local list = {}
    for _, r in ipairs(MySQL.query.await('SELECT * FROM fks_bank_frozen ORDER BY frozen_at DESC') or {}) do
        list[#list + 1] = { cid = r.cid, name = r.name, bill = r.bill_id and Bills.Number(r.bill_id) or nil, by = r.frozen_by,
                            at = r.frozen_at, src = online[tostring(r.cid)] }
    end
    return true, list
end, { noLimit = true })

-- people search (name, character id or server id) among account holders and bill debtors, also for
-- characters whose bill was deleted
Callback('gov:people', function(src, P, query)
    local actor, err = Me(P)
    if not actor then return false, err end
    query = Bk.Text(query, 60)
    if not query then return true, {} end
    local online = OnlineMap()
    local bySrc = tonumber(query)
    local cidFromSrc
    if bySrc and GetPlayerName(bySrc) then
        local T = Bridge.GetPlayer(bySrc)
        cidFromSrc = T and tostring(T.cid) or nil
    end
    local like = '%' .. query:gsub('[%%_]', '') .. '%'
    local rows = MySQL.query.await([[
        SELECT cid, MAX(name) AS name FROM (
            SELECT cid, owner_name AS name FROM fks_bank_accounts WHERE owner_name LIKE ? OR cid = ? OR cid = ?
            UNION ALL SELECT target_cid AS cid, target_name AS name FROM fks_bills WHERE target_name LIKE ? OR target_cid = ? OR target_cid = ?
            UNION ALL SELECT cid, name FROM fks_bank_frozen WHERE name LIKE ? OR cid = ? OR cid = ?
        ) x GROUP BY cid LIMIT 50]], { like, query, cidFromSrc or '', like, query, cidFromSrc or '', like, query, cidFromSrc or '' }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        local accounts = tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM fks_bank_accounts WHERE cid = ?', { r.cid })) or 0
        list[#list + 1] = { cid = tostring(r.cid), name = r.name, frozen = IsFrozen(r.cid), accounts = accounts, src = online[tostring(r.cid)] }
    end
    return true, list
end)

Callback('gov:log', function(src, P)
    local actor, err = Me(P)
    if not actor then return false, err end
    local list = {}
    for _, r in ipairs(MySQL.query.await('SELECT * FROM fks_bank_frozen_log ORDER BY id DESC LIMIT ?', { G.LogRows }) or {}) do
        list[#list + 1] = { id = r.id, action = r.action, actor = r.actor_name, target = r.target_name, targetCid = r.target_cid,
                            bill = r.bill_id and Bills.Number(r.bill_id) or nil, details = r.details, at = r.created_at }
    end
    return true, list
end, { noLimit = true })
