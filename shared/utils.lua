---------------------------------------------------------------------------
-- Shared helpers: number validation, money formatting, text cleaning, bank / rank lookups and config checks.
-- Every number that comes from a client goes through Bk.Money / Bk.Int before the server uses it.
---------------------------------------------------------------------------
Bk = {}

-- money: 2 decimals, > 0 and <= Config.MaxTransaction. nil for NaN, inf, negatives, zero, strings...
function Bk.Money(v, allowZero)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    v = math.floor(v * 100 + 0.5) / 100
    if v < 0 or (v == 0 and not allowZero) or v > (Config.MaxTransaction or 1000000) then return nil end
    return v
end

-- rounds any number to cents (internal maths; no limits)
function Bk.Round(v)
    v = tonumber(v) or 0
    if v ~= v or v == math.huge or v == -math.huge then return 0 end
    return math.floor(v * 100 + 0.5) / 100
end

-- whole positive number (bars, items, installments). nil for decimals, NaN, <= 0 or > max
function Bk.Int(v, max)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    if v ~= math.floor(v) or v < 1 then return nil end
    if max and v > max then return nil end
    return v
end

-- "$1,250" / "$12.50"
function Bk.Fmt(n)
    n = tonumber(n) or 0
    local neg = n < 0
    n = math.abs(n)
    local int = math.floor(n)
    local cents = math.floor((n - int) * 100 + 0.5)
    if cents >= 100 then int, cents = int + 1, 0 end
    local s = tostring(int):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    if cents > 0 then s = ('%s.%02d'):format(s, cents) end
    return (neg and '-$' or '$') .. s
end

-- gold amount "12.5 g"
function Bk.Gold(n)
    n = Bk.Round(n)
    local s = (n == math.floor(n)) and tostring(math.floor(n)) or ('%.2f'):format(n)
    return _L('gold_fmt', s)
end

