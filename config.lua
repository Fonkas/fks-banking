Config = Config or {}

--[[
    ============================================================================================================
     FKS Banking - configuration
    ============================================================================================================
     Every big feature has its own `Enabled` switch. A feature that is switched off disappears completely: no tab in
     the menu, no command, and its server events refuse every call.

     Money values are dollars with cents ($12.50 = 12.50). Times are REAL time (not the in-game clock) unless a
     comment says otherwise.

     Economy rule of this script: no money is created from nothing. Loans, gold purchases, commissions and salaries
     are paid out of the vault of each bank (Config.Vault). If a vault is empty, those operations are refused.
     The only money "created" are the gold bar earnings (Config.GoldBars), which is an investment you control.
    ============================================================================================================
]]

-- Server console: "up to date" / "OUTDATED" compared with GitHub
Config.VersionCheck = {
    enabled  = true,
    repo     = 'Fonkas/fks-banking',     -- GitHub "user/repository"
    branch   = 'main',
    interval = 12,                       -- check again every X hours (0 = only on start)
}

Config.Debug = false                     -- true: prints every money movement and loop run in the server console

-- Language: 'en' | 'pt' (files in locales/; a missing key falls back to English)
Config.Locale = 'en'

---------------------------------------------------------------------------
-- Framework / inventory (read by the fks-core bridge)
---------------------------------------------------------------------------
Config.Framework = 'auto'                -- 'auto' | 'vorp' | 'rsg'
Config.Inventory = 'auto'                -- 'auto' | 'vorp_inventory' | 'rsg-inventory' | 'ox_inventory'
-- RSG has no "gold" currency of its own: the rsg-core money account used as gold (e.g. 'bloodmoney').
-- nil = no gold on RSG, so everything about the gold currency (Config.GoldCurrency) is hidden there.
-- VORP always has gold (character gold) and ignores this.
Config.RSGGoldAccount = nil

-- Anti-spam: minimum milliseconds between two calls of the same action by the same player.
-- Lower = snappier menus, higher = safer against macro clicking. Every money action is ALSO locked per account on
-- the server, so fast double clicks can never run twice at the same time.
Config.RateLimit = 500

-- Largest amount of money accepted in any single operation (deposit, withdrawal, transfer, bill, loan...).
-- A last safety net against typos and exploits; real limits are below in each section.
Config.MaxTransaction = 1000000

---------------------------------------------------------------------------
-- Opening a bank
---------------------------------------------------------------------------
-- Key of the native prompt at a counter. Default 0xCEFD9220 = E, the usual interaction key.
Config.OpenKey = 0xCEFD9220
Config.OpenKeyLabel = 'E'                -- only shown in texts

Config.Interaction = {
    checkInterval = 500,                 -- ms between "am I near a counter?" checks (only when a bank is close)
    nearBank      = 40.0,                -- the precise checks (and the NPC) only run within this distance of a bank
    -- the server re-checks the distance on EVERY action, with this extra margin (lag / walking while the menu is open)
    serverMargin  = 3.0,
    closeWhenAway = true,                -- close the menu when the player walks away from the counter
}

