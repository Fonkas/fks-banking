# fks-banking

Banking for RedM (**VORP** and **RSG**): one bank per town with its own accounts, the framework's gold kept apart,
gold bars that earn money as an investment, rented vault boxes, a banker job (vault, loans, telegraph transfers,
gold exchange, appraisal), bills between players with a handwritten signature and a government menu that can freeze
accounts.

Every screen is drawn by **fks-core** (horizontal menus: the sections sit side by side as tabs and their content
opens below in rows of cards). This resource ships no HTML, CSS or JavaScript.

Available in English and Portuguese (`Config.Locale`).

> License: **GPL-3.0-or-later**, see [LICENSE](LICENSE). Changes per version: [CHANGELOG.md](CHANGELOG.md).

---

## Installation

1. Put `fks-banking` in your resources folder.
2. Start it **after** its dependencies:

```cfg
ensure ox_lib
ensure oxmysql
ensure vorp_core          # or rsg-core
ensure vorp_inventory     # or rsg-inventory / ox_inventory
ensure fks-core           # 2.2.0 or newer
ensure fks-companies      # optional (company bills)
ensure fks-banking
```

3. The tables are created on start. You can also import `sql/install.sql` by hand (same statements).
4. Edit `config.lua`. Every option is explained there; at least check:
   - the coordinates of the 5 default banks (marked `TODO: verify in-game`);
   - `Config.Banker.Jobs` (which jobs are bankers, and of which banks) and `Config.Government.Jobs`;
   - `Config.Billing.CompanyJobs` if you use company bills.
5. RSG: if you want the gold currency in banks, set `Config.RSGGoldAccount` to the rsg-core money account you use as
   gold (e.g. `'bloodmoney'`). Without it the Gold tab is hidden on RSG.
6. Gold bars need the item `Config.GoldBars.Item` (default `goldbar`) in your inventory.

### Dependencies