-- trims, collapses spaces, strips control chars and markup; nil when empty / too short
function Bk.Text(v, max, min)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('[%c<>]', ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if max and #v > max then v = v:sub(1, max) end
    if #v < (min or 1) then return nil end
    return v
end

-- The RedM client has no `os` library (server only). The server shares its UTC offset so the client can show
-- the same local times the server writes.
local HAS_OS = type(os) == 'table' and type(os.date) == 'function'
if HAS_OS and IsDuplicityVersion() then
    local now = os.time()
    GlobalState.fksBankingTz = now - os.time(os.date('!*t', now))
end

-- epoch seconds (UTC) -> year, month, day, hour, minute (days-from-civil, H. Hinnant)
local function Civil(t)
    local days, secs = t // 86400, t % 86400
    local z = days + 719468
    local era = (z >= 0 and z or z - 146096) // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    local y = yoe + era * 400 + (m <= 2 and 1 or 0)
    return y, m, d, secs // 3600, secs % 3600 // 60
end

local function Format(t, withTime)
    if HAS_OS then return os.date(withTime and '%Y-%m-%d %H:%M' or '%Y-%m-%d', t) end
    local y, m, d, h, mi = Civil(t + (tonumber(GlobalState.fksBankingTz) or 0))
    if withTime then return ('%04d-%02d-%02d %02d:%02d'):format(y, m, d, h, mi) end
    return ('%04d-%02d-%02d'):format(y, m, d)
end

-- 'YYYY-MM-DD HH:MM'
function Bk.Date(t)
    if not t then return '-' end
    return Format(math.floor(tonumber(t) or 0), true)
end

-- 'YYYY-MM-DD' (daily limits / caps; server side)
function Bk.Day(t)
    return Format(math.floor(tonumber(t) or (HAS_OS and os.time() or GetCloudTimeAsInt())), false)
end

-- "2 d 4 h" / "35 min"
function Bk.Span(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local d, h, m = math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600), math.floor(seconds % 3600 / 60)
    if d > 0 then return _L('span_dh', d, h) end
    if h > 0 then return _L('span_hm', h, m) end
    return _L('span_m', math.max(m, seconds > 0 and 1 or 0))
end

---------------------------------------------------------------------------
-- Banks
---------------------------------------------------------------------------
Bk.Banks = {}            -- [id] = bank (enabled only)
Bk.BankList = {}         -- enabled banks in config order

for _, b in ipairs(Config.Banks or {}) do
    if b.enabled ~= false then
        if type(b.id) ~= 'string' or not b.id:match('^[%w_]+$') then
            print(('^1[fks-banking] config: a bank has an invalid id (%s) - skipped^0'):format(tostring(b.id)))
        elseif Bk.Banks[b.id] then
            print(('^1[fks-banking] config: bank id "%s" is used twice - the second one is skipped^0'):format(b.id))
        else
            b.distance = tonumber(b.distance) or 2.0
            b.prefix = (b.prefix or b.id:sub(1, 3)):upper()
            Bk.Banks[b.id] = b
            Bk.BankList[#Bk.BankList + 1] = b
        end
    end
end

function Bk.Bank(id) return Bk.Banks[id] end
function Bk.BankLabel(id) local b = Bk.Banks[id] return b and b.label or tostring(id) end
function Bk.BankCount() return #Bk.BankList end

-- open now? clock: 'real' uses os.time (server), 'game' uses the hour given by the client
function Bk.IsOpen(bank, gameHour)
    local h = bank.hours
    if not h then return true end
    local hour
    if h.clock == 'real' then
        if not HAS_OS then return true end       -- the client cannot read the real clock: the server checks it
        hour = tonumber(os.date('%H'))
    else
        if gameHour == nil then return true end   -- the server cannot read the game clock: the client checks it
        hour = tonumber(gameHour) or 0
    end
    local open, close = tonumber(h.open) or 0, tonumber(h.close) or 24
    if open <= close then return hour >= open and hour < close end
    return hour >= open or hour < close           -- e.g. 20 -> 4 (open overnight)
end

---------------------------------------------------------------------------
-- Banker ranks / jobs
---------------------------------------------------------------------------
table.sort(Config.Banker.Ranks, function(a, b) return (a.grade or 0) < (b.grade or 0) end)

-- rank index (0-based) and rank table for a grade
function Bk.Rank(grade)
    grade = tonumber(grade) or 0
    local idx, rank
    for i, r in ipairs(Config.Banker.Ranks) do
        if grade >= (r.grade or 0) then idx, rank = i - 1, r end
    end
    return idx, rank
end

-- does `job` make a banker of `bankId`?
function Bk.BankerOf(job, bankId)
    if not Config.Banker.Enabled or not job then return false end
    local banks = Config.Banker.Jobs[job]
    if banks == 'all' then return true end
    if type(banks) == 'table' then
        for _, id in ipairs(banks) do if id == bankId then return true end end
    end
    return false
end

-- company bill jobs / government jobs (job = minimum grade)
function Bk.JobGrade(list, job, grade)
    local min = job and list[job]
    return min ~= nil and (tonumber(grade) or 0) >= (tonumber(min) or 0)
end

function Bk.Tier(id)
    for i, t in ipairs(Config.Storage.Tiers) do if t.id == id then return t, i end end
end

---------------------------------------------------------------------------
-- Config validation: wrong values fall back to safe defaults (with a console warning)
---------------------------------------------------------------------------
local function Warn(path, value, default)
    print(('^3[fks-banking] config %s = %s is not valid, using %s^0'):format(path, tostring(value), tostring(default)))
end

local function Num(tbl, key, path, default, min, max)
    local v = tonumber(tbl[key])
    if not v or v ~= v or (min and v < min) or (max and v > max) then
        Warn(path, tbl[key], default)
        tbl[key] = default
    else
        tbl[key] = v
    end
end

do
    local C = Config
    Num(C, 'RateLimit', 'RateLimit', 500, 0)
    Num(C, 'MaxTransaction', 'MaxTransaction', 1000000, 1)
    Num(C.Accounts, 'OpeningFee', 'Accounts.OpeningFee', 5, 0)
    Num(C.Accounts, 'MaxDepositPerOperation', 'Accounts.MaxDepositPerOperation', 0, 0)
    Num(C.Accounts, 'MaxWithdrawPerDay', 'Accounts.MaxWithdrawPerDay', 0, 0)
    Num(C.Accounts, 'HistoryLimit', 'Accounts.HistoryLimit', 50, 1, 500)
    Num(C.Accounts, 'HistoryKeepDays', 'Accounts.HistoryKeepDays', 0, 0)
    Num(C.GoldBars, 'MaxPerAccount', 'GoldBars.MaxPerAccount', 100, 1)
    Num(C.GoldBars, 'RatePerBarPerHour', 'GoldBars.RatePerBarPerHour', 0.005, 0)
    Num(C.GoldBars, 'PayoutIntervalHours', 'GoldBars.PayoutIntervalHours', 4, 0.1)
    Num(C.GoldBars, 'DailyCapPerAccount', 'GoldBars.DailyCapPerAccount', 12.0, 0)
    Num(C.GoldBars, 'MaxOfflineHours', 'GoldBars.MaxOfflineHours', 72, 0)
    Num(C.GoldBars, 'CheckEverySeconds', 'GoldBars.CheckEverySeconds', 60, 10)
    Num(C.Storage, 'CycleDays', 'Storage.CycleDays', 30, 1)
    Num(C.Storage, 'GraceDays', 'Storage.GraceDays', 3, 0)
    Num(C.Storage, 'DeleteAfterDays', 'Storage.DeleteAfterDays', 0, 0)
    Num(C.Vault, 'StartingBalance', 'Vault.StartingBalance', 0, 0)
    Num(C.Vault, 'ReserveRatio', 'Vault.ReserveRatio', 0, 0, 1)
    Num(C.Banker, 'MaxRentDiscount', 'Banker.MaxRentDiscount', 50, 0, 100)
    Num(C.Banker, 'AutoModeFeeMultiplier', 'Banker.AutoModeFeeMultiplier', 1.5, 1)
    Num(C.Loans, 'MinInterest', 'Loans.MinInterest', 5, 0)
    Num(C.Loans, 'MaxInterest', 'Loans.MaxInterest', 50, 0)
    Num(C.Loans, 'MissedPaymentsToDefault', 'Loans.MissedPaymentsToDefault', 3, 1)
    Num(C.Loans, 'CommissionPercent', 'Loans.CommissionPercent', 10, 0, 100)
    Num(C.Telegraph, 'FeePercent', 'Telegraph.FeePercent', 5, 0, 100)
    Num(C.Telegraph, 'DelayMinutes', 'Telegraph.DelayMinutes', 30, 0)
    Num(C.GoldExchange, 'BuyPrice', 'GoldExchange.BuyPrice', 20, 0)
    Num(C.GoldExchange, 'SellPrice', 'GoldExchange.SellPrice', 25, 0)
    Num(C.Billing, 'MaxDistance', 'Billing.MaxDistance', 10.0, 0)
    Num(C.Billing, 'MinAmount', 'Billing.MinAmount', 1, 0.01)
    Num(C.Billing, 'MaxAmount', 'Billing.MaxAmount', 10000, 0.01)
    if C.Loans.MaxInterest < C.Loans.MinInterest then Warn('Loans.MaxInterest', C.Loans.MaxInterest, C.Loans.MinInterest) C.Loans.MaxInterest = C.Loans.MinInterest end
    if C.GoldExchange.SellPrice < C.GoldExchange.BuyPrice then
        print('^3[fks-banking] config GoldExchange.SellPrice is lower than BuyPrice: players can buy and sell bars back for a profit^0')
    end
    if C.Billing.PersonalPayout ~= 'cash' and C.Billing.PersonalPayout ~= 'bank' then Warn('Billing.PersonalPayout', C.Billing.PersonalPayout, 'cash') C.Billing.PersonalPayout = 'cash' end
    if C.Loans.CommissionBase ~= 'interest' and C.Loans.CommissionBase ~= 'principal' then Warn('Loans.CommissionBase', C.Loans.CommissionBase, 'interest') C.Loans.CommissionBase = 'interest' end
    if #C.Storage.Tiers == 0 then C.Storage.Enabled = false end
    if #C.Banker.Ranks == 0 then C.Banker.Enabled = false end
    -- the services only exist with the banker job
    if not C.Banker.Enabled then
        C.Loans.Enabled, C.Telegraph.Enabled, C.GoldExchange.Enabled, C.Appraisal.Enabled = false, false, false, false
    end
    -- the government menu lives in /billing
    if not C.Billing.Enabled then C.Government.Enabled = false end
end
