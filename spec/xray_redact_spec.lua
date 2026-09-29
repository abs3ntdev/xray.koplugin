package.path = "xray.koplugin/?.lua;spec/?.lua;" .. package.path
require("spec.spec_helper")

local Redact = require("xray_redact")

describe("xray_redact", function()
    after_each(function() Redact.clear_registered() end)

    it("redacts bearer tokens", function()
        local out = Redact.redact("Authorization: Bearer abc.DEF-123_xyz")
        assert.is_nil(out:find("abc.DEF-123_xyz", 1, true))
        assert.is_not_nil(out:find("Bearer [REDACTED]", 1, true))
    end)

    it("redacts JWTs", function()
        local jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"
        assert.is_nil(Redact.redact("tok " .. jwt .. " end"):find(jwt, 1, true))
    end)

    it("redacts known API key shapes", function()
        for _, k in ipairs({ "sk-proj-AbC123_xyz", "sk-ant-api03-zzz", "AIzaSyD-abc_123", "AQ.TestGeminiKey123" }) do
            assert.is_nil(Redact.redact("key=" .. k .. " x"):find(k, 1, true))
        end
    end)

    it("redacts JSON credential fields including refresh tokens", function()
        local body = '{"access_token":"opaque1","refresh_token":"opaque2","id_token":"opaque3","api_key":"opaque4","client_secret":"opaque5","ok":"keep"}'
        local out = Redact.redact(body)
        for i = 1, 5 do assert.is_nil(out:find("opaque" .. i, 1, true)) end
        assert.is_not_nil(out:find('"ok":"keep"', 1, true))
    end)

    it("redacts query string tokens", function()
        local out = Redact.redact("GET /x?code=1&access_token=opaqueQ&key=opaqueK")
        assert.is_nil(out:find("opaqueQ", 1, true))
        assert.is_nil(out:find("opaqueK", 1, true))
    end)

    it("redacts registered exact secrets containing pattern characters", function()
        local secret = "rt_%weird.(value)+123"
        Redact.register(secret)
        assert.is_nil(Redact.redact("x " .. secret .. " y"):find(secret, 1, true))
        Redact.unregister(secret)
        assert.is_not_nil(Redact.redact("x " .. secret):find(secret, 1, true))
    end)

    it("ignores too-short registered secrets", function()
        Redact.register("abc")
        assert.are.equal("abc def", Redact.redact("abc def"))
    end)

    it("handles non-string values", function()
        assert.are.equal("42", Redact.redact(42))
        assert.are.equal("nil", Redact.redact(nil))
        assert.are.equal("true", Redact.redact(true))
        assert.is_string(Redact.redact({}))
        local bad = setmetatable({}, { __tostring = function() error("boom") end })
        assert.are.equal("[unprintable]", Redact.redact(bad))
    end)

    it("leaves ordinary text unchanged", function()
        local s = "Chapter 3: The token of friendship, keyed to skill."
        assert.are.equal(s, Redact.redact(s))
    end)
end)

describe("xray_logger sanitation", function()
    local Logger

    setup(function()
        local saved = package.loaded["xray_logger"]
        package.loaded["xray_logger"] = nil
        Logger = dofile("xray.koplugin/xray_logger.lua")
        package.loaded["xray_logger"] = saved
    end)

    before_each(function()
        Logger._buf = {}
        Logger._buf_count = 0
        Logger._buffer_limit = 1000
    end)

    after_each(function() Logger._buf = {}; Logger._buf_count = 0 end)

    it("redacts via info/warn/err and log", function()
        Logger.info("Bearer secretinfo123")
        Logger.warn('{"refresh_token":"secretwarn"}')
        Logger.err("sk-secreterr")
        Logger:log("eyJa.eyJb.sig")
        local all = table.concat(Logger._buf)
        assert.is_nil(all:find("secretinfo123", 1, true))
        assert.is_nil(all:find("secretwarn", 1, true))
        assert.is_nil(all:find("secreterr", 1, true))
        assert.is_nil(all:find("eyJa.eyJb", 1, true))
        assert.are.equal(4, #Logger._buf)
    end)

    it("accepts non-string args", function()
        Logger.info(nil)
        Logger.err({})
        Logger:log(12)
        assert.are.equal(3, #Logger._buf)
    end)

    it("masks registered secrets", function()
        Logger.registerSecret("opaque-registered-xyz")
        Logger.info("value opaque-registered-xyz here")
        Logger.unregisterSecret("opaque-registered-xyz")
        assert.is_nil(table.concat(Logger._buf):find("opaque-registered-xyz", 1, true))
    end)
end)

describe("xray_logger without redactor", function()
    it("fails closed with a fixed placeholder", function()
        local saved_r, saved_l = package.loaded["xray_redact"], package.loaded["xray_logger"]
        package.preload["xray_redact"] = function() error("missing") end
        package.loaded["xray_redact"] = nil
        local ok, L = pcall(dofile, "xray.koplugin/xray_logger.lua")
        package.preload["xray_redact"] = nil
        package.loaded["xray_redact"], package.loaded["xray_logger"] = saved_r, saved_l
        assert.is_true(ok)
        L._buf, L._buf_count, L._buffer_limit = {}, 0, 1000
        L.info("plain-secret-value")
        local all = table.concat(L._buf)
        assert.is_nil(all:find("plain-secret-value", 1, true))
        assert.is_not_nil(all:find("redactor unavailable", 1, true))
    end)
end)