| Resource | Why |
|---|---|
| [fks-core](https://github.com/Fonkas/fks-core) 2.2.0+ | VORP / RSG bridge (players, money, items, stashes), the shared UI (incl. the `table`, `signature` and `dropdown` components added in 2.2.0), notifications |
| ox_lib | server callbacks (`lib.callback`) |
| oxmysql | database |
| vorp_core **or** rsg-core | framework |
| vorp_inventory, rsg-inventory **or** ox_inventory | gold bars, vault boxes, collateral items |
| fks-companies (optional) | receives the money of company bills (`Config.FKS_Banking = true` in its config) |

---

## Systems

### Banks and accounts
- Banks live in `Config.Banks` (id, name, counter coordinates, distance, blip, optional NPC, optional opening hours,
  enabled). The `id` is the key in the database: never rename it once players have accounts there.
- Accounts are **per bank**: money deposited in Blackwater only exists in Blackwater. A character opens an account
  in each bank they use (fee `Config.Accounts.OpeningFee`, paid in cash, goes to that bank's vault).
- Each account has a unique number (`VAL-482913`) and belongs to the **character** (charidentifier / citizenid).
- Cash and gold (framework currency, `Config.GoldCurrency`) are deposited / withdrawn at the counter. History is
  shown in a searchable table (`Config.Accounts.HistoryLimit` rows, optional cleanup with `HistoryKeepDays`).
- Optional limits: `MaxDepositPerOperation`, `MaxWithdrawPerDay`.

### Gold bars (investment)
Gold bars are an inventory item. Deposited in an account they earn cash into that same account.

```
payout = bars x RatePerBarPerHour x hours since the last payout      (paid every PayoutIntervalHours)
```

With the defaults (`0.005` per bar per hour, every `4` h, cap `12.0` per account per day):

| Bars | Per payout | Per day | Per week | All 5 default banks full (per day / week) |
|---:|---:|---:|---:|---:|
| 1 | $0.02 | $0.12 | $0.84 | 5 bars: $0.60 / $4.20 |
| 50 | $1.00 | $6.00 | $42.00 | 250 bars: $30.00 / $210.00 |
| 100 | $2.00 | $12.00 | $84.00 | 500 bars: $60.00 / $420.00 |

- At most `MaxPerAccount` (100) bars per bank: with 5 banks a player can invest 500 bars, with 6 banks 600, etc.
- Computed only on the server, from timestamps in the database. Offline time counts up to `MaxOfflineHours` and
  is paid on the next login (respecting the daily cap). Cents are kept until they add up to $0.01.
- Bars used as loan collateral are locked but keep earning. Frozen accounts earn nothing (that time is lost).
- High values print money for every investor, every day: change them carefully.

### Vault boxes
- One rented box per bank (Small 250 / Medium 500 / Large 750 space by default; `Config.Storage.Tiers`). Space is
  slots on ox / rsg inventory and items on vorp_inventory.
- The first rent is paid when renting; then every `CycleDays` from the account of that bank.
- Bigger box: pays the difference for the days left of the cycle. Smaller box: only if the items fit
  (`Bridge.StashUsage` of fks-core).
- No money: "overdue" for `GraceDays` (warning), then "locked" until the debt is paid at the counter (items are
  kept). A debt the account can cover later is paid automatically. `DeleteAfterDays` (0 = never) removes boxes
  locked for too long.
- Frozen accounts keep their box and still pay the rent (`ChargeRentWhileFrozen`).

### Banker job
No money is created: loans, gold purchases, commissions and salaries come from the **vault** of each bank, which
receives opening fees, telegraph fees, exchange margins, rents, installments and bank debt bills (plus an optional
reserve share of deposits, `Config.Vault.ReserveRatio`). If the vault cannot pay, the operation is refused.

| Rank (default) | Can do |
|---|---|
| Teller (0) | assisted account opening, gold exchange / appraisal, look up clients |
| Manager (1) | + loans up to $500, telegraph transfers, client ledger, rent discounts |
| Director (2) | + loans up to the maximum, vault (deposit / withdraw / items / ledger), salaries, full bank ledger |

- A banker works only in the bank(s) of their job (`Config.Banker.Jobs`), within `WorkDistance` of the counter. The
  client must stand within `ClientDistance` and **confirms** every operation on their money or items.
- **Loans:** amount, interest, installments, interval and collateral (gold bars in that bank, an item kept in the
  vault, or none with a higher minimum interest). The client signs in the Loans tab with their character name;
  only then the money leaves the vault. Installments are taken automatically (also from frozen accounts). After
  `MissedPaymentsToDefault` missed installments in a row the collateral goes to the vault and the rest of the debt
  becomes a bank bill ("Bank - Valentine Bank") in the government menu. Fully repaid: collateral back and a
  commission for the banker.
- **Telegraph:** moves money from an account in this bank to any account number in any bank. Fee to the sending
  vault, money arrives after `DelayMinutes`.
- **Gold exchange:** the bank buys bars (vault pays `BuyPrice`) and sells bars from its stock (`SellPrice`).
- **Appraisal** (optional): the bank buys the items of `Config.Appraisal.Items`.
- **Automatic mode** (`AutoModeWhenNoBankers`): with no banker online, telegraph / exchange / appraisal work at the
  counter with worse prices (`AutoModeFeeMultiplier`). Loans only with `AutoModeLoans` (off by default).
- Salaries (off by default): paid from the vault to bankers online, amounts per rank set by the Director.

### Bills (`/billing`, `/mybills`)
- `/billing`: personal bill (everyone) or company bill (jobs of `Config.Billing.CompanyJobs`, shown with the company
  name; needs fks-companies with `Config.FKS_Banking = true`). Target by server id, within `MaxDistance`.
- `/mybills`: To sign | To pay | Paid | Written by me. Signing writes the character's first and last name with the
  date, shown as a handwritten signature. A signed bill cannot be refused anymore.
- Payment: the full amount in cash on hand. With `AllowBankPayment = true` also from a bank account (never frozen).
- Money: company bills go to the company balance (fks-companies ledger, "Bank bill"); personal bills go to the
  writer in cash (kept until they log in when offline) or to their account in `PersonalPayoutBank`
  (`PersonalPayout = 'bank'`); bank debt bills go to the vault of that bank.

### Government
Jobs of `Config.Government.Jobs` see more tabs in `/billing`:
- **Manage bills:** every open bill (or all), search by name (writer, debtor, signer), character or player ID,
  company and bill number; filters by status and type; order by date or amount. Delete a bill, freeze or unfreeze
  the debtor.
- **Frozen accounts:** every frozen character, plus a people search (also finds people whose bill was deleted).
- **Log:** who did what and when (also to Discord with `Config.Webhooks`).

Frozen character: every account in every bank (also new ones). Blocked: deposits, withdrawals, gold, gold bars,
transfers, loans and bill payments from the bank; gold bars stop earning. Still working: vault boxes and the
automatic rent / installments. At the counter only the notice *"Your accounts have been frozen..."* and, when they
rent a box there, a menu with only the box. The player is told at once, or on the next login.

---

## Icons

The menu icons are SVG files in `img/icons/` (`deposit.svg`, `vault.svg`, `telegraph.svg`...). fks-core draws them
with its own stroke and theme colours, so they change colour on hover and when a button is disabled. To change one,
replace the file with a 24x24 line drawing (`viewBox="0 0 24 24"`, no fills or colours of its own) and restart the
resource. A missing file shows a plain box icon and a warning in the F8 console.

## Commands

| Command | Who | |
|---|---|---|
| `/billing` (`Config.Billing.Command`) | everyone | write bills; government: manage bills, frozen accounts, log |
| `/mybills` (`Config.Billing.MyBillsCommand`) | everyone | sign, refuse and pay bills |

The bank opens with `Config.OpenKey` (default **E**) at a counter.

## Exports (server)

`charId` = character identifier (VORP charidentifier / RSG citizenid).

```lua
local cash, gold, bars = exports['fks-banking']:GetAccountBalance(charId, 'valentine')   -- nil = no account
local accounts = exports['fks-banking']:GetAccounts(charId)    -- { { bank, label, number, cash, gold, bars, frozen } }
local ok, err = exports['fks-banking']:AddMoney(charId, 'valentine', 25.0, 'Reward')
local ok, err = exports['fks-banking']:RemoveMoney(charId, 'valentine', 10.0, 'Fine', ignoreFrozen)  -- err: no_account | frozen | invalid_amount | ...
local frozen = exports['fks-banking']:IsFrozen(charId)
local ok, msg = exports['fks-banking']:FreezeAccounts(charId, 'Sheriff Office')
local ok, msg = exports['fks-banking']:UnfreezeAccounts(charId, 'Sheriff Office')
local billId = exports['fks-banking']:CreateBill({ target = serverIdOrCharId, amount = 50, reason = 'Fine', issuerName = 'Sheriff Office' })
local bills = exports['fks-banking']:GetBills(charId, 'unpaid')   -- status optional
```

Server events: `fks-banking:server:accountChanged` (accountId, cid, bankId, field, delta, after, kind),
`fks-banking:server:billCreated`, `fks-banking:server:billPaid`, `fks-banking:server:frozen` (cid, frozen).

## Security

The client only sends what the player wants (bank, amount typed, target). The server checks on every call: loaded
character, job and grade, distance to the counter, opening hours, balances, limits and frozen state. Every number is
validated (no NaN, no negatives, whole numbers for bars and items). Events are rate limited per player
(`Config.RateLimit`), money operations are locked per account and written with their history in one database
transaction, so fast clicks never duplicate money.

---

## Testing in game

1. **Account:** go to the Valentine counter, press E, open an account (fee leaves your cash). Deposit and withdraw
   cash; check the history table (search, filters, order). With gold enabled, do the same in the Gold tab.
2. **Per town:** open Blackwater: no account there yet; your Valentine money is not visible.
3. **Gold bars:** give yourself `goldbar` items, deposit them in the Gold bars tab. For a quick test set
   `PayoutIntervalHours = 0.05` (3 min) and watch the payout notification and the "Bar earnings" rows. Log out and
   in again to see the offline payout. Try more than 100 bars (refused) and withdrawing with a full inventory.
4. **Vault box:** rent a Small box (rent leaves the account), open it, put items in. Try to change to a smaller size
   with too many items (refused). Empty the account and set `CycleDays = 1` / change `next_due_at` in
   `fks_bank_storage` to the past: the box goes overdue, then locked after `GraceDays`; pay the debt at the counter.
5. **Banker:** give a player the `banker` job (grade 2). As Director deposit money into the vault. Propose a loan to
   another player next to you; the client signs it in the Loans tab (signature appears) and receives the money.
   Set the interval low / move `next_due_at` back to see installments, empty the client's account to see missed
   installments and the default (collateral to the vault, bank bill in the government menu).
6. **Telegraph / exchange / appraisal:** as banker send a transfer (client confirms), check it arrives after the
   delay. Buy and sell bars with a client. Log the banker out with `AutoModeWhenNoBankers = true` and use the
   Services tab as a client.
7. **Bills:** `/billing` a personal bill to a player next to you; they sign it in `/mybills` and pay with cash
   (refused without the full amount). With a job in `CompanyJobs`, fks-companies running and its
   `Config.FKS_Banking = true`, write a company bill and check the company ledger ("Bank bill").
8. **Government:** with the `government` job open `/billing` → Manage bills, search, freeze the debtor. The debtor
   (online) is told at once; at the counter they only see the frozen notice (or the box menu). Unfreeze from the
   Frozen accounts tab or the people search. Freeze an offline character and log them in to see the notice.
9. **Exploits:** spam deposit / withdraw buttons and the events: no duplicated money, "Slow down" messages, and the
   history matches the balance.
