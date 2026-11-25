---------------------------------------------------------------------------
-- Banker tab (client). One page with a row of section pills at the top (horizontal) and the section below:
--   Clients | Loans | Telegraph | Exchange | Vault | Ledger
-- Only the sections of the banker's rank show. Every action is checked again on the server.
---------------------------------------------------------------------------
BankerUI = {}

local st = {}            -- section, clients, client, loans, vault, ledger

function BankerUI.Reset() st = { section = nil } end

local function Info() return Bank.data and Bank.data.banker end
local function Id() return Bank.cur and Bank.cur.id end
local function Money(n) return Fmt(n) end
local function Box(children) return { type = 'grid', cols = 1, class = 'box', children = children } end
local function ClientField() return TargetField('client', _L('client'), Config.Banker.ClientDistance) end

local SECTIONS = {
    { id = 'clients', perm = 'clients', icon = Icon('clients') },
    { id = 'loans', perm = 'loans', icon = Icon('loan') },
    { id = 'telegraph', perm = 'telegraph', icon = Icon('telegraph') },
    { id = 'exchange', perm = 'exchange', icon = Icon('exchange') },
    { id = 'vault', perm = 'vault', icon = Icon('vault') },
    { id = 'ledger', perm = 'bankLedger', icon = Icon('ledger') },
}