---------------------------------------------------------------------------
-- Banks
-- Create as many as you want. `id` is the key used everywhere in the database: NEVER rename the id of a bank that
-- already has accounts (players would lose access to them). To retire a bank, set enabled = false instead.
--
--   id          unique id (letters, numbers, _ ) - stored in the database
--   label       name shown to players
--   prefix      3-4 letters in front of the account numbers of this bank (VAL-482913)
--   coords      position of the counter (vector3) · heading = which way the clerk faces
--   distance    how close the player must be to the counter to see the prompt
--   blip        { enabled, sprite (name or hash), name }
--   npc         optional clerk behind the counter { enabled, model, coords (vector3), heading }
--   hours       optional opening hours { open = 8, close = 18, clock = 'game' | 'real' } - nil = always open
--               'game' uses the in-game clock (checked by the client), 'real' the server clock (checked by the server)
--   enabled     false = the bank does not exist (no blip, no prompt) but its data stays in the database
--
-- The default counters and clerk spots of Valentine, Saint Denis, Rhodes and Blackwater are the ones used by
-- vorp_banking / rsg-banking. Armadillo's clerk is off until its spot is set (see below).
---------------------------------------------------------------------------
Config.Banks = {
    {
        id = 'valentine', label = 'Valentine Bank', prefix = 'VAL',
        coords = vector3(-308.58, 776.07, 118.70), heading = 18.69, distance = 2.0,
        blip = { enabled = true, sprite = 'blip_proc_bank', name = 'Valentine Bank' },
        npc = { enabled = true, model = 's_m_m_bankclerk_01', coords = vector3(-308.02, 773.82, 116.70), heading = 18.69 },
        hours = nil,
        enabled = true,
    },
    {
        id = 'saintdenis', label = 'Saint Denis Bank', prefix = 'STD',
        coords = vector3(2644.08, -1292.21, 52.29), heading = 30.64, distance = 2.0,
        blip = { enabled = true, sprite = 'blip_proc_bank', name = 'Saint Denis Bank' },
        npc = { enabled = true, model = 's_m_m_bankclerk_01', coords = vector3(2645.12, -1294.37, 51.25), heading = 30.64 },
        hours = nil,
        enabled = true,
    },
    {
        id = 'rhodes', label = 'Rhodes Bank', prefix = 'RHO',
        coords = vector3(1294.14, -1303.06, 77.04), heading = 327.08, distance = 2.0,
        blip = { enabled = true, sprite = 'blip_proc_bank', name = 'Rhodes Bank' },
        npc = { enabled = true, model = 's_m_m_bankclerk_01', coords = vector3(1292.84, -1304.74, 76.04), heading = 327.08 },
        hours = nil,
        enabled = true,
    },
    {
        id = 'blackwater', label = 'Blackwater Bank', prefix = 'BLW',
        coords = vector3(-813.18, -1277.60, 43.68), heading = 176.86, distance = 2.0,
        blip = { enabled = true, sprite = 'blip_proc_bank', name = 'Blackwater Bank' },
        npc = { enabled = true, model = 's_m_m_bankclerk_01', coords = vector3(-813.18, -1275.42, 42.64), heading = 176.86 },
        hours = nil,
        enabled = true,
    },
    {
        id = 'armadillo', label = 'Armadillo Bank', prefix = 'ARM',
        coords = vector3(-3666.25, -2626.57, -13.59), heading = 90.0, distance = 2.0,
        blip = { enabled = true, sprite = 'blip_proc_bank', name = 'Armadillo Bank' },
        -- no known clerk spot for Armadillo yet: with Config.Debug = true, stand where the clerk should be, type /bankpos
        -- and paste the line it prints (F8) here, then set enabled = true
        npc = { enabled = false, model = 's_m_m_bankclerk_01', coords = vector3(-3664.30, -2626.60, -14.59), heading = 90.0 },
        hours = nil,
        enabled = true,
    },
}

---------------------------------------------------------------------------
-- Accounts (section 2)
---------------------------------------------------------------------------
Config.Accounts = {
    -- Fee to open an account in a bank, paid with cash on hand. It goes to that bank's vault.
    -- Economy: a small sink that also seeds the vaults. 0 = free.
    OpeningFee = 5,

    -- Largest cash deposit in one operation (0 = no limit besides Config.MaxTransaction).
    MaxDepositPerOperation = 0,

    -- Most cash a character can withdraw from ONE account per real day (0 = no limit).
    -- Economy: slows down laundering stolen money through the bank.
    MaxWithdrawPerDay = 0,

    -- Rows of history shown in the menu (the newest ones).
    HistoryLimit = 50,

    -- Delete history rows older than this many days (0 = keep forever). Only the history; balances never change.
    HistoryKeepDays = 0,
}

---------------------------------------------------------------------------
-- Gold currency (section 2): the framework's gold (VORP gold / RSG Config.RSGGoldAccount), NOT the gold bar item.
-- Many servers use gold as a VIP / premium currency: if you do not want it stored in banks, set Enabled = false.
---------------------------------------------------------------------------
Config.GoldCurrency = {
    Enabled = true,
    MaxDepositPerOperation = 0,          -- 0 = no limit
}

