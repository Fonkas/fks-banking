-- fks-banking · Copyright (C) 2026 FKS · Licensed under the GNU GPL v3 or later (see LICENSE)
fx_version 'cerulean'
game 'rdr3'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
lua54 'yes'

name 'fks-banking'
author 'FKS'
description 'FKS Banking for RedM (VORP / RSG): per-town bank accounts, gold, gold bar investments, rented vault boxes, banker job (loans, telegraph, gold exchange), bills and government account freezes'
version '1.0.0'
license 'GPL-3.0-or-later'
fks_core_version '2.2.0' -- minimum fks-core version (signature + table components, Bridge.StashUsage)

shared_scripts {
    '@ox_lib/init.lua',
    '@fks-core/import.lua',   -- fks-core bridge (VORP / RSG, inventories) + the shared FKS UI
    'config.lua',
    'locales/*.lua',
    'shared/locale.lua',
    'shared/utils.lua',
}

client_scripts {
    'client/main.lua',
    'client/bank.lua',
    'client/banker.lua',
    'client/billing.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/db.lua',
    'server/main.lua',
    'server/webhooks.lua',
    'server/vault.lua',
    'server/accounts.lua',
    'server/goldbars.lua',
    'server/storage.lua',
    'server/loans.lua',
    'server/banker.lua',
    'server/billing.lua',
    'server/government.lua',
    'server/exports.lua',
}

-- no ui_page: every screen is drawn by fks-core (one NUI for every FKS script)
files {
    'sql/install.sql',
    'img/icons/*.svg',
}

-- + a framework (vorp_core or rsg-core) and an inventory (vorp_inventory, rsg-inventory or ox_inventory)
dependencies {
    'fks-core',
    'ox_lib',
    'oxmysql',
}
