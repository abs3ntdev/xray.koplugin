package.path = "xray.koplugin/?.lua;spec/?.lua;" .. package.path
require("spec.spec_helper")

local WebSetup = require("xray_websetup")

describe("xray_websetup", function()
    local mock_ai_helper
    local mock_loc
    local saved_prov, saved_key

    before_each(function()
        saved_prov = nil
        saved_key = nil
        mock_ai_helper = {
            settings = {},
            setAPIKey = function(self, prov, key)
                saved_prov = prov
                saved_key = key
            end,
            setCustomAPIConfig = function(self, prov, key, endpoint, model)
                saved_prov = prov
                saved_key = key
            end,
            updateConfigKey = function(self, k, v) end,
        }
        mock_loc = {
            t = function(self, k, arg) return k .. ":" .. tostring(arg or "") end
        }
    end)

    it("returns formatted provider display names", function()
        assert.are.equal("Google Gemini", WebSetup:getProviderDisplayName("gemini"))
        assert.are.equal("OpenAI ChatGPT", WebSetup:getProviderDisplayName("chatgpt"))
        assert.are.equal("DeepSeek", WebSetup:getProviderDisplayName("deepseek"))
        assert.are.equal("Anthropic Claude", WebSetup:getProviderDisplayName("claude"))
        assert.are.equal("Custom API", WebSetup:getProviderDisplayName("custom1"))
    end)

    it("applies received key to AIHelper", function()
        WebSetup.ai_helper = mock_ai_helper
        WebSetup.loc = mock_loc

        local payload = {
            provider = "gemini",
            api_key = "AQ.TestGeminiKey123"
        }

        local ok, err = WebSetup:applyReceivedKey(payload)
        assert.is_true(ok)
        assert.are.equal("gemini", saved_prov)
        assert.are.equal("AQ.TestGeminiKey123", saved_key)
    end)

    it("handles custom API configuration payloads", function()
        WebSetup.ai_helper = mock_ai_helper
        WebSetup.loc = mock_loc

        local payload = {
            provider = "custom1",
            api_key = "sk-or-testkey",
            endpoint = "https://openrouter.ai/api/v1/chat/completions",
            model = "google/gemini-flash"
        }

        local ok, err = WebSetup:applyReceivedKey(payload)
        assert.is_true(ok)
        assert.are.equal("custom1", saved_prov)
        assert.are.equal("sk-or-testkey", saved_key)
    end)

    it("stops cleanly and clears session state", function()
        WebSetup.is_running = true
        WebSetup.session_id = "ABC123"
        WebSetup.session_secret = "secret"
        WebSetup:stop()

        assert.is_false(WebSetup.is_running)
        assert.is_nil(WebSetup.session_id)
        assert.is_nil(WebSetup.session_secret)
    end)

    it("correctly identifies whether local server is supported by device", function()
        local Device = require("device")
        local orig_isKindle = Device.isKindle

        -- When device is Kindle (firewall blocks inbound connections)
        Device.isKindle = function() return true end
        assert.is_false(WebSetup:isLocalServerSupported())

        -- When device is Android / Kobo / etc.
        Device.isKindle = function() return false end
        assert.is_true(WebSetup:isLocalServerSupported())

        Device.isKindle = orig_isKindle
    end)
    it("never logs decrypted payload or raw relay responses", function()
        local logger = package.loaded["xray_logger"]
        local Transfer = require("xray_code_transfer")
        local HTTP = require("xray_secure_http")
        local secret = "sk-supersecret-relay-value-123"
        local lines = {}
        local saved = { err = logger.err, warn = logger.warn, info = logger.info,
            decrypt = Transfer.decrypt, req = HTTP.requestRelay }
        local function capture(msg)
            table.insert(lines, tostring(msg))
            WebSetup.is_running = false -- stop the synchronous poll loop
        end
        logger.err = capture
        logger.warn = capture
        logger.info = function(msg) table.insert(lines, tostring(msg)) end
        Transfer.decrypt = function() return '{"not_api_key":"' .. secret .. '"}' end
        HTTP.requestRelay = function()
            return true, 200, '{"status":"ready","payload":"' .. secret .. '"}'
        end

        local ok, err = pcall(function()
            WebSetup.is_running = true
            WebSetup.session_id = "sess"
            WebSetup.poll_start_time = os.time()
            WebSetup:pollCloudRelay("https://relay.example", "sess", "00")

            HTTP.requestRelay = function()
                return true, 500, '{"error":"' .. secret .. '"}'
            end
            WebSetup.is_running = true
            WebSetup:pollCloudRelay("https://relay.example", "sess", "00")
        end)

        logger.err, logger.warn, logger.info = saved.err, saved.warn, saved.info
        Transfer.decrypt = saved.decrypt
        HTTP.requestRelay = saved.req
        WebSetup.is_running = false
        WebSetup.session_id = nil
        assert.is_true(ok, tostring(err))

        assert.is_true(#lines >= 2)
        for _, line in ipairs(lines) do
            assert.is_nil(line:find(secret, 1, true))
        end
    end)
end)


describe("Web setup owned relay settings", function()
    local UIManager = require("ui/uimanager")
    local HTTP = require("xray_secure_http")
    local Transfer = require("xray_code_transfer")
    local Config = require("xray_relay_config")
    local helper, saved, calls, callbacks, polls, secret_calls
    before_each(function()
        saved = { request = HTTP.requestRelay, generate = Transfer.generateSecret, poll = WebSetup.pollCloudRelay }
        calls, callbacks, polls, secret_calls = {}, 0, {}, 0
        helper = { settings = {}, saves = 0 }
        function helper:saveSettings(update)
            self.saves = self.saves + 1
            if self.fail then return false end
            for k, v in pairs(update) do self.settings[k] = v end
            return true
        end
        HTTP.requestRelay = function(_, origin, path, method, headers, body)
            calls[#calls + 1] = { origin = origin, path = path, method = method, headers = headers, body = body }
            return true, 200, '{"session_id":"AB12CD"}'
        end
        Transfer.generateSecret = function()
            secret_calls = secret_calls + 1
            return string.rep("a", 64)
        end
        WebSetup.pollCloudRelay = function(_, origin, id, key)
            polls[#polls + 1] = { origin = origin, id = id, key = key }
        end
        _G.ui_tracker.shown, _G.ui_tracker.closed = {}, {}
        WebSetup:stop()
    end)
    after_each(function()
        WebSetup:stop()
        HTTP.requestRelay, Transfer.generateSecret, WebSetup.pollCloudRelay = saved.request, saved.generate, saved.poll
    end)
    local function open()
        WebSetup:showRelaySettings(helper, function() callbacks = callbacks + 1 end)
        return _G.ui_tracker.last_shown
    end
    it("saves normalized custom origin, cancels without writes and restores upstream only explicitly", function()
        local dialog = open()
        assert.are.equal(Config.DEFAULT_URL, dialog.args.input)
        dialog.getInputText = function() return " https://OWNED.example.com/ " end
        dialog.args.buttons[1][2].callback()
        assert.are.equal("https://owned.example.com", helper.settings.cloud_setup_worker_url)
        assert.are.equal(1, helper.saves) assert.are.equal(1, callbacks)
        dialog = open()
        assert.are.equal("https://owned.example.com", dialog.args.input)
        dialog.args.buttons[1][1].callback()
        assert.are.equal(1, helper.saves)
        dialog = open()
        dialog.args.buttons[2][1].callback()
        assert.are.equal(Config.DEFAULT_URL, helper.settings.cloud_setup_worker_url)
        assert.are.equal(2, callbacks)
        assert.are.equal(0, #calls)
    end)
    it("keeps the prior origin when entry is invalid or saving fails", function()
        helper.settings.cloud_setup_worker_url = "https://old.example.com"
        local dialog = open()
        dialog.getInputText = function() return "http://new.example.com" end
        dialog.args.buttons[1][2].callback()
        assert.are.equal(0, helper.saves) assert.are.equal(0, callbacks)
        assert.are.equal("https://old.example.com", helper.settings.cloud_setup_worker_url)
        helper.fail = true
        dialog.getInputText = function() return "https://new.example.com" end
        dialog.args.buttons[1][2].callback()
        assert.are.equal(0, callbacks)
        assert.are.equal("https://old.example.com", helper.settings.cloud_setup_worker_url)
    end)
    it("creates and polls only at the configured origin with a fragment-only secret", function()
        helper.settings.cloud_setup_worker_url = "https://OWNED.example.com/"
        assert.is_true(WebSetup:startCloudRelay(helper, nil))
        assert.are.equal("https://owned.example.com", calls[1].origin)
        assert.are.equal("/api/session/create", calls[1].path)
        assert.are.equal("{}", calls[1].body)
        assert.is_nil(calls[1].headers.Authorization)
        assert.are.equal(calls[1].origin, polls[1].origin)
        assert.are.equal("AB12CD", polls[1].id)
        assert.are.equal(string.rep("a", 64), polls[1].key)
        WebSetup.dialog.buttons[1][1].callback()
        assert.truthy(_G.ui_tracker.last_shown.args.title:find("https://owned.example.com/?s=AB12CD#" .. string.rep("a", 64), 1, true))
        local link_dialog = WebSetup.link_dialog
        WebSetup:stop()
        assert.is_nil(WebSetup.link_dialog)
        local closed = false
        for _, dialog in ipairs(_G.ui_tracker.closed) do if dialog == link_dialog then closed = true end end
        assert.is_true(closed)
    end)
    it("fails before network with invalid configuration or no secure entropy", function()
        helper.settings.cloud_setup_worker_url = "https://owned.example.com/path"
        assert.is_false(WebSetup:startCloudRelay(helper, nil))
        assert.are.equal(0, #calls) assert.are.equal(0, secret_calls)
        helper.settings.cloud_setup_worker_url = "https://owned.example.com"
        Transfer.generateSecret = function() return nil end
        assert.is_false(WebSetup:startCloudRelay(helper, nil))
        assert.are.equal(0, #calls)
    end)
end)