---------------------------------------------------------------------------
-- Gold bars (section 3): an inventory item deposited in an account that earns cash over time.
--
--  FORMULA
--    payout = bars x RatePerBarPerHour x hours since the last payout
--    It is paid every PayoutIntervalHours, in cash, into the account of the SAME bank, and never more than
--    DailyCapPerAccount per real day per account (0 = no cap).
--    Cents are kept: earnings below $0.01 are saved and added to the next payout.
--
--  EXAMPLES with the defaults (RatePerBarPerHour = 0.005, PayoutIntervalHours = 4, DailyCapPerAccount = 12.0)
--    bars | per payout (4 h)        | per day (6 payouts) | per week | all 5 default banks full, per day / week
--    -----+-------------------------+---------------------+----------+------------------------------------------
--      1  | 1 x 0.005 x 4 = $0.02   | $0.12               | $0.84    |  (5 bars)   $0.60 / $4.20
--     50  | 50 x 0.005 x 4 = $1.00  | $6.00               | $42.00   |  (250 bars) $30.00 / $210.00
--    100  | 100 x 0.005 x 4 = $2.00 | $12.00 (= the cap)  | $84.00   |  (500 bars) $60.00 / $420.00
--
--    A player can have MaxPerAccount bars in EVERY bank: with 5 banks that is 500 bars earning; if you add a 6th
--    bank, 600, and so on. Plan the economy with the number of banks you have.
--
--  WARNING: high rates or caps print money for every investor on the server, every day, even while they are
--  offline (see MaxOfflineHours). Raise them slowly and watch your economy.
---------------------------------------------------------------------------
Config.GoldBars = {
    Enabled = true,
    Item = 'goldbar',                    -- item name in your inventory
    MaxPerAccount = 100,                 -- most bars a character can keep in ONE bank
    RatePerBarPerHour = 0.005,           -- dollars per bar per hour
    PayoutIntervalHours = 4,             -- hours between payouts
    DailyCapPerAccount = 12.0,           -- most one account can earn per real day (0 = no cap)
    -- Offline: how many hours offline still earn (0 = bars only earn while the owner is online).
    -- When the player logs in again they receive what they earned offline (respecting the daily cap).
    MaxOfflineHours = 72,
    CheckEverySeconds = 60,              -- how often the server loop looks for due payouts (not the payout interval)
    NotifyPayout = true,                 -- notification to the owner (online) on every payout
}

---------------------------------------------------------------------------
-- Vault boxes (section 4): a personal storage rented per bank, paid from that bank's account.
---------------------------------------------------------------------------
Config.Storage = {
    Enabled = true,
    CycleDays = 30,                      -- rent is charged every X real days (the first cycle is paid when renting)
    GraceDays = 3,                       -- unpaid rent: days of tolerance (with a warning) before the box locks
    -- Locked boxes keep their items until the debt is paid at the counter. Delete abandoned boxes (AND their
    -- items) after they have been locked for this many days. 0 = never delete.
    DeleteAfterDays = 0,
    ChargeRentWhileFrozen = true,        -- frozen accounts still pay the rent automatically
    -- Tiers. Space = slots on ox_inventory / rsg-inventory, total items on vorp_inventory. Weight in grams
    -- (ox / rsg only). Rent per cycle. The order is the order shown in the menu (small to big).
    Tiers = {
        { id = 'small',  space = 250, weight = 250000, rent = 500 },
        { id = 'medium', space = 500, weight = 500000, rent = 1000 },
        { id = 'large',  space = 750, weight = 750000, rent = 1500 },
    },
}

---------------------------------------------------------------------------
-- Vault of each bank (section 5.1)
---------------------------------------------------------------------------
Config.Vault = {
    -- Money a vault starts with the first time the bank is used. 0 = the vault only grows from fees, rents and
    -- interest, or when a Director deposits money into it. Loans and gold purchases need money in the vault.
    StartingBalance = 0,

    -- Fractional reserve: this share (0.0 - 1.0) of every client cash deposit is ALSO credited to the vault, as
    -- the money the bank can lend. Real banks lend out most of what clients deposit; here the client's balance
    -- stays intact, so this creates money: 0.1 means $10 of lending money for every $100 deposited.
    -- 0 = off (default, no money created). Keep it low.
    ReserveRatio = 0,
}

