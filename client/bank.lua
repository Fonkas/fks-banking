---------------------------------------------------------------------------
-- The bank menu (client). Built only from fks-core components in the wide (landscape) layout:
-- the sections sit side by side as tabs and each section's content opens below, in rows of cards.
--   Account | Gold | Bars | Vault box | Loans | Services | Banker
-- A tab only shows when its feature is on and the player can use it. The server re-checks everything.
---------------------------------------------------------------------------
Bank = { cur = nil, data = nil, page = nil }

local function D() return Bank.data end
local function Id() return Bank.cur and Bank.cur.id end

-- refreshes the data from the server (false + error when the server refuses, e.g. walked away)
function Bank.Fetch()
    local ok, data = Call('bank:data', Id(), GameHour())
    if ok then Bank.data = data end
    return ok, data
end

local function Money(n) return Fmt(n) end
local function Box(children, extra)
    local b = { type = 'grid', cols = 1, class = 'box', children = children }
    if extra then for k, v in pairs(extra) do b[k] = v end end
    return b
end
local function NumberPrompt(title, text, max, value, quick)
    return { title = title, text = text, fields = { { type = 'number', name = 'amount', label = _L('amount'),
        value = value or 1, min = 0.01, max = max or Config.MaxTransaction, step = 1, quick = quick or { 10, 100, 1000 } } } }
end
local function CountPrompt(title, text, max)
    return { title = title, text = text, fields = { { type = 'number', name = 'amount', label = _L('quantity'),
        value = math.min(1, math.max(max or 1, 1)), min = 1, max = math.max(max or 1, 1), step = 1, quick = { 1, 10, 50 } } } }
end

