-- ---------------------------------------------------------------------------
-- fks-banking database. The resource runs this file on start (CREATE TABLE IF NOT EXISTS), so importing it by
-- hand is optional. Money is DECIMAL(14,2); every time is a unix timestamp (seconds).
-- `cid` = the character identifier (VORP charidentifier / RSG citizenid), never the license: every character
-- has its own accounts.
-- ---------------------------------------------------------------------------

-- One account per character per bank (money deposited in Blackwater only exists in Blackwater)
CREATE TABLE IF NOT EXISTS `fks_bank_accounts` (
    `id`              INT(11) NOT NULL AUTO_INCREMENT,
    `bank_id`         VARCHAR(40) NOT NULL,                        -- Config.Banks[].id
    `cid`             VARCHAR(60) NOT NULL,
    `owner_name`      VARCHAR(80) NOT NULL,
    `account_number`  VARCHAR(20) NOT NULL,
    `cash`            DECIMAL(14,2) NOT NULL DEFAULT 0,
    `gold`            DECIMAL(14,2) NOT NULL DEFAULT 0,           -- framework gold currency (not the gold bar item)
    `bars`            INT(11) NOT NULL DEFAULT 0,                  -- gold bars deposited (all of them earn)
    `bars_locked`     INT(11) NOT NULL DEFAULT 0,                  -- of those, held as loan collateral
    `last_payout_at`  INT(11) NULL,                                -- last gold bar payout
    `offline_since`   INT(11) NULL,                                -- when the owner logged out (offline earnings)
    `yield_fraction`  DECIMAL(16,6) NOT NULL DEFAULT 0,            -- earnings below $0.01 not credited yet
    `yield_day`       CHAR(10) NULL,                               -- day of yield_today (YYYY-MM-DD)
    `yield_today`     DECIMAL(14,6) NOT NULL DEFAULT 0,            -- earned that day (daily cap)
    `withdrawn_day`   CHAR(10) NULL,
    `withdrawn_today` DECIMAL(14,2) NOT NULL DEFAULT 0,            -- withdrawn that day (daily limit)
    `frozen`          TINYINT(1) NOT NULL DEFAULT 0,
    `created_at`      INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_owner_bank` (`cid`, `bank_id`),
    UNIQUE KEY `uniq_number` (`account_number`),
    KEY `idx_bank` (`bank_id`),
    KEY `idx_name` (`owner_name`),
    KEY `idx_bars` (`bars`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Account history
CREATE TABLE IF NOT EXISTS `fks_bank_transactions` (
    `id`              INT(11) NOT NULL AUTO_INCREMENT,
    `account_id`      INT(11) NOT NULL,
    `bank_id`         VARCHAR(40) NOT NULL,
    `cid`             VARCHAR(60) NOT NULL,
    `type`            VARCHAR(24) NOT NULL,                        -- deposit | withdraw | gold_in | gold_out | bars_in | bars_out | yield | fee | rent | loan | installment | transfer_in | transfer_out | bill | ...
    `currency`        VARCHAR(8) NOT NULL DEFAULT 'cash',          -- cash | gold | bars
    `amount`          DECIMAL(14,2) NOT NULL,                      -- signed: + in / - out
    `balance_after`   DECIMAL(14,2) NOT NULL,
    `description`     VARCHAR(255) NULL,
    `actor_cid`       VARCHAR(60) NULL,
    `actor_name`      VARCHAR(80) NULL,
    `created_at`      INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_account` (`account_id`, `id`),
    KEY `idx_bank` (`bank_id`, `id`),
    KEY `idx_cid` (`cid`),
    KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- The vault of each bank: pays loans, gold purchases, commissions and salaries; receives fees, rents, interest
CREATE TABLE IF NOT EXISTS `fks_bank_vaults` (
    `bank_id`         VARCHAR(40) NOT NULL,
    `balance`         DECIMAL(16,2) NOT NULL DEFAULT 0,
    `bars`            INT(11) NOT NULL DEFAULT 0,                  -- gold bars in stock (bought / seized)
    `salaries`        TEXT NULL,                                   -- JSON { [rank] = amount } set by the Director
    `updated_at`      INT(11) NULL,
    PRIMARY KEY (`bank_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Vault ledger
CREATE TABLE IF NOT EXISTS `fks_bank_vault_ledger` (
    `id`              INT(11) NOT NULL AUTO_INCREMENT,
    `bank_id`         VARCHAR(40) NOT NULL,
    `type`            VARCHAR(24) NOT NULL,                        -- opening_fee | transfer_fee | exchange | rent | installment | reserve | loan | gold_buy | gold_sell | appraisal | commission | salary | deposit | withdraw | bill
    `amount`          DECIMAL(14,2) NOT NULL,                      -- signed
    `balance_after`   DECIMAL(16,2) NOT NULL,
    `description`     VARCHAR(255) NULL,
    `actor_cid`       VARCHAR(60) NULL,
    `actor_name`      VARCHAR(80) NULL,
    `created_at`      INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_bank` (`bank_id`, `id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Items kept in a vault: loan collateral, seized collateral and appraised items
CREATE TABLE IF NOT EXISTS `fks_bank_vault_items` (
    `id`              INT(11) NOT NULL AUTO_INCREMENT,
    `bank_id`         VARCHAR(40) NOT NULL,
    `item`            VARCHAR(80) NOT NULL,
    `amount`          INT(11) NOT NULL,
    `loan_id`         INT(11) NULL,
    `owner_cid`       VARCHAR(60) NULL,                            -- who gets it back (collateral)
    `status`          VARCHAR(12) NOT NULL,                        -- held (collateral) | return (to give back) | stock (bank property)
    `created_at`      INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_bank` (`bank_id`, `status`),
    KEY `idx_owner` (`owner_cid`, `status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Rented vault boxes (one per character per bank)
CREATE TABLE IF NOT EXISTS `fks_bank_storage` (
    `id`              INT(11) NOT NULL AUTO_INCREMENT,
    `bank_id`         VARCHAR(40) NOT NULL,
    `cid`             VARCHAR(60) NOT NULL,
    `account_id`      INT(11) NOT NULL,
    `tier`            VARCHAR(20) NOT NULL,                        -- Config.Storage.Tiers[].id
    `stash_id`        VARCHAR(100) NOT NULL,
    `discount`        INT(11) NOT NULL DEFAULT 0,                  -- % off the rent, set by a banker
    `next_due_at`     INT(11) NOT NULL,
    `status`          VARCHAR(12) NOT NULL DEFAULT 'active',       -- active | overdue | locked
    `overdue_since`   INT(11) NULL,
    `debt`            DECIMAL(14,2) NOT NULL DEFAULT 0,
    `created_at`      INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_owner_bank` (`cid`, `bank_id`),
    KEY `idx_due` (`next_due_at`),
    KEY `idx_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Loans
CREATE TABLE IF NOT EXISTS `fks_bank_loans` (
    `id`                 INT(11) NOT NULL AUTO_INCREMENT,
    `bank_id`            VARCHAR(40) NOT NULL,
    `cid`                VARCHAR(60) NOT NULL,
    `client_name`        VARCHAR(80) NOT NULL,
    `account_id`         INT(11) NOT NULL,
    `banker_cid`         VARCHAR(60) NULL,                         -- NULL = automatic mode
    `banker_name`        VARCHAR(80) NULL,
    `principal`          DECIMAL(14,2) NOT NULL,
    `interest`           DECIMAL(6,2) NOT NULL,                    -- %
    `total_due`          DECIMAL(14,2) NOT NULL,
    `installments`       INT(11) NOT NULL,
    `installment_amount` DECIMAL(14,2) NOT NULL,
    `interval_hours`     INT(11) NOT NULL,
    `collateral_type`    VARCHAR(8) NOT NULL DEFAULT 'none',       -- none | bars | item
    `collateral_bars`    INT(11) NOT NULL DEFAULT 0,
    `collateral_item`    VARCHAR(80) NULL,
    `collateral_amount`  INT(11) NOT NULL DEFAULT 0,
    `collateral_value`   DECIMAL(14,2) NOT NULL DEFAULT 0,         -- what the bank counts the collateral as on default
    `status`             VARCHAR(12) NOT NULL,                     -- proposed | active | paid | defaulted | declined | expired
    `paid_amount`        DECIMAL(14,2) NOT NULL DEFAULT 0,
    `paid_installments`  INT(11) NOT NULL DEFAULT 0,
    `missed`             INT(11) NOT NULL DEFAULT 0,               -- missed installments in a row
    `next_due_at`        INT(11) NULL,
    `expires_at`         INT(11) NULL,                             -- proposal expiry
    `signed_name`        VARCHAR(80) NULL,
    `signed_at`          INT(11) NULL,
    `debt_bill_id`       INT(11) NULL,
    `created_at`         INT(11) NOT NULL,
    `closed_at`          INT(11) NULL,
    PRIMARY KEY (`id`),
    KEY `idx_cid` (`cid`, `status`),
    KEY `idx_bank` (`bank_id`, `status`),
    KEY `idx_due` (`status`, `next_due_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Telegraph transfers between banks (arrive after a delay)
CREATE TABLE IF NOT EXISTS `fks_bank_transfers` (
    `id`              INT(11) NOT NULL AUTO_INCREMENT,
    `from_account`    INT(11) NOT NULL,
    `to_account`      INT(11) NOT NULL,
    `from_bank`       VARCHAR(40) NOT NULL,
    `to_bank`         VARCHAR(40) NOT NULL,
    `from_cid`        VARCHAR(60) NOT NULL,
    `to_cid`          VARCHAR(60) NOT NULL,
    `amount`          DECIMAL(14,2) NOT NULL,
    `fee`             DECIMAL(14,2) NOT NULL,
    `banker_cid`      VARCHAR(60) NULL,
    `banker_name`     VARCHAR(80) NULL,
    `status`          VARCHAR(10) NOT NULL DEFAULT 'pending',      -- pending | done
    `arrives_at`      INT(11) NOT NULL,
    `created_at`      INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_pending` (`status`, `arrives_at`),
    KEY `idx_from` (`from_cid`),
    KEY `idx_to` (`to_cid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Bills (/billing, /mybills) and bank debt bills
CREATE TABLE IF NOT EXISTS `fks_bills` (
    `id`              INT(11) NOT NULL AUTO_INCREMENT,
    `kind`            VARCHAR(10) NOT NULL,                        -- personal | company | bank
    `issuer_cid`      VARCHAR(60) NULL,                            -- NULL for bank debt bills
    `issuer_name`     VARCHAR(80) NOT NULL,                        -- who wrote it (or the bank)
    `issuer_job`      VARCHAR(60) NULL,                            -- company bills: the company job
    `issuer_label`    VARCHAR(100) NULL,                           -- company name / "Bank - Valentine"
    `bank_id`         VARCHAR(40) NULL,                            -- bank debt bills: the bank that gets the money
    `loan_id`         INT(11) NULL,
    `target_cid`      VARCHAR(60) NOT NULL,
    `target_name`     VARCHAR(80) NOT NULL,
    `amount`          DECIMAL(14,2) NOT NULL,
    `reason`          VARCHAR(255) NULL,
    `status`          VARCHAR(10) NOT NULL DEFAULT 'unsigned',     -- unsigned | unpaid | paid | refused | deleted
    `signed_name`     VARCHAR(80) NULL,
    `signed_at`       INT(11) NULL,
    `paid_at`         INT(11) NULL,
    `paid_via`        VARCHAR(40) NULL,                            -- cash | bank:<bankId>
    `created_at`      INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_target` (`target_cid`, `status`),
    KEY `idx_issuer` (`issuer_cid`),
    KEY `idx_status` (`status`),
    KEY `idx_job` (`issuer_job`),
    KEY `idx_target_name` (`target_name`),
    KEY `idx_issuer_name` (`issuer_name`),
    KEY `idx_signed_name` (`signed_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Frozen characters (all their accounts in every bank, also accounts opened later)
CREATE TABLE IF NOT EXISTS `fks_bank_frozen` (
    `cid`             VARCHAR(60) NOT NULL,
    `name`            VARCHAR(80) NULL,
    `bill_id`         INT(11) NULL,
    `frozen_by`       VARCHAR(80) NULL,
    `frozen_at`       INT(11) NOT NULL,
    PRIMARY KEY (`cid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Government action log (freeze / unfreeze / bill deleted)
CREATE TABLE IF NOT EXISTS `fks_bank_frozen_log` (
    `id`              INT(11) NOT NULL AUTO_INCREMENT,
    `action`          VARCHAR(20) NOT NULL,                        -- freeze | unfreeze | delete_bill
    `actor_cid`       VARCHAR(60) NULL,
    `actor_name`      VARCHAR(80) NULL,
    `actor_job`       VARCHAR(60) NULL,
    `target_cid`      VARCHAR(60) NULL,
    `target_name`     VARCHAR(80) NULL,
    `bill_id`         INT(11) NULL,
    `details`         VARCHAR(255) NULL,
    `created_at`      INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_target` (`target_cid`),
    KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Things waiting for a character that was offline: cash, items, notifications
CREATE TABLE IF NOT EXISTS `fks_bank_pending` (
    `id`              INT(11) NOT NULL AUTO_INCREMENT,
    `cid`             VARCHAR(60) NOT NULL,
    `kind`            VARCHAR(10) NOT NULL,                        -- cash | item | notify
    `amount`          DECIMAL(14,2) NOT NULL DEFAULT 0,
    `item`            VARCHAR(80) NULL,
    `message`         VARCHAR(60) NULL,                            -- locale key
    `args`            TEXT NULL,                                   -- JSON array for the locale string
    `created_at`      INT(11) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_cid` (`cid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
