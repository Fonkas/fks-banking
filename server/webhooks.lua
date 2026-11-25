---------------------------------------------------------------------------
-- Discord webhooks (Config.Webhooks). Fire and forget: a failing webhook never blocks the game.
--   Webhook('Government', 'Accounts frozen', 'John Smith froze ...', { { 'Bill', '#12' } })
---------------------------------------------------------------------------
local COLORS = { Government = 13917759, Banker = 15909198, Bills = 10273402, Accounts = 9419689 }

function Webhook(channel, title, text, fields)
    local W = Config.Webhooks
    if not W.Enabled then return end
    local url = W[channel]
    if type(url) ~= 'string' or url == '' then return end
    local embed = {
        title = title,
        description = text,
        color = COLORS[channel] or 15909198,
        footer = { text = ('%s · %s'):format(W.Name or 'FKS Banking', os.date('%Y-%m-%d %H:%M:%S')) },
        fields = {},
    }
    for _, f in ipairs(fields or {}) do
        embed.fields[#embed.fields + 1] = { name = tostring(f[1]), value = tostring(f[2]), inline = f[3] ~= false }
    end
    PerformHttpRequest(url, function(status)
        if status and (status < 200 or status >= 300) then
            Debug('webhook %s answered HTTP %s', channel, tostring(status))
        end
    end, 'POST', json.encode({ username = W.Name or 'FKS Banking', embeds = { embed } }), { ['Content-Type'] = 'application/json' })
end
