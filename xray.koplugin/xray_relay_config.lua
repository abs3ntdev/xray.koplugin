-- One setup origin for API keys, Claude codes and TypeSafe phone transfers.
-- This never changes the pinned model/OAuth destinations.
local Config = {
    DEFAULT_URL = "https://xray-setup.ultimatejimmy.workers.dev",
    SETTING = "cloud_setup_worker_url",
    ERROR = "Enter an HTTPS origin such as https://xray.example.com, without a port, path, query or fragment.",
}

function Config.normalize(value)
    if type(value) ~= "string" or #value > 270 or value:find("[%c%s]") then
        return nil, Config.ERROR
    end
    local host = value:lower():match("^https://([a-z0-9%.%-]+)/?$")
    if not host or #host > 253 or not host:find(".", 1, true)
        or host:find("..", 1, true) or host:sub(-1) == "."
        or host:match("^[%d%.]+$") then return nil, Config.ERROR end
    for label in host:gmatch("[^.]+") do
        if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then
            return nil, Config.ERROR
        end
    end
    if host:sub(1, 1) == "." then return nil, Config.ERROR end
    return "https://" .. host, host
end

function Config.resolve(settings)
    local value
    if type(settings) == "table" then value = settings[Config.SETTING] end
    -- Only an absent setting selects the built-in service. Invalid configured
    -- values must never silently send a pairing session to another server.
    if value == nil then value = Config.DEFAULT_URL end
    return Config.normalize(value)
end

function Config.save(helper, value)
    local origin, message = Config.normalize(value)
    if not origin then return nil, message end
    local ok, saved = false, false
    if helper and type(helper.saveSettings) == "function" then
        ok, saved = pcall(helper.saveSettings, helper, { [Config.SETTING] = origin })
    end
    if not ok or saved ~= true then
        return nil, "Could not save the setup relay. The previous setting is unchanged."
    end
    return true, origin
end

return Config
