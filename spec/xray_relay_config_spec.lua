package.path = package.path .. ";xray.koplugin/?.lua"
local Config = require("xray_relay_config")

describe("Setup relay configuration", function()
    it("defaults only an absent setting and normalizes HTTPS origins", function()
        assert.are.equal(Config.DEFAULT_URL, Config.resolve({}))
        assert.are.equal(Config.DEFAULT_URL, Config.resolve(nil))
        local url, host = Config.normalize("HTTPS://XRAY.example.com/")
        assert.are.equal("https://xray.example.com", url)
        assert.are.equal("xray.example.com", host)
        assert.are.equal(url, Config.resolve({ cloud_setup_worker_url = url }))
    end)

    it("rejects unsafe or ambiguous values instead of falling back", function()
        for _, value in ipairs({ false, 123, "", " ", "http://xray.example.com", "https://user@xray.example.com",
            "https://xray.example.com:443", "https://xray.example.com:3000", "https://xray.example.com/path",
            "https://xray.example.com?next=evil", "https://xray.example.com#secret", "https://xray.example.com//",
            "https://xray.example.com/\n", "https://xray..example.com", "https://.example.com",
            "https://xray.example.com.", "https://-xray.example.com", "https://xray-.example.com",
            "https://xray_example.com", "https://localhost", "https://127.0.0.1", "https://[::1]",
            "https://" .. string.rep("x", 64) .. ".example.com", "https://xray.example.com\\@evil.example" }) do
            assert.is_nil(Config.normalize(value))
            assert.is_nil(Config.resolve({ cloud_setup_worker_url = value }))
        end
    end)

    it("saves through the existing atomic settings API without changing model configuration", function()
        local helper = { settings = { primary_ai = { provider = "claude" } }, calls = 0 }
        function helper:saveSettings(update)
            self.calls = self.calls + 1
            for k, v in pairs(update) do self.settings[k] = v end
            return true
        end
        local ok, url = Config.save(helper, "https://OWN.example.com/")
        assert.is_true(ok)
        assert.are.equal("https://own.example.com", url)
        assert.are.equal(url, helper.settings.cloud_setup_worker_url)
        assert.are.equal("claude", helper.settings.primary_ai.provider)
        assert.is_nil(Config.save(helper, "http://own.example.com"))
        assert.are.equal(1, helper.calls)
    end)

    it("reports persistence failures and does not publish a new setting", function()
        local helper = { settings = { cloud_setup_worker_url = "https://old.example.com" },
            saveSettings = function() return false end }
        assert.is_nil(Config.save(helper, "https://new.example.com"))
        assert.are.equal("https://old.example.com", helper.settings.cloud_setup_worker_url)
        helper.saveSettings = function() error("disk failure") end
        local ok, message = Config.save(helper, "https://new.example.com")
        assert.is_nil(ok)
        assert.is_nil(message:find("disk failure", 1, true))
    end)
end)