local function Sections()
    local info = Info()
    local list = {}
    for _, s in ipairs(SECTIONS) do
        if info.perms[s.perm] then list[#list + 1] = s end
    end
    return list
end

---------------------------------------------------------------------------
-- Sections
---------------------------------------------------------------------------
local function ClientDetail(c)
    local info = Info()
    local body = {
        { type = 'section', label = c.name },
        { type = 'kv', cols = 4, items = {
            { label = _L('account_number'), value = c.number },
            { label = _L('in_account'), value = Money(c.cash), tone = 'gold' },
            { label = _L('cur_gold'), value = Bk.Gold(c.gold) },
            { label = _L('cur_bars'), value = c.locked > 0 and _L('bars_with_locked', c.bars, c.locked) or tostring(c.bars) },
            { label = _L('opened_on'), value = Bk.Date(c.created) },
            { label = _L('status'), value = c.frozen and _L('frozen') or _L('active'), tone = c.frozen and 'bad' or 'good' },
        } },
    }
    if c.storage then
        body[#body + 1] = { type = 'kv', cols = 4, items = {
            { label = _L('my_box'), value = _L('tier_' .. c.storage.tier) },
            { label = _L('rent'), value = Money(c.storage.rent) },
            { label = _L('discount'), value = c.storage.discount .. '%' },
            { label = _L('status'), value = _L('box_' .. c.storage.status), tone = c.storage.status == 'active' and 'good' or 'bad' },
        } }
        if info.perms.discounts then
            body[#body + 1] = { type = 'button', small = true, style = 'ghost', icon = Icon('discount'), label = _L('set_discount'), action = 'bb:discount', value = c.storage.id,
                prompt = { title = _L('set_discount'), text = _L('discount_text', Config.Banker.MaxRentDiscount, Money(c.storage.base)), fields = {
                    { type = 'number', name = 'pct', label = _L('discount_pct'), value = c.storage.discount, min = 0, max = Config.Banker.MaxRentDiscount, step = 5 } } } }
        end
    end
    if c.history then
        body[#body + 1] = HistoryTable(c.history, { name = 'clientHistory', height = 22 })
    else
        body[#body + 1] = { type = 'text', style = 'note', text = _L('ledger_rank_note') }
    end
    return Box(body)
end

local function ClientsSection()
    local info = Info()
    local body = {}
    local rows = {}
    for _, c in ipairs(st.clients or {}) do
        rows[#rows + 1] = { value = c.id, tone = c.frozen and 'bad' or nil, cells = {
            name = c.name, number = c.number, cash = { text = Money(c.cash), tone = 'gold' }, gold = Bk.Gold(c.gold),
            bars = tostring(c.bars), since = Bk.Date(c.created), status = c.frozen and { text = _L('frozen'), tone = 'bad' } or _L('active') },
            sort = { cash = c.cash, bars = c.bars, since = c.created }, search = c.cid }
    end
    local left = {
        { type = 'section', label = _L('find_client') },
        { type = 'row', children = {
            { type = 'input', name = 'q', placeholder = _L('find_client_ph'), max = 60 },
            { type = 'button', small = true, icon = 'search', label = _L('search'), action = 'bb:search' },
        } },
        { type = 'table', name = 'clients', height = 22, action = 'bb:client', selected = st.client and st.client.id or nil,
          rows = rows, sort = { key = 'name', dir = 'asc' }, empty = _L('no_clients'), count = _L('showing_count'), columns = {
            { key = 'name', label = _L('col_client'), sort = true }, { key = 'number', label = _L('account_number') },
            { key = 'cash', label = _L('in_account'), align = 'right', sort = true }, { key = 'gold', label = _L('cur_gold'), align = 'right' },
            { key = 'bars', label = _L('cur_bars'), align = 'right', sort = true }, { key = 'status', label = _L('status') } } },
    }
    local cards = { Box(left) }
    if info.perms.openAccounts then
        cards[#cards + 1] = Box({
            { type = 'section', label = _L('assisted_opening') },
            { type = 'text', style = 'desc', text = _L('assisted_opening_desc', Money(Config.Accounts.OpeningFee)) },
            ClientField(),
            { type = 'button', wide = true, icon = Icon('account'), label = _L('open_account_btn'), action = 'bb:open', requires = 'client' },
        })
    end
    body[#body + 1] = { type = 'grid', template = #cards > 1 and 'minmax(0, 2.2fr) minmax(0, 1fr)' or nil, cols = #cards, children = cards }
    if st.client then body[#body + 1] = ClientDetail(st.client) end
    return body
end

local LOAN_TONE = { proposed = 'gold', active = 'good', paid = 'good', defaulted = 'bad', declined = 'muted', expired = 'muted' }

local function LoansSection()
    local info = Info()
    local s = Bank.data.services.loans
    local col = {}
    for _, k in ipairs({ 'none', 'bars', 'item' }) do
        if s.collateral[k] and (k ~= 'bars' or Config.GoldBars.Enabled) then col[#col + 1] = { value = k, label = _L('collateral_' .. k) } end
    end
    local intervals = {}
    for _, h in ipairs(s.intervals) do intervals[#intervals + 1] = { value = tostring(h), label = _L('every_hours', h) } end

    local form = Box({
        { type = 'section', label = _L('new_loan') },
        ClientField(),
        { type = 'grid', cols = 3, children = {
            { type = 'number', name = 'amount', label = _L('amount'), value = s.min, min = s.min, max = info.maxLoan, step = 10, quick = { 50, 100, 500 } },
            { type = 'number', name = 'interest', label = _L('loan_interest'), value = s.minInterest, min = s.minInterest, max = s.maxInterest, step = 1 },
            { type = 'number', name = 'installments', label = _L('loan_installments'), value = s.minInstallments, min = s.minInstallments, max = s.maxInstallments, step = 1 },
        } },
        { type = 'grid', cols = 2, children = {
            { type = 'dropdown', name = 'interval', label = _L('loan_every'), options = intervals, value = intervals[1] and intervals[1].value },
            { type = 'segmented', name = 'collateral', label = _L('loan_collateral'), options = col, value = col[1] and col[1].value },
        } },
        { type = 'grid', cols = 4, children = {
            { type = 'number', name = 'bars', label = _L('collateral_bars_n'), value = 0, min = 0, max = Config.GoldBars.MaxPerAccount, step = 1 },
            { type = 'input', name = 'item', label = _L('collateral_item_name'), max = 60, optional = true, placeholder = 'pocket_watch' },
            { type = 'number', name = 'itemAmount', label = _L('quantity'), value = 1, min = 1, max = 1000, step = 1 },
            { type = 'number', name = 'itemValue', label = _L('collateral_value'), value = 0, min = 0, max = info.maxLoan, step = 10 },
        } },
        { type = 'text', style = 'note', text = _L('loan_form_note', Money(info.maxLoan), s.minInterestNone, s.proposalMinutes) },
        { type = 'button', wide = true, icon = Icon('loan'), label = _L('propose_loan'), action = 'bb:loan', requires = 'client' },
    })

    local rows = {}
    for _, l in ipairs(st.loans or {}) do
        rows[#rows + 1] = { value = l.id, tone = l.status == 'defaulted' and 'bad' or (l.status == 'proposed' and 'gold' or nil), cells = {
            id = '#' .. l.id, client = l.client, principal = Money(l.principal), total = Money(l.total),
            paid = ('%s (%d/%d)'):format(Money(l.paid), l.paidInstallments, l.installments), banker = l.banker or _L('auto_mode'),
            status = { text = _L('loan_status_' .. l.status), tone = LOAN_TONE[l.status] }, at = Bk.Date(l.created) },
            sort = { at = l.created, principal = l.principal }, data = { status = l.status },
            actions = l.status == 'proposed' and { { label = _L('cancel'), style = 'ghost', action = 'bb:loanCancel',
                confirm = { title = _L('cancel_proposal'), text = _L('cancel_proposal_confirm', l.client), danger = true } } } or nil }
    end
    local statusOpts = { { value = '', label = _L('all') } }
    for _, k in ipairs({ 'proposed', 'active', 'paid', 'defaulted', 'declined', 'expired' }) do statusOpts[#statusOpts + 1] = { value = k, label = _L('loan_status_' .. k) } end
    return {
        form,
        { type = 'section', label = _L('bank_loans') },
        { type = 'table', name = 'bankLoans', height = 24, rows = rows, sort = { key = 'at', dir = 'desc' }, search = { placeholder = _L('search') },
          filters = { { key = 'status', label = _L('status'), options = statusOpts, value = '' } }, empty = _L('no_loans'), columns = {
            { key = 'id', label = _L('col_number') }, { key = 'client', label = _L('col_client'), sort = true },
            { key = 'principal', label = _L('loan_principal'), align = 'right', sort = true }, { key = 'total', label = _L('loan_total'), align = 'right' },
            { key = 'paid', label = _L('loan_paid'), align = 'right' }, { key = 'banker', label = _L('banker') },
            { key = 'status', label = _L('status') }, { key = 'at', label = _L('col_date'), sort = true } } },
    }
end

local function TelegraphSection()
    local tg = Bank.data.services.telegraph
    return { { type = 'grid', cols = 2, class = 'fill', children = {
        Box({
            { type = 'section', label = _L('telegraph') },
            ClientField(),
            { type = 'input', name = 'to', label = _L('target_account'), placeholder = 'BLW-123456', max = 20 },
            { type = 'number', name = 'tamount', label = _L('amount'), value = 10, min = 0.01, max = tg.max, step = 1, quick = { 10, 100, 1000 } },
            { type = 'button', wide = true, icon = Icon('telegraph'), label = _L('send_telegraph'), action = 'bb:telegraph', requires = 'client' },
        }),
        Box({
            { type = 'section', label = _L('how_it_works') },
            { type = 'kv', cols = 2, items = {
                { label = _L('fee'), value = _L('fee_fmt', tg.fee, Money(tg.minFee)) },
                { label = _L('delay'), value = tg.delay > 0 and _L('minutes_fmt', tg.delay) or _L('immediate') },
                { label = _L('max_amount'), value = Money(tg.max) },
            } },
            { type = 'text', style = 'note', text = _L('telegraph_banker_note') },
        }),
    } } }
end

local function ExchangeSection()
    local s = Bank.data.services
    local cards = {}
    if s.exchange then
        local ex = s.exchange
        cards[#cards + 1] = Box({
            { type = 'section', label = _L('gold_exchange') },
            { type = 'kv', cols = 3, items = {
                { label = _L('bank_buys'), value = Money(ex.buy), tone = 'good' },
                { label = _L('bank_sells'), value = Money(ex.sell), tone = 'bad' },
                { label = _L('vault_stock'), value = _L('n_bars', ex.stock) },
            } },
            ClientField(),
            { type = 'segmented', name = 'mode', options = { { value = 'buy', label = _L('bank_buys') }, { value = 'sell', label = _L('bank_sells') } }, value = 'buy' },
            { type = 'number', name = 'qty', label = _L('quantity'), value = 1, min = 1, max = ex.max, step = 1, quick = { 1, 10, 50 } },
            { type = 'button', wide = true, icon = Icon('exchange'), label = _L('do_exchange'), action = 'bb:exchange', requires = 'client' },
        })
    end
    if s.appraisal then
        local opts = {}
        for _, it in ipairs(s.appraisal.items) do opts[#opts + 1] = { value = it.item, label = ('%s · %s'):format(it.label, Money(it.value)) } end
        cards[#cards + 1] = Box({
            { type = 'section', label = _L('appraisal') },
            { type = 'text', style = 'desc', text = _L('appraisal_desc') },
            ClientField(),
            { type = 'dropdown', name = 'aitem', label = _L('item'), options = opts, value = opts[1] and opts[1].value },
            { type = 'number', name = 'aqty', label = _L('quantity'), value = 1, min = 1, max = s.appraisal.max, step = 1, quick = { 1, 10 } },
            { type = 'button', wide = true, icon = Icon('appraise'), label = _L('appraise'), action = 'bb:appraise', requires = 'client' },
        })
    end
    return { { type = 'grid', cols = math.max(#cards, 1), class = 'fill', children = cards } }
end

local VAULT_TONE = { held = 'gold', stock = 'good', ['return'] = 'muted' }

local function VaultSection()
    local v = st.vault
    if not v then return { { type = 'empty', text = _L('loading') } } end
    local items = {}
    for _, it in ipairs(v.items) do
        items[#items + 1] = { value = it.id, cells = {
            item = it.label, amount = tostring(it.amount), status = { text = _L('vitem_' .. it.status), tone = VAULT_TONE[it.status] },
            loan = it.loan and ('#' .. it.loan) or '-', at = Bk.Date(it.at) }, sort = { at = it.at },
            actions = it.status == 'stock' and { { label = _L('take'), action = 'bb:vaultItem',
                confirm = { title = _L('take'), text = _L('take_item_confirm', it.amount, it.label) } } } or nil }
    end
    local ledger = {}
    for _, r in ipairs(v.ledger) do
        ledger[#ledger + 1] = { value = r.id, cells = {
            at = Bk.Date(r.at), type = _L('vl_type_' .. r.type), desc = r.desc or '', who = r.actor or _L('system'),
            amount = { text = (r.amount > 0 and '+' or '') .. Money(r.amount), tone = r.amount > 0 and 'good' or (r.amount < 0 and 'bad' or nil) },
            after = Money(r.after) }, sort = { at = r.at, amount = r.amount }, data = { type = r.type } }
    end
    local cards = {
        Box({
            { type = 'section', label = _L('vault') },
            { type = 'kv', cols = 2, class = 'big', items = {
                { label = _L('vault_balance'), value = Money(v.balance), tone = 'gold' },
                { label = _L('vault_stock'), value = _L('n_bars', v.bars) },
            } },
            { type = 'row', align = 'center', children = {
                { type = 'button', small = true, icon = Icon('deposit'), label = _L('deposit'), action = 'bb:vaultMove', value = 'deposit',
                  prompt = { title = _L('vault_deposit'), text = _L('deposit_text', Money(v.cash)), fields = {
                      { type = 'number', name = 'amount', label = _L('amount'), value = 100, min = 0.01, max = Config.MaxTransaction, step = 10, quick = { 100, 1000, 10000 } } } } },
                { type = 'button', small = true, style = 'ghost', icon = Icon('withdraw'), label = _L('withdraw'), action = 'bb:vaultMove', value = 'withdraw',
                  prompt = { title = _L('vault_withdraw'), text = _L('vault_withdraw_text', Money(v.balance)), fields = {
                      { type = 'number', name = 'amount', label = _L('amount'), value = 100, min = 0.01, max = Config.MaxTransaction, step = 10, quick = { 100, 1000, 10000 } } } } },
                v.bars > 0 and { type = 'button', small = true, style = 'ghost', icon = Icon('bars'), label = _L('take_bars'), action = 'bb:vaultBars',
                  prompt = { title = _L('take_bars'), fields = { { type = 'number', name = 'amount', label = _L('quantity'), value = 1, min = 1, max = v.bars, step = 1 } } } } or nil,
            } },
            { type = 'text', style = 'note', text = _L('vault_note') },
        }),
    }
    if v.salaries then
        local rows = {}
        for _, s in ipairs(v.salaries) do
            rows[#rows + 1] = { value = s.rank, cells = { rank = s.name, amount = Money(s.amount) },
                actions = { { label = _L('edit'), style = 'ghost', action = 'bb:salary', prompt = { title = _L('salary_of', s.name), fields = {
                    { type = 'number', name = 'amount', label = _L('amount'), value = s.amount, min = 0, max = v.salaryMax, step = 1 } } } } } }
        end
        cards[#cards + 1] = Box({
            { type = 'section', label = _L('salaries') },
            { type = 'text', style = 'note', text = _L('salaries_note', v.salaryEvery, Money(v.salaryMax)) },
            { type = 'table', rows = rows, height = 16, columns = { { key = 'rank', label = _L('rank') }, { key = 'amount', label = _L('amount'), align = 'right' } } },
        })
    end
    cards[#cards + 1] = Box({
        { type = 'section', label = _L('vault_items') },
        { type = 'table', name = 'vaultItems', rows = items, height = 16, sort = { key = 'at', dir = 'desc' }, empty = _L('no_items'), columns = {
            { key = 'item', label = _L('item') }, { key = 'amount', label = _L('quantity'), align = 'right' },
            { key = 'status', label = _L('status') }, { key = 'loan', label = _L('loan') } } },
    })
    return {
        { type = 'grid', cols = #cards, class = 'fill', children = cards },
        { type = 'section', label = _L('vault_ledger') },
        { type = 'table', name = 'vaultLedger', rows = ledger, height = 24, sort = { key = 'at', dir = 'desc' }, search = { placeholder = _L('search') },
          empty = _L('no_history'), count = _L('showing_count'), columns = {
            { key = 'at', label = _L('col_date'), sort = true, width = '14%' }, { key = 'type', label = _L('col_type'), sort = true },
            { key = 'desc', label = _L('col_description') }, { key = 'who', label = _L('col_by') },
            { key = 'amount', label = _L('col_amount'), align = 'right', sort = true }, { key = 'after', label = _L('col_balance'), align = 'right' } } },
    }
end

local function LedgerSection()
    if not st.ledger then return { { type = 'empty', text = _L('loading') } } end
    return { HistoryTable(st.ledger, { name = 'bankLedger', who = true, height = 44 }) }
end

local BUILD = { clients = ClientsSection, loans = LoansSection, telegraph = TelegraphSection, exchange = ExchangeSection, vault = VaultSection, ledger = LedgerSection }

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------
function BankerUI.Page()
    local info = Info()
    local secs = Sections()
    if #secs == 0 then return { body = { { type = 'empty', text = _L('no_permission') } } } end
    local ok = false
    for _, s in ipairs(secs) do if s.id == st.section then ok = true end end
    if not ok then st.section = secs[1].id end
    -- first time this section shows: load its data (e.g. the banker tab is the first page)
    local sec = st.section
    if (sec == 'clients' and not st.clients) or (sec == 'loans' and not st.loans) or (sec == 'vault' and not st.vault) or (sec == 'ledger' and not st.ledger) then
        BankerUI.Load(sec)
    end
    local opts = {}
    for _, s in ipairs(secs) do opts[#opts + 1] = { value = s.id, label = _L('bsec_' .. s.id), icon = s.icon } end
    local body = {
        { type = 'row', align = 'center', children = {
            { type = 'badges', items = { { text = info.rankName, tone = 'gold' } } },
            { type = 'segmented', id = 'bsec', options = opts, value = st.section, action = 'bb:section' },
        } },
    }
    for _, n in ipairs(BUILD[st.section]()) do body[#body + 1] = n end
    return { body = body }
end

-- data a section needs from the server
function BankerUI.Load(section)
    local bankId = Id()
    if section == 'clients' and not st.clients then
        local ok, list = Call('bk:clients', bankId, '')
        if ok then st.clients = list end
    elseif section == 'loans' then
        local ok, list = Call('bk:loans', bankId)
        if ok then st.loans = list end
    elseif section == 'vault' then
        local ok, v = Call('bk:vault', bankId)
        if ok then st.vault = v end
    elseif section == 'ledger' then
        local ok, list = Call('bk:bankLedger', bankId)
        if ok then st.ledger = list end
    end
end

function BankerUI.OnOpen()
    if not Info() then return end
    local secs = Sections()
    if not st.section and secs[1] then st.section = secs[1].id end
    BankerUI.Load(st.section)
    return { page = BankerUI.Page() }
end

-- redraws the banker page after an action (fresh bank data + this section's data)
local function Redraw(ok, msg)
    if not ok then return { ok = false, error = msg } end
    PlaySoundFrontend('PURCHASE', 'Ledger_Sounds', true, 0)
    Bank.Fetch()
    BankerUI.Load(st.section)
    if st.section == 'clients' and st.client then
        local okc, c = Call('bk:client', Id(), st.client.id)
        st.client = okc and c or nil
    end
    return { toast = { text = msg, type = 'success' }, page = BankerUI.Page() }
end

---------------------------------------------------------------------------
-- Handlers
---------------------------------------------------------------------------
UI.On('bb:section', function(d)
    st.section = d.value
    BankerUI.Load(st.section)
    return { page = BankerUI.Page() }
end)

UI.On('bb:search', function(d)
    local ok, list = Call('bk:clients', Id(), (d.values or {}).q or '')
    if not ok then return { ok = false, error = list } end
    st.clients, st.client = list, nil
    return { page = BankerUI.Page() }
end)

UI.On('bb:client', function(d)
    local ok, c = Call('bk:client', Id(), d.value)
    if not ok then return { ok = false, error = c } end
    st.client = c
    return { page = BankerUI.Page() }
end)

UI.On('bb:open', function(d)
    UI.Toast(_L('waiting_client'), 'inform')
    return Redraw(Call('bk:open', Id(), tonumber((d.values or {}).client)))
end)

UI.On('bb:discount', function(d)
    return Redraw(Call('bk:discount', Id(), d.value, tonumber((d.values or {}).pct)))
end)

UI.On('bb:loan', function(d)
    local v = d.values or {}
    return Redraw(Call('bk:loan', Id(), {
        target = tonumber(v.client), amount = tonumber(v.amount), interest = tonumber(v.interest),
        installments = tonumber(v.installments), interval = tonumber(v.interval), collateral = v.collateral,
        bars = tonumber(v.bars), item = v.item, itemAmount = tonumber(v.itemAmount), itemValue = tonumber(v.itemValue),
    }))
end)

UI.On('bb:loanCancel', function(d) return Redraw(Call('bk:loanCancel', Id(), d.value)) end)

UI.On('bb:telegraph', function(d)
    local v = d.values or {}
    UI.Toast(_L('waiting_client'), 'inform')
    return Redraw(Call('bk:telegraph', Id(), tonumber(v.client), v.to, tonumber(v.tamount)))
end)

UI.On('bb:exchange', function(d)
    local v = d.values or {}
    UI.Toast(_L('waiting_client'), 'inform')
    return Redraw(Call('bk:exchange', Id(), tonumber(v.client), v.mode or 'buy', tonumber(v.qty)))
end)

UI.On('bb:appraise', function(d)
    local v = d.values or {}
    UI.Toast(_L('waiting_client'), 'inform')
    return Redraw(Call('bk:appraise', Id(), tonumber(v.client), v.aitem, tonumber(v.aqty)))
end)

UI.On('bb:vaultMove', function(d) return Redraw(Call('bk:vaultMove', Id(), d.value, tonumber((d.values or {}).amount))) end)
UI.On('bb:vaultItem', function(d) return Redraw(Call('bk:vaultItem', Id(), d.value)) end)
UI.On('bb:vaultBars', function(d) return Redraw(Call('bk:vaultBars', Id(), tonumber((d.values or {}).amount))) end)
UI.On('bb:salary', function(d) return Redraw(Call('bk:salary', Id(), d.value, tonumber((d.values or {}).amount))) end)