---------------------------------------------------------------------------
-- History table (shared with the banker screens)
---------------------------------------------------------------------------
function HistoryTable(rows, opts)
    opts = opts or {}
    local list = {}
    local types = {}
    for _, r in ipairs(rows or {}) do
        local unit = r.currency == 'gold' and 'gold' or (r.currency == 'bars' and 'bars' or 'cash')
        local amount = unit == 'gold' and Bk.Gold(r.amount) or (unit == 'bars' and _L('n_bars', r.amount) or Money(r.amount))
        local after = unit == 'gold' and Bk.Gold(r.after) or (unit == 'bars' and _L('n_bars', r.after) or Money(r.after))
        list[#list + 1] = {
            value = r.id,
            cells = {
                at = Bk.Date(r.at), type = _L('tx_type_' .. r.type), desc = r.desc or '', who = r.name or r.actor or '',
                amount = { text = (r.amount > 0 and '+' or '') .. amount, tone = r.amount > 0 and 'good' or (r.amount < 0 and 'bad' or nil) },
                after = after,
            },
            sort = { at = r.at, amount = r.amount },
            data = { type = r.type, currency = unit },
        }
        types[r.type] = true
    end
    local typeOptions = { { value = '', label = _L('all') } }
    for t in pairs(types) do typeOptions[#typeOptions + 1] = { value = t, label = _L('tx_type_' .. t) } end
    table.sort(typeOptions, function(a, b) return a.value == '' or (b.value ~= '' and a.label < b.label) end)
    local columns = {
        { key = 'at', label = _L('col_date'), sort = true, width = '14%' },
        { key = 'type', label = _L('col_type'), sort = true, width = '14%' },
        { key = 'desc', label = _L('col_description') },
    }
    if opts.who then columns[#columns + 1] = { key = 'who', label = _L('col_client'), sort = true } end
    columns[#columns + 1] = { key = 'amount', label = _L('col_amount'), align = 'right', sort = true }
    columns[#columns + 1] = { key = 'after', label = _L('col_balance'), align = 'right' }
    return {
        type = 'table', name = opts.name or 'history', height = opts.height or 30,
        columns = columns, rows = list, sort = { key = 'at', dir = 'desc' },
        search = { placeholder = _L('search_history') },
        filters = {
            { key = 'type', label = _L('col_type'), options = typeOptions, value = '' },
            { key = 'currency', label = _L('col_currency'), value = '', options = {
                { value = '', label = _L('all') }, { value = 'cash', label = _L('cur_cash') },
                { value = 'gold', label = _L('cur_gold') }, { value = 'bars', label = _L('cur_bars') } } },
        },
        empty = _L('no_history'), count = _L('showing_count'),
    }
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------
local function NoAccountPage()
    local d = D()
    return { body = {
        { type = 'grid', cols = 2, class = 'fill', children = {
            Box({
                { type = 'section', label = _L('open_account') },
                { type = 'text', text = _L('open_account_desc', d.bank.label) },
                { type = 'kv', cols = 2, class = 'big', items = {
                    { label = _L('opening_fee'), value = d.openingFee > 0 and Money(d.openingFee) or _L('free'), tone = 'gold' },
                    { label = _L('cash_on_hand'), value = Money(d.cash) },
                } },
                { type = 'button', wide = true, icon = Icon('account'), label = _L('open_account_btn'), action = 'bk:open',
                  confirm = { title = _L('open_account'), text = _L('open_account_confirm', d.bank.label, Money(d.openingFee)) } },
            }),
            Box({
                { type = 'section', label = _L('how_it_works') },
                { type = 'text', style = 'desc', text = _L('how_accounts') },
                { type = 'text', style = 'note', text = _L('how_accounts_note') },
            }),
        } },
    } }
end

local function AccountPage()
    local d = D()
    local a = d.account
    if not a then return NoAccountPage() end
    local A = Config.Accounts
    local limits = {}
    if A.MaxDepositPerOperation > 0 then limits[#limits + 1] = _L('limit_deposit', Money(A.MaxDepositPerOperation)) end
    if A.MaxWithdrawPerDay > 0 then limits[#limits + 1] = _L('limit_withdraw', Money(A.MaxWithdrawPerDay)) end

    local cards = {
        Box({
            { type = 'section', label = _L('balance') },
            { type = 'kv', cols = 2, class = 'big', items = {
                { label = _L('in_account'), value = Money(a.cash), tone = 'gold' },
                { label = _L('cash_on_hand'), value = Money(d.cash) },
            } },
            { type = 'kv', cols = 2, items = {
                { label = _L('account_number'), value = a.number },
                { label = _L('holder'), value = d.name },
                { label = _L('opened_on'), value = Bk.Date(a.created) },
                { label = _L('bank'), value = d.bank.label },
            } },
        }),
        Box({
            { type = 'section', label = _L('cash_moves') },
            { type = 'row', align = 'center', children = {
                { type = 'button', icon = Icon('deposit'), label = _L('deposit'), action = 'bk:dep',
                  prompt = NumberPrompt(_L('deposit'), _L('deposit_text', Money(d.cash)), A.MaxDepositPerOperation > 0 and A.MaxDepositPerOperation or nil, math.min(10, math.max(d.cash, 0.01))) },
                { type = 'button', icon = Icon('withdraw'), style = 'ghost', label = _L('withdraw'), action = 'bk:wd',
                  prompt = NumberPrompt(_L('withdraw'), _L('withdraw_text', Money(a.cash)), nil, math.min(10, math.max(a.cash, 0.01))) },
            } },
            #limits > 0 and { type = 'text', style = 'note', text = table.concat(limits, ' · ') } or nil,
        }),
    }
    local tg = d.services and d.services.telegraph
    if tg then
        cards[#cards + 1] = Box({
            { type = 'section', label = _L('telegraph') },
            { type = 'text', style = 'desc', text = _L('telegraph_desc', tg.fee, tg.delay) },
            tg.self and { type = 'button', wide = true, icon = Icon('telegraph'), label = _L('send_telegraph'), action = 'bk:tself',
                prompt = { title = _L('send_telegraph'), text = _L('telegraph_self_text', tg.fee, Money(tg.max)), fields = {
                    { type = 'input', name = 'to', label = _L('target_account'), placeholder = 'VAL-123456', max = 20, required = true },
                    { type = 'number', name = 'amount', label = _L('amount'), value = 10, min = 0.01, max = tg.max, step = 1, quick = { 10, 100, 1000 } },
                } } }
                or { type = 'text', style = 'note', text = _L('telegraph_needs_banker') },
        })
    end
    return { body = {
        { type = 'grid', cols = #cards, class = 'fill', children = cards },
        { type = 'section', label = _L('history') },
        HistoryTable(a.history),
    } }
end

local function GoldPage()
    local d = D()
    local a = d.account
    return { body = {
        { type = 'grid', cols = 2, class = 'fill', children = {
            Box({
                { type = 'section', label = _L('gold_balance') },
                { type = 'kv', cols = 2, class = 'big', items = {
                    { label = _L('in_account'), value = Bk.Gold(a.gold), tone = 'gold' },
                    { label = _L('gold_on_hand'), value = Bk.Gold(d.gold.onHand) },
                } },
                { type = 'text', style = 'note', text = _L('gold_note') },
            }),
            Box({
                { type = 'section', label = _L('gold_moves') },
                { type = 'row', align = 'center', children = {
                    { type = 'button', icon = Icon('goldcoin'), label = _L('deposit'), action = 'bk:gdep',
                      prompt = NumberPrompt(_L('deposit_gold'), _L('deposit_gold_text', Bk.Gold(d.gold.onHand)), Config.GoldCurrency.MaxDepositPerOperation > 0 and Config.GoldCurrency.MaxDepositPerOperation or nil, 1, { 1, 5, 10 }) },
                    { type = 'button', icon = Icon('goldcoin'), style = 'ghost', label = _L('withdraw'), action = 'bk:gwd',
                      prompt = NumberPrompt(_L('withdraw_gold'), _L('withdraw_gold_text', Bk.Gold(a.gold)), nil, 1, { 1, 5, 10 }) },
                } },
            }),
        } },
    } }
end

local function ExchangeBox(ex)
    return Box({
        { type = 'section', label = _L('gold_exchange') },
        { type = 'kv', cols = 3, items = {
            { label = _L('bank_buys'), value = Money(ex.buy), tone = 'good' },
            { label = _L('bank_sells'), value = Money(ex.sell), tone = 'bad' },
            { label = _L('vault_stock'), value = _L('n_bars', ex.stock) },
        } },
        { type = 'text', style = 'note', text = _L('auto_mode_note', Config.Banker.AutoModeFeeMultiplier) },
        { type = 'row', align = 'center', children = {
            { type = 'button', small = true, icon = Icon('sellbars'), label = _L('sell_bars'), action = 'bk:exself', value = 'buy',
              prompt = CountPrompt(_L('sell_bars'), _L('sell_bars_text', Money(ex.buy)), ex.max) },
            { type = 'button', small = true, style = 'ghost', icon = Icon('buybars'), label = _L('buy_bars'), action = 'bk:exself', value = 'sell',
              prompt = CountPrompt(_L('buy_bars'), _L('buy_bars_text', Money(ex.sell)), math.min(ex.max, math.max(ex.stock, 1))) },
        } },
    })
end

local function BarsPage()
    local d = D()
    local a, b = d.account, d.bars
    local free = a.bars - a.locked
    return { body = {
        { type = 'grid', cols = 3, class = 'fill', children = {
            Box({
                { type = 'section', label = _L('bars_invested') },
                { type = 'kv', cols = 2, class = 'big', items = {
                    { label = _L('in_this_bank'), value = ('%d / %d'):format(a.bars, b.max), tone = 'gold' },
                    { label = _L('on_hand'), value = tostring(b.onHand) },
                } },
                { type = 'kv', cols = 2, items = {
                    { label = _L('bars_locked'), value = a.locked > 0 and _L('n_bars', a.locked) or nil, tone = 'bad' },
                    { label = _L('bars_max_total'), value = _L('n_bars', b.max * b.banks) },
                } },
            }),
            Box({
                { type = 'section', label = _L('bars_yield') },
                { type = 'kv', cols = 2, items = {
                    { label = _L('per_payout', b.interval), value = Money(b.perPayout), tone = 'good' },
                    { label = _L('per_day'), value = Money(b.perDay) },
                    { label = _L('earned_today'), value = Money(b.today) },
                    { label = _L('daily_cap'), value = b.cap > 0 and Money(b.cap) or _L('no_cap') },
                } },
                b.nextIn and { type = 'timers', items = { { label = _L('next_payout'), seconds = b.nextIn } } } or nil,
                { type = 'text', style = 'note', text = _L('bars_formula', b.rate, b.interval, b.offlineHours) },
            }),
            Box({
                { type = 'section', label = _L('bars_moves') },
                { type = 'row', align = 'center', children = {
                    { type = 'button', icon = Icon('bars'), label = _L('deposit'), action = 'bk:bdep', disabled = b.onHand < 1 or a.bars >= b.max,
                      prompt = CountPrompt(_L('deposit_bars'), _L('deposit_bars_text', b.label, b.max - a.bars), math.min(b.onHand, b.max - a.bars)) },
                    { type = 'button', icon = Icon('bars'), style = 'ghost', label = _L('withdraw'), action = 'bk:bwd', disabled = free < 1,
                      prompt = CountPrompt(_L('withdraw_bars'), _L('withdraw_bars_text', free), free) },
                } },
                a.locked > 0 and { type = 'text', style = 'note', text = _L('bars_locked_note', a.locked) } or nil,
            }),
        } },
    } }
end

local STATUS_TONE = { active = 'good', overdue = 'gold', locked = 'bad' }

local function StoragePage()
    local d = D()
    local s = d.storage
    local box = s.box
    local tiers = {}
    for _, t in ipairs(s.tiers) do
        local current = box and box.tier == t.id
        local btn
        if not box then
            btn = { type = 'button', wide = true, icon = Icon('box'), label = _L('rent'), action = 'bk:rent', value = t.id,
                    confirm = { title = _L('rent_title', _L('tier_' .. t.id)), text = _L('rent_confirm', Money(t.rent), s.cycle) } }
        elseif not current then
            btn = { type = 'button', wide = true, small = true, style = 'ghost', label = _L('change_to'), action = 'bk:stier', value = t.id,
                    confirm = { title = _L('change_tier'), text = _L('change_tier_confirm', _L('tier_' .. t.id)) } }
        else
            btn = { type = 'badges', items = { { text = _L('current'), tone = 'gold' } } }
        end
        tiers[#tiers + 1] = Box({
            { type = 'section', label = _L('tier_' .. t.id) },
            { type = 'kv', cols = 2, items = {
                { label = _L('space'), value = tostring(t.space) },
                { label = _L('rent_per', s.cycle), value = Money(t.rent), tone = 'gold' },
            } },
            btn,
        })
    end
    local body = {}
    if box then
        local actions = {}
        if box.status ~= 'locked' then
            actions[#actions + 1] = { type = 'button', icon = Icon('box'), label = _L('open_box'), action = 'bk:sopen', pulse = true }
        end
        if box.debt > 0 then
            if not d.frozen then actions[#actions + 1] = { type = 'button', small = true, label = _L('pay_from_account'), action = 'bk:spay', value = 'account',
                confirm = { title = _L('pay_debt'), text = _L('pay_debt_confirm', Money(box.debt)) } } end
            actions[#actions + 1] = { type = 'button', small = true, style = 'ghost', label = _L('pay_cash'), action = 'bk:spay', value = 'cash',
                confirm = { title = _L('pay_debt'), text = _L('pay_debt_confirm', Money(box.debt)) } }
        end
        body[#body + 1] = { type = 'grid', cols = 2, class = 'fill', children = {
            Box({
                { type = 'section', label = _L('my_box') },
                { type = 'kv', cols = 3, items = {
                    { label = _L('size'), value = _L('tier_' .. box.tier) },
                    { label = _L('space'), value = tostring(box.space) },
                    { label = _L('status'), value = _L('box_' .. box.status), tone = STATUS_TONE[box.status] },
                    { label = _L('rent_per', s.cycle), value = Money(box.rent), tone = 'gold' },
                    { label = _L('discount'), value = box.discount > 0 and (box.discount .. '%') or nil, tone = 'good' },
                    { label = _L('next_rent'), value = Bk.Date(box.nextDue) },
                    { label = _L('debt'), value = box.debt > 0 and Money(box.debt) or nil, tone = 'bad' },
                    { label = _L('locks_on'), value = box.lockAt and Bk.Date(box.lockAt) or nil, tone = 'bad' },
                } },
                box.status == 'locked' and { type = 'text', style = 'note', text = _L('box_locked_note') }
                    or { type = 'text', style = 'note', text = _L('box_rent_note', s.grace) },
            }),
            Box({
                { type = 'section', label = _L('actions') },
                { type = 'row', align = 'center', children = actions },
                not d.frozen and { type = 'button', small = true, style = 'danger', label = _L('end_rental'), action = 'bk:scancel',
                    confirm = { title = _L('end_rental'), text = _L('end_rental_confirm'), danger = true } } or nil,
            }),
        } }
        if not d.frozen then
            body[#body + 1] = { type = 'section', label = _L('change_tier') }
            body[#body + 1] = { type = 'grid', cols = #tiers, class = 'fill', children = tiers }
        end
    else
        body[#body + 1] = { type = 'text', style = 'desc', text = _L('storage_desc', s.cycle, s.grace) }
        body[#body + 1] = { type = 'grid', cols = #tiers, class = 'fill', children = tiers }
    end
    return { body = body }
end

---------------------------------------------------------------------------
-- Loans (client side): proposals to sign, active loans, history
---------------------------------------------------------------------------
local LOAN_TONE = { proposed = 'gold', active = 'good', paid = 'good', defaulted = 'bad', declined = 'bad', expired = 'bad' }

function LoanTerms(l)
    local col = l.collateral == 'bars' and _L('n_bars', l.bars)
        or (l.collateral == 'item' and ('%dx %s'):format(l.itemAmount, l.itemLabel or l.item) or _L('collateral_none'))
    return { type = 'kv', cols = 3, items = {
        { label = _L('loan_principal'), value = Money(l.principal), tone = 'gold' },
        { label = _L('loan_interest'), value = l.interest .. '%' },
        { label = _L('loan_total'), value = Money(l.total) },
        { label = _L('loan_installments'), value = _L('installments_fmt', l.installments, Money(l.installment)) },
        { label = _L('loan_every'), value = _L('every_hours', l.interval) },
        { label = _L('loan_collateral'), value = col },
        { label = _L('loan_paid'), value = l.status ~= 'proposed' and ('%s / %s'):format(Money(l.paid), Money(l.total)) or nil },
        { label = _L('next_installment'), value = l.status == 'active' and Bk.Date(l.nextDue) or nil },
        { label = _L('missed'), value = (l.missed or 0) > 0 and tostring(l.missed) or nil, tone = 'bad' },
        { label = _L('banker'), value = l.banker or _L('auto_mode') },
    } }
end

local function LoanDoc(l, d)
    local body = {
        { type = 'section', label = _L('loan_doc', l.id) },
        LoanTerms(l),
    }
    if l.status == 'proposed' then
        body[#body + 1] = { type = 'text', style = 'note', text = _L('loan_sign_note', d.bank.label, Bk.Date(l.expires)) }
        body[#body + 1] = { type = 'signature', label = _L('signature_client'), pending = _L('awaiting_signature') }
        body[#body + 1] = { type = 'row', align = 'center', children = {
            { type = 'button', icon = Icon('sign'), label = _L('sign'), action = 'bk:lsign', value = l.id, pulse = true,
              confirm = { title = _L('sign_loan'), text = _L('sign_loan_confirm', Money(l.principal), Money(l.total), l.installments) } },
            { type = 'button', style = 'ghost', label = _L('decline'), action = 'bk:ldecline', value = l.id,
              confirm = { title = _L('decline'), text = _L('decline_loan_confirm'), danger = true } },
        } }
    else
        body[#body + 1] = { type = 'badges', items = { { text = _L('loan_status_' .. l.status), tone = LOAN_TONE[l.status] } } }
        body[#body + 1] = { type = 'signature', name = l.signedName, date = l.signedAt and Bk.Date(l.signedAt) or nil, label = _L('signature_client'),
                            pending = _L('not_signed') }
    end
    return Box(body)
end

local function LoanRequestBox(s)
    local col = {}
    if s.collateral.none then col[#col + 1] = { value = 'none', label = _L('collateral_none') } end
    if s.collateral.bars and Config.GoldBars.Enabled then col[#col + 1] = { value = 'bars', label = _L('collateral_bars') } end
    local intervals = {}
    for _, h in ipairs(s.intervals) do intervals[#intervals + 1] = { value = tostring(h), label = _L('every_hours', h) } end
    return Box({
        { type = 'section', label = _L('request_loan') },
        { type = 'text', style = 'note', text = _L('auto_mode_note', Config.Banker.AutoModeFeeMultiplier) },
        { type = 'button', wide = true, icon = Icon('loan'), label = _L('request_loan'), action = 'bk:lself',
          prompt = { title = _L('request_loan'), fields = {
              { type = 'number', name = 'amount', label = _L('amount'), value = s.min, min = s.min, max = s.max, step = 10, quick = { 50, 100, 500 } },
              { type = 'number', name = 'interest', label = _L('loan_interest'), value = s.minInterestNone, min = s.minInterest, max = s.maxInterest, step = 1 },
              { type = 'number', name = 'installments', label = _L('loan_installments'), value = s.minInstallments, min = s.minInstallments, max = s.maxInstallments, step = 1 },
              { type = 'dropdown', name = 'interval', label = _L('loan_every'), options = intervals, value = intervals[1] and intervals[1].value },
              { type = 'dropdown', name = 'collateral', label = _L('loan_collateral'), options = col, value = col[1] and col[1].value },
              { type = 'number', name = 'bars', label = _L('collateral_bars_n'), value = 0, min = 0, max = Config.GoldBars.MaxPerAccount, step = 1 },
          } } },
    })
end

local function LoansPage()
    local d = D()
    local open, closed = {}, {}
    for _, l in ipairs(d.loans or {}) do
        if l.status == 'proposed' or l.status == 'active' then open[#open + 1] = LoanDoc(l, d) else closed[#closed + 1] = l end
    end
    local body = {}
    local s = d.services and d.services.loans
    if s and s.self then open[#open + 1] = LoanRequestBox(s) end
    if #open > 0 then
        body[#body + 1] = { type = 'grid', cols = math.min(#open, 2), class = 'fill', children = open }
    else
        body[#body + 1] = { type = 'empty', text = _L('no_open_loans') }
    end
    if #closed > 0 then
        local rows = {}
        for _, l in ipairs(closed) do
            rows[#rows + 1] = { value = l.id, cells = {
                id = '#' .. l.id, principal = Money(l.principal), total = Money(l.total), paid = Money(l.paid),
                status = { text = _L('loan_status_' .. l.status), tone = LOAN_TONE[l.status] }, at = Bk.Date(l.closed or l.created) },
                sort = { at = l.closed or l.created } }
        end
        body[#body + 1] = { type = 'section', label = _L('past_loans') }
        body[#body + 1] = { type = 'table', height = 18, rows = rows, sort = { key = 'at', dir = 'desc' }, columns = {
            { key = 'id', label = _L('col_number') }, { key = 'principal', label = _L('loan_principal'), align = 'right' },
            { key = 'total', label = _L('loan_total'), align = 'right' }, { key = 'paid', label = _L('loan_paid'), align = 'right' },
            { key = 'status', label = _L('status') }, { key = 'at', label = _L('col_date'), sort = true } } }
    end
    return { body = body }
end

-- automatic mode (no banker online): what the counter does by itself
local function ServicesPage()
    local d = D()
    local s = d.services
    local cards = {}
    if s.exchange and s.exchange.self then cards[#cards + 1] = ExchangeBox(s.exchange) end
    if s.appraisal and s.appraisal.self then
        local opts = {}
        for _, it in ipairs(s.appraisal.items) do opts[#opts + 1] = { value = it.item, label = ('%s · %s'):format(it.label, Money(it.value)) } end
        cards[#cards + 1] = Box({
            { type = 'section', label = _L('appraisal') },
            { type = 'text', style = 'desc', text = _L('appraisal_desc') },
            { type = 'button', wide = true, icon = Icon('appraise'), label = _L('appraise'), action = 'bk:apself',
              prompt = { title = _L('appraisal'), fields = {
                  { type = 'dropdown', name = 'item', label = _L('item'), options = opts, value = opts[1] and opts[1].value },
                  { type = 'number', name = 'amount', label = _L('quantity'), value = 1, min = 1, max = s.appraisal.max, step = 1, quick = { 1, 10 } },
              } } },
        })
    end
    return { body = {
        { type = 'text', style = 'note', text = _L('auto_mode_banner', s.mult) },
        #cards > 0 and { type = 'grid', cols = #cards, class = 'fill', children = cards } or { type = 'empty', text = _L('needs_banker') },
    } }
end

---------------------------------------------------------------------------
-- View
---------------------------------------------------------------------------
function Bank.View()
    local d = D()
    local tabs, pages = {}, {}
    local function add(id, label, page) tabs[#tabs + 1] = { page = id, label = label } pages[id] = page end

    if d.frozen then
        -- frozen: only the vault box (section 7.3)
        add('storage', _L('tab_storage'), StoragePage())
    else
        add('account', _L('tab_account'), AccountPage())
        if d.account then
            if d.gold then add('gold', _L('tab_gold'), GoldPage()) end
            if d.bars then add('bars', _L('tab_bars'), BarsPage()) end
            if d.storage then add('storage', _L('tab_storage'), StoragePage()) end
            local loanSelf = d.services and d.services.loans and d.services.loans.self
            if d.loans and (#d.loans > 0 or loanSelf) then add('loans', _L('tab_loans'), LoansPage()) end
        end
        local s = d.services or {}
        if s.auto and ((s.exchange and s.exchange.self) or (s.appraisal and s.appraisal.self)) then add('services', _L('tab_services'), ServicesPage()) end
    end
    if d.banker then
        add('banker', _L('tab_banker'), BankerUI.Page())
    end
    local first = tabs[1] and tabs[1].page
    local page = Bank.page and pages[Bank.page] and Bank.page or first
    return {
        eyebrow = d.frozen and _L('frozen_eyebrow') or _L('bank_eyebrow'), title = d.bank.label, page = page,
        tabs = #tabs > 1 and tabs or nil, pages = pages, layout = 'wide',
        footer = { money = { cash = d.cash, gold = d.gold and d.gold.onHand or nil } },
        hints = { { 'ESC', _L('close') } },
    }
end

-- reloads the data and redraws (answer of most handlers)
local function Refresh(ok, msg)
    if not ok then return { ok = false, error = msg } end
    PlaySoundFrontend('PURCHASE', 'Ledger_Sounds', true, 0)
    local fetched, err = Bank.Fetch()
    if not fetched then return { toast = { text = msg, type = 'success' }, close = true } end
    return { toast = { text = msg, type = 'success' }, view = Bank.View() }
end
Bank.Refresh = Refresh

function Bank.Open(bank)
    if UI.IsOpen() then return end
    Bank.cur, Bank.page = bank, nil
    local ok, data = Call('bank:data', bank.id, GameHour())
    if not ok then Notify(data, 'error') Bank.cur = nil return end
    Bank.data = data
    if data.frozen then
        Notify(_L('frozen_open'), 'error')
        if not (data.storage and data.storage.box) and not data.banker then Bank.cur = nil return end
    end
    BankerUI.Reset()
    if not OpenView('bank', Bank.View()) then Bank.cur = nil return end
    CloseWhenAway(bank, function() return Bank.cur == bank and ActiveView == 'bank' end)
end

OnUIClose(function(_, view)
    if view == 'bank' then Bank.cur, Bank.data, Bank.page = nil, nil, nil end
end)

OnUIPage(function(d)
    if ActiveView ~= 'bank' then return end
    Bank.page = d.to
    if d.to == 'banker' then return BankerUI.OnOpen() end
end)

---------------------------------------------------------------------------
-- Handlers
---------------------------------------------------------------------------
local function Amount(d) return tonumber((d.values or {}).amount) end

UI.On('bk:open', function() return Refresh(Call('acc:open', Id(), GameHour())) end)
UI.On('bk:dep', function(d) return Refresh(Call('acc:deposit', Id(), Amount(d), GameHour())) end)
UI.On('bk:wd', function(d) return Refresh(Call('acc:withdraw', Id(), Amount(d), GameHour())) end)
UI.On('bk:gdep', function(d) return Refresh(Call('gold:deposit', Id(), Amount(d), GameHour())) end)
UI.On('bk:gwd', function(d) return Refresh(Call('gold:withdraw', Id(), Amount(d), GameHour())) end)
UI.On('bk:bdep', function(d) return Refresh(Call('bars:deposit', Id(), Amount(d), GameHour())) end)
UI.On('bk:bwd', function(d) return Refresh(Call('bars:withdraw', Id(), Amount(d), GameHour())) end)
UI.On('bk:rent', function(d) return Refresh(Call('storage:rent', Id(), d.value, GameHour())) end)
UI.On('bk:stier', function(d) return Refresh(Call('storage:tier', Id(), d.value, GameHour())) end)
UI.On('bk:spay', function(d) return Refresh(Call('storage:pay', Id(), d.value, GameHour())) end)
UI.On('bk:scancel', function() return Refresh(Call('storage:cancel', Id(), GameHour())) end)
UI.On('bk:lsign', function(d) return Refresh(Call('loan:sign', d.value, GameHour())) end)
UI.On('bk:ldecline', function(d) return Refresh(Call('loan:decline', d.value)) end)

UI.On('bk:sopen', function()
    local bankId = Id()
    -- the inventory has its own screen: close ours first
    UI.Close()
    local ok, err = Call('storage:open', bankId, GameHour())
    if not ok then Notify(err, 'error') end
end)

UI.On('bk:tself', function(d)
    local v = d.values or {}
    return Refresh(Call('tele:self', Id(), v.to, tonumber(v.amount), GameHour()))
end)

UI.On('bk:exself', function(d) return Refresh(Call('ex:self', Id(), d.value, Amount(d), GameHour())) end)

UI.On('bk:apself', function(d)
    local v = d.values or {}
    return Refresh(Call('appr:self', Id(), v.item, tonumber(v.amount), GameHour()))
end)

UI.On('bk:lself', function(d)
    local v = d.values or {}
    return Refresh(Call('loan:self', Id(), {
        amount = tonumber(v.amount), interest = tonumber(v.interest), installments = tonumber(v.installments),
        interval = tonumber(v.interval), collateral = v.collateral, bars = tonumber(v.bars),
    }, GameHour()))
end)
