---------------------------------------------------------------------------
-- Bills (client): /billing and /mybills, drawn by fks-core in the wide layout.
--   /billing   Write | Manage bills | Frozen accounts | Log      (the last three: government jobs only)
--   /mybills   To sign | To pay | Paid | Written by me
---------------------------------------------------------------------------
if not Config.Billing.Enabled then return end

local BC = Config.Billing
local Money = function(n) return Fmt(n) end
local function Box(children) return { type = 'grid', cols = 1, class = 'box', children = children } end

local meta, gov = nil, { scope = 'active', bills = nil, frozen = nil, people = nil, log = nil }
local mine = nil

local KIND_TONE = { personal = nil, company = 'gold', bank = 'bad' }
local STATUS_TONE = { unsigned = 'gold', unpaid = 'bad', paid = 'good', refused = 'muted', deleted = 'muted' }

local function Issuer(b) return b.issuerLabel or b.issuer end

---------------------------------------------------------------------------
-- /billing: write a bill
---------------------------------------------------------------------------
local function WritePage()
    local kinds = { { value = 'personal', label = _L('bill_personal') } }
    if meta.company then kinds[#kinds + 1] = { value = 'company', label = _L('bill_company') } end
    return { body = {
        { type = 'grid', template = 'minmax(0, 1.4fr) minmax(0, 1fr)', cols = 2, class = 'fill', children = {
            Box({
                { type = 'section', label = _L('new_bill') },
                #kinds > 1 and { type = 'segmented', name = 'kind', options = kinds, value = 'personal' } or nil,
                TargetField('target', _L('bill_to'), BC.MaxDistance),
                { type = 'number', name = 'amount', label = _L('amount'), value = meta.min, min = meta.min, max = meta.max, step = 1, quick = { 5, 10, 50, 100 } },
                { type = 'textarea', name = 'reason', label = _L('bill_reason'), max = meta.reasonMax, placeholder = _L('bill_reason_ph') },
                { type = 'button', wide = true, icon = Icon('bill'), label = _L('send_bill'), action = 'bl:create', requires = 'target' },
            }),
            Box({
                { type = 'section', label = _L('how_it_works') },
                { type = 'kv', cols = 1, items = {
                    { label = _L('bill_from'), value = meta.name },
                    { label = _L('bill_company_as'), value = meta.company or nil, tone = 'gold' },
                    { label = _L('amount_range'), value = ('%s - %s'):format(Money(meta.min), Money(meta.max)) },
                    { label = _L('max_distance'), value = meta.maxDistance > 0 and _L('meters_fmt', math.floor(meta.maxDistance)) or _L('anywhere') },
                } },
                { type = 'text', style = 'note', text = _L('bill_how', BC.MyBillsCommand) },
            }),
        } },
    } }
end

---------------------------------------------------------------------------
-- /billing: government pages
---------------------------------------------------------------------------
local function BillsTable(list)
    local rows = {}
    for _, b in ipairs(list or {}) do
        local acts = { { label = _L('delete'), style = 'danger', action = 'bg:delete',
            confirm = { title = _L('delete_bill'), text = _L('delete_bill_confirm', b.number, b.target, Money(b.amount)), danger = true } } }
        if b.status == 'unpaid' or b.status == 'unsigned' then
            if b.frozen then
                acts[#acts + 1] = { label = _L('unfreeze'), style = 'ghost', action = 'bg:unfreeze', value = b.targetCid,
                    confirm = { title = _L('unfreeze'), text = _L('unfreeze_confirm', b.target) } }
            else
                acts[#acts + 1] = { label = _L('freeze'), action = 'bg:freeze',
                    confirm = { title = _L('freeze'), text = _L('freeze_confirm', b.target, b.number), danger = true } }
            end
        end
        rows[#rows + 1] = {
            value = b.id, tone = b.frozen and 'bad' or (b.status == 'unpaid' and 'gold' or nil),
            cells = {
                number = b.number, kind = { text = _L('kind_' .. b.kind), tone = KIND_TONE[b.kind] }, issuer = Issuer(b),
                target = b.targetSrc and ('%s [%d]'):format(b.target, b.targetSrc) or b.target, signed = b.signedName or '-',
                amount = { text = Money(b.amount), tone = 'gold' }, reason = b.reason or '', created = Bk.Date(b.created),
                signedAt = b.signedAt and Bk.Date(b.signedAt) or '-', days = b.daysUnpaid and _L('days_fmt', b.daysUnpaid) or '-',
                status = { text = _L('status_' .. b.status), tone = STATUS_TONE[b.status] },
            },
            sort = { number = b.id, amount = b.amount, created = b.created, signedAt = b.signedAt or 0, days = b.daysUnpaid or -1 },
            data = { status = b.status, kind = b.kind },
            -- the search also finds: character ids, server ids, the company job
            search = table.concat({ b.targetCid or '', b.issuerCid or '', b.job or '', b.targetSrc and tostring(b.targetSrc) or '',
                                    b.issuerSrc and tostring(b.issuerSrc) or '', b.issuer or '' }, ' '),
            actions = acts,
        }
    end
    local statusOpts = { { value = '', label = _L('all') } }
    for _, s in ipairs({ 'unsigned', 'unpaid', 'paid', 'refused' }) do statusOpts[#statusOpts + 1] = { value = s, label = _L('status_' .. s) } end
    return {
        type = 'table', name = 'govBills', height = 40, rows = rows, sort = { key = 'created', dir = 'desc' },
        search = { placeholder = _L('gov_search_ph') }, empty = _L('no_bills'), count = _L('showing_count'),
        filters = {
            { key = 'status', label = _L('status'), options = statusOpts, value = '' },
            { key = 'kind', label = _L('col_type'), value = '', options = { { value = '', label = _L('all') },
                { value = 'personal', label = _L('kind_personal') }, { value = 'company', label = _L('kind_company') }, { value = 'bank', label = _L('kind_bank') } } },
        },
        columns = {
            { key = 'number', label = _L('col_number'), sort = true }, { key = 'kind', label = _L('col_type') },
            { key = 'issuer', label = _L('col_issuer'), sort = true }, { key = 'target', label = _L('col_target'), sort = true },
            { key = 'signed', label = _L('col_signed') }, { key = 'amount', label = _L('col_amount'), align = 'right', sort = true },
            { key = 'reason', label = _L('bill_reason') }, { key = 'created', label = _L('col_issued'), sort = true },
            { key = 'signedAt', label = _L('col_signed_at'), sort = true }, { key = 'days', label = _L('col_days'), align = 'right', sort = true },
            { key = 'status', label = _L('status') },
        },
    }
end

local function ManagePage()
    if not gov.bills then return { body = { { type = 'empty', text = _L('loading') } } } end
    return { body = {
        { type = 'row', align = 'center', children = {
            { type = 'segmented', id = 'govScope', options = { { value = 'active', label = _L('scope_active') }, { value = 'all', label = _L('scope_all') } },
              value = gov.scope, action = 'bg:scope' },
        } },
        BillsTable(gov.bills),
    } }
end

local function PeopleTable(list, name, empty)
    local rows = {}
    for _, p in ipairs(list or {}) do
        rows[#rows + 1] = {
            value = p.cid, tone = p.frozen and 'bad' or nil,
            cells = { name = p.src and ('%s [%d]'):format(p.name or '?', p.src) or (p.name or '?'), cid = tostring(p.cid),
                      bill = p.bill or '-', by = p.by or '-', at = p.at and Bk.Date(p.at) or '-',
                      status = p.frozen == false and { text = _L('active'), tone = 'good' } or { text = _L('frozen'), tone = 'bad' } },
            sort = { at = p.at or 0 },
            actions = p.frozen ~= false and { { label = _L('unfreeze'), action = 'bg:unfreeze',
                confirm = { title = _L('unfreeze'), text = _L('unfreeze_confirm', p.name or p.cid) } } } or nil,
        }
    end
    return { type = 'table', name = name, height = 24, rows = rows, sort = { key = 'at', dir = 'desc' }, empty = empty, columns = {
        { key = 'name', label = _L('col_client'), sort = true }, { key = 'cid', label = _L('col_cid') }, { key = 'status', label = _L('status') },
        { key = 'bill', label = _L('col_bill') }, { key = 'by', label = _L('col_by') }, { key = 'at', label = _L('col_date'), sort = true } } }
end

local function FrozenPage()
    local frozen = {}
    for _, f in ipairs(gov.frozen or {}) do f.frozen = true frozen[#frozen + 1] = f end
    return { body = {
        { type = 'grid', template = 'minmax(0, 1fr) minmax(0, 1.4fr)', cols = 2, children = {
            Box({
                { type = 'section', label = _L('find_person') },
                { type = 'text', style = 'desc', text = _L('find_person_desc') },
                { type = 'row', children = {
                    { type = 'input', name = 'pq', placeholder = _L('find_person_ph'), max = 60 },
                    { type = 'button', small = true, icon = 'search', label = _L('search'), action = 'bg:people' },
                } },
                gov.people and PeopleTable(gov.people, 'govPeople', _L('no_results')) or nil,
            }),
            Box({
                { type = 'section', label = _L('frozen_accounts') },
                gov.frozen and PeopleTable(frozen, 'govFrozen', _L('no_frozen')) or { type = 'empty', text = _L('loading') },
            }),
        } },
    } }
end

local function LogPage()
    if not gov.log then return { body = { { type = 'empty', text = _L('loading') } } } end
    local rows = {}
    for _, r in ipairs(gov.log) do
        rows[#rows + 1] = { value = r.id, tone = r.action == 'freeze' and 'bad' or (r.action == 'unfreeze' and 'good' or nil), cells = {
            at = Bk.Date(r.at), action = _L('log_' .. r.action), actor = r.actor or _L('system'), target = r.target or '-',
            bill = r.bill or '-', details = r.details or '' }, sort = { at = r.at }, data = { action = r.action } }
    end
    return { body = {
        { type = 'table', name = 'govLog', height = 44, rows = rows, sort = { key = 'at', dir = 'desc' }, search = { placeholder = _L('search') },
          empty = _L('no_history'), count = _L('showing_count'),
          filters = { { key = 'action', label = _L('col_action'), value = '', options = { { value = '', label = _L('all') },
              { value = 'freeze', label = _L('log_freeze') }, { value = 'unfreeze', label = _L('log_unfreeze') }, { value = 'delete_bill', label = _L('log_delete_bill') } } } },
          columns = { { key = 'at', label = _L('col_date'), sort = true, width = '14%' }, { key = 'action', label = _L('col_action') },
              { key = 'actor', label = _L('col_by'), sort = true }, { key = 'target', label = _L('col_target'), sort = true },
              { key = 'bill', label = _L('col_bill') }, { key = 'details', label = _L('col_details') } } },
    } }
end

local function BillingView(page)
    local tabs, pages = { { page = 'write', label = _L('tab_write') } }, { write = WritePage() }
    if meta.gov then
        tabs[#tabs + 1] = { page = 'manage', label = _L('tab_manage') }
        tabs[#tabs + 1] = { page = 'frozen', label = _L('tab_frozen') }
        tabs[#tabs + 1] = { page = 'log', label = _L('tab_log') }
        pages.manage, pages.frozen, pages.log = ManagePage(), FrozenPage(), LogPage()
    end
    return { eyebrow = _L('billing_eyebrow'), title = _L('billing_title'), page = page or 'write', tabs = #tabs > 1 and tabs or nil,
             pages = pages, layout = 'wide', hints = { { 'ESC', _L('close') } } }
end

local function GovLoad(page)
    if page == 'manage' then
        local ok, list = Call('gov:bills', gov.scope)
        if ok then gov.bills = list else return false, list end
    elseif page == 'frozen' then
        local ok, list = Call('gov:frozen')
        if ok then gov.frozen = list else return false, list end
    elseif page == 'log' then
        local ok, list = Call('gov:log')
        if ok then gov.log = list else return false, list end
    end
    return true
end

local function GovPage(page)
    if page == 'manage' then return ManagePage() elseif page == 'frozen' then return FrozenPage() elseif page == 'log' then return LogPage() end
end

-- after a government action: reload the open page
local function GovRedraw(ok, msg, page)
    if not ok then return { ok = false, error = msg } end
    GovLoad(page)
    if page == 'frozen' and gov.people then
        local pq = gov.lastQuery
        if pq then local okp, list = Call('gov:people', pq) if okp then gov.people = list end end
    end
    return { toast = { text = msg, type = 'success' }, page = GovPage(page) }
end

RegisterCommand(BC.Command, function()
    if UI.IsOpen() then return end
    local ok, m = Call('bill:meta')
    if not ok then Notify(m, 'error') return end
    meta, gov = m, { scope = 'active' }
    OpenView('billing', BillingView('write'))
end, false)

OnUIPage(function(d)
    if ActiveView ~= 'billing' or not meta or not meta.gov then return end
    if d.to == 'manage' or d.to == 'frozen' or d.to == 'log' then
        local ok, err = GovLoad(d.to)
        if not ok then return { ok = false, error = err } end
        return { page = GovPage(d.to) }
    end
end)

UI.On('bl:create', function(d)
    local v = d.values or {}
    local ok, msg = Call('bill:create', v.kind or 'personal', tonumber(v.target), tonumber(v.amount), v.reason)
    if not ok then return { ok = false, error = msg } end
    PlaySoundFrontend('INFO', 'HUD_SHOP_SOUNDSET', true, 0)
    return { toast = { text = msg, type = 'success' }, close = true }
end)

UI.On('bg:scope', function(d)
    gov.scope = d.value == 'all' and 'all' or 'active'
    local ok, err = GovLoad('manage')
    if not ok then return { ok = false, error = err } end
    return { page = ManagePage() }
end)

UI.On('bg:delete', function(d)
    local ok, msg = Call('gov:delete', d.value)
    return GovRedraw(ok, msg, 'manage')
end)
UI.On('bg:freeze', function(d)
    local ok, msg = Call('gov:freeze', d.value)
    return GovRedraw(ok, msg, 'manage')
end)
UI.On('bg:unfreeze', function(d)
    local ok, msg = Call('gov:unfreeze', d.value)
    return GovRedraw(ok, msg, d.page or 'manage')
end)

UI.On('bg:people', function(d)
    local q = (d.values or {}).pq or ''
    local ok, list = Call('gov:people', q)
    if not ok then return { ok = false, error = list } end
    gov.people, gov.lastQuery = list, q
    return { page = FrozenPage() }
end)

---------------------------------------------------------------------------
-- /mybills
---------------------------------------------------------------------------
local function BillDoc(b, signable)
    return {
        { type = 'kv', cols = 3, items = {
            { label = _L('col_number'), value = b.number },
            { label = _L('bill_from'), value = Issuer(b), tone = b.kind ~= 'personal' and 'gold' or nil },
            { label = _L('bill_to'), value = b.target },
            { label = _L('col_amount'), value = Money(b.amount), tone = 'gold' },
            { label = _L('col_issued'), value = Bk.Date(b.created) },
            { label = _L('status'), value = _L('status_' .. b.status), tone = STATUS_TONE[b.status] },
            { label = _L('col_days'), value = b.daysUnpaid and _L('days_fmt', b.daysUnpaid) or nil, tone = 'bad' },
            { label = _L('paid_on'), value = b.paidAt and Bk.Date(b.paidAt) or nil, tone = 'good' },
        } },
        b.reason and { type = 'text', style = 'desc', text = b.reason } or nil,
        { type = 'signature', name = b.signedName, date = b.signedAt and Bk.Date(b.signedAt) or nil, label = _L('signature_debtor'),
          pending = signable and _L('awaiting_your_signature') or _L('awaiting_signature') },
    }
end

local function PayAction(b)
    local opts = { { value = 'cash', label = _L('pay_with_cash', Money(mine.cash)) } }
    for _, a in ipairs(mine.accounts or {}) do
        opts[#opts + 1] = { value = 'bank:' .. a.bank, label = _L('pay_with_bank', a.label, Money(a.cash)) }
    end
    if #opts == 1 then
        return { label = _L('pay'), icon = Icon('pay'), action = 'mb:pay', value = b.id,
                 confirm = { title = _L('pay_bill'), text = _L('pay_bill_cash', Money(b.amount), Issuer(b)) } }
    end
    return { label = _L('pay'), icon = Icon('pay'), action = 'mb:pay', value = b.id,
             prompt = { title = _L('pay_bill'), text = _L('pay_bill_text', Money(b.amount), Issuer(b)), fields = {
                 { type = 'dropdown', name = 'via', label = _L('pay_from'), options = opts, value = 'cash' } } } }
end

local function BillList(list, kind)
    if #list == 0 then return { type = 'empty', text = _L('no_bills') } end
    local items = {}
    for _, b in ipairs(list) do
        local actions
        if kind == 'sign' then
            actions = {
                { label = _L('sign'), icon = Icon('sign'), action = 'mb:sign', confirm = { title = _L('sign_bill'), text = _L('sign_bill_confirm', b.number, Money(b.amount), Issuer(b)) } },
                { label = _L('refuse'), style = 'ghost', action = 'mb:refuse', confirm = { title = _L('refuse_bill'), text = _L('refuse_bill_confirm', b.number), danger = true } },
            }
        elseif kind == 'pay' then
            actions = { PayAction(b) }
        end
        items[#items + 1] = {
            value = b.id, title = ('%s · %s'):format(b.number, kind == 'issued' and b.target or Issuer(b)),
            tag = Money(b.amount), sub = ('%s · %s'):format(_L('status_' .. b.status), Bk.Date(b.created)),
            flag = (b.daysUnpaid and b.daysUnpaid > 0) and { text = _L('days_fmt', b.daysUnpaid), tone = 'bad' } or nil,
            details = BillDoc(b, kind == 'sign'), actions = actions,
        }
    end
    return { type = 'list', items = items }
end

local function MyBillsView(page)
    local tabs = {
        { page = 'sign', label = _L('tab_to_sign', #mine.toSign) }, { page = 'pay', label = _L('tab_to_pay', #mine.toPay) },
        { page = 'paid', label = _L('tab_paid') }, { page = 'issued', label = _L('tab_issued') },
    }
    local note = { type = 'text', style = 'note', text = BC.AllowBankPayment and _L('mybills_note_bank') or _L('mybills_note_cash') }
    return {
        eyebrow = _L('mybills_eyebrow'), title = _L('mybills_title'), page = page or (#mine.toSign > 0 and 'sign' or 'pay'), tabs = tabs, layout = 'wide',
        footer = { money = { cash = mine.cash } },
        pages = {
            sign = { body = { { type = 'text', style = 'desc', text = _L('to_sign_desc') }, BillList(mine.toSign, 'sign') } },
            pay = { body = { note, BillList(mine.toPay, 'pay') } },
            paid = { body = { BillList(mine.history, 'paid') } },
            issued = { body = { BillList(mine.issued, 'issued') } },
        },
        hints = { { 'ESC', _L('close') } },
    }
end

local function MyFetch()
    local ok, d = Call('bill:mine')
    if ok then mine = d end
    return ok, d
end

local function MyRedraw(ok, msg)
    if not ok then return { ok = false, error = msg } end
    PlaySoundFrontend('PURCHASE', 'Ledger_Sounds', true, 0)
    MyFetch()
    return { toast = { text = msg, type = 'success' }, view = MyBillsView() }
end

RegisterCommand(BC.MyBillsCommand, function()
    if UI.IsOpen() then return end
    local ok, err = MyFetch()
    if not ok then Notify(err, 'error') return end
    OpenView('mybills', MyBillsView())
end, false)

UI.On('mb:sign', function(d) return MyRedraw(Call('bill:sign', d.value)) end)
UI.On('mb:refuse', function(d) return MyRedraw(Call('bill:refuse', d.value)) end)
UI.On('mb:pay', function(d) return MyRedraw(Call('bill:pay', d.value, (d.values or {}).via or 'cash')) end)

OnUIClose(function(_, view)
    if view == 'billing' then meta = nil end
    if view == 'mybills' then mine = nil end
end)

-- chat suggestions
CreateThread(function()
    Wait(2000)
    TriggerEvent('chat:addSuggestion', '/' .. BC.Command, _L('cmd_billing_help'), {})
    TriggerEvent('chat:addSuggestion', '/' .. BC.MyBillsCommand, _L('cmd_mybills_help'), {})
end)