---------------------------------------------------------------------------
-- Banker job (section 5). Each service below has its own switch.
---------------------------------------------------------------------------
Config.Banker = {
    Enabled = true,

    -- Which jobs are bankers and in which banks they work:
    --   ['banker'] = 'all'                         one job for every bank
    --   ['banker_valentine'] = { 'valentine' }     one job per bank (a banker only works in the listed banks)
    Jobs = {
        ['banker'] = 'all',
        -- ['banker_valentine'] = { 'valentine' },
        -- ['banker_blackwater'] = { 'blackwater' },
    },

    -- Ranks by job grade (the highest rank whose `grade` is <= the player's grade). What each rank can do:
    --   openAccounts  assisted account opening        exchange   buy / sell gold bars, appraise items
    --   clients       look up clients of the bank      ledger     see a client's account history
    --   loans         create loans, up to maxLoan      telegraph  send telegraph transfers
    --   discounts     discount on vault box rents      vault      deposit / withdraw / see the vault and its items
    --   bankLedger    the full ledger of the bank       salaries   set the salaries of the bank
    Ranks = {
        { grade = 0, name = 'Teller',   openAccounts = true, exchange = true, clients = true },
        { grade = 1, name = 'Manager',  openAccounts = true, exchange = true, clients = true, ledger = true,
          loans = true, maxLoan = 500, telegraph = true, discounts = true },
        { grade = 2, name = 'Director', openAccounts = true, exchange = true, clients = true, ledger = true,
          loans = true, maxLoan = nil, telegraph = true, discounts = true, vault = true, bankLedger = true, salaries = true },
    },

    MaxRentDiscount = 50,                -- highest discount (%) a banker can give on a vault box rent
    WorkDistance = 8.0,                  -- a banker must be this close to the counter of their bank to work
    ClientDistance = 6.0,                -- the client must be this close to the banker

    -- With no banker online for a bank: loans, telegraph and the gold exchange need a banker...
    AutoModeWhenNoBankers = false,       -- ...unless this is true: then telegraph and exchange work at the counter
    AutoModeFeeMultiplier = 1.5,         -- with worse prices: fees x1.5, the bank buys cheaper and sells dearer
    AutoModeLoans = false,               -- loans in automatic mode (not recommended: nobody checks the client)

    -- Salaries paid from the vault to bankers ONLINE, every IntervalMinutes. Off by default because most
    -- frameworks already pay job salaries. The Director can change the amounts of their bank (up to Max).
    -- Each banker is paid by the first bank of their job (for a job with 'all', the first bank of Config.Banks).
    Salaries = {
        Enabled = false,
        IntervalMinutes = 60,
        Default = { [0] = 5, [1] = 8, [2] = 12 },   -- by rank index (0 = first rank above)
        Max = 50,
    },
}

-- Loans (section 5.2)
Config.Loans = {
    Enabled = true,
    MaxAmount = 5000,                    -- highest loan of all (ranks have their own maxLoan)
    MinAmount = 10,
    MinInterest = 5,                     -- % of the principal, added once
    MaxInterest = 50,
    MinInterestNoCollateral = 15,        -- loans without collateral need at least this interest
    MinInstallments = 1,
    MaxInstallments = 30,
    IntervalOptions = { 24, 48, 72, 168 },   -- hours between installments the banker can choose
    MaxActivePerClient = 1,              -- active loans per character in ALL banks
    MissedPaymentsToDefault = 3,         -- missed installments IN A ROW before the loan defaults
    ProposalMinutes = 30,                -- a proposal not signed in this time expires
    Collateral = {
        bars = true,                     -- the client's gold bars in that bank (locked, still earning)
        item = true,                     -- an item kept in the vault (returned when the loan is paid)
        none = true,                     -- no collateral (MinInterestNoCollateral applies)
    },
    -- Commission for the banker who made the loan, paid from the vault when it is fully repaid:
    -- CommissionPercent % of the interest ('interest') or of the principal ('principal'). 0 = none.
    CommissionPercent = 10,
    CommissionBase = 'interest',
}

-- Telegraph transfers between banks (section 5.3). Accounts are per town, so this is the only way to move money
-- between banks without carrying cash.
Config.Telegraph = {
    Enabled = true,
    FeePercent = 5,                      -- % of the amount, paid by the sender to the vault of the sending bank
    MinFee = 0.10,
    DelayMinutes = 30,                   -- real minutes until the money arrives (0 = immediately)
    MaxAmount = 10000,
}

-- Gold exchange (section 5.4): the bank buys and sells gold bars (Config.GoldBars.Item) for cash on hand.
-- The margin (SellPrice - BuyPrice) stays in the vault. The bank can only sell bars it has in stock.
Config.GoldExchange = {
    Enabled = true,
    BuyPrice = 20,                       -- the bank pays this per bar (from the vault)
    SellPrice = 25,                      -- the bank charges this per bar (to the vault)
    MaxPerTrade = 50,
}

-- Appraisal (section 5.4, optional): the bank buys these items for cash from the vault. Item names exactly as in
-- your inventory, value per unit. The items go to the vault stock.
Config.Appraisal = {
    Enabled = false,
    MaxPerTrade = 100,
    Items = {
        ['goldnugget'] = 2.0,
        ['silvernugget'] = 1.0,
        ['diamond'] = 50.0,
        ['ring_gold'] = 15.0,
    },
}

---------------------------------------------------------------------------
-- Bills (section 6): /billing and /mybills
---------------------------------------------------------------------------
Config.Billing = {
    Enabled = true,
    Command = 'billing',                 -- write bills (and the government menu)
    MyBillsCommand = 'mybills',          -- my bills: to sign, to pay, paid, written by me

    -- Company bills: only these jobs (with a minimum grade) can write them, in the company's name.
    -- They need fks-companies running with Config.FKS_Banking = true there; otherwise this option is hidden.
    CompanyJobs = {
        -- ['saloonblackwater'] = 0,
    },

    MaxDistance = 10.0,                  -- the target must be within this distance (0 = anywhere on the server)
    MinAmount = 1,
    MaxAmount = 10000,
    ReasonMax = 200,                     -- characters of the reason
    Cooldown = 10,                       -- seconds between two bills from the same player
    MaxUnsignedPerTarget = 5,            -- bills waiting for a signature per target (stops spam)

    -- Payment is always with cash on hand (the full amount or nothing). true: the player may instead pay from one
    -- of their bank accounts (never a frozen one).
    AllowBankPayment = false,

    -- Personal bills: where the money goes.
    --   'cash' = cash on hand of the writer (kept for them until they log in when offline)
    --   'bank' = their account in PersonalPayoutBank (falls back to cash when they have no account there)
    PersonalPayout = 'cash',
    PersonalPayoutBank = 'valentine',
}

---------------------------------------------------------------------------
-- Government (section 7): manage bills and freeze accounts, from the /billing menu
---------------------------------------------------------------------------
Config.Government = {
    Enabled = true,
    Jobs = {                             -- job = minimum grade
        ['government'] = 0,
    },
    MaxRows = 500,                       -- bills loaded into the menu at once (newest first)
    LogRows = 200,                       -- rows of the action log shown
}

---------------------------------------------------------------------------
-- Discord webhooks (optional). Leave a url empty to skip that channel.
---------------------------------------------------------------------------
Config.Webhooks = {
    Enabled = false,
    Name = 'FKS Banking',
    Government = '',                     -- freezes, unfreezes, deleted bills
    Banker = '',                         -- loans, transfers, vault movements, exchange
    Bills = '',                          -- bills written, signed, paid
    Accounts = '',                       -- accounts opened, big deposits / withdrawals (BigAmount)
    BigAmount = 1000,                    -- deposits / withdrawals from this amount go to the Accounts webhook
}
