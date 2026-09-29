-- All relay traffic is injected. No live network, auth, config or key access.
-- VECTOR was produced by the deployed page's encryptPayload algorithm
-- (WebCrypto HMAC-SHA256 CTR + "AUTH" tag) for key KEY, with payload
-- {provider="gemini", api_key="synthetic-code#state", timestamp=1}.
package.path = package.path .. ";xray.koplugin/?.lua"
local KEY = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
local VECTOR = "HMAC:AQIDBAUGBwgJCgsMDQ4PEFCQPlEM8osZ0WaDjWsKPYy471jk8ssDEp4DmiiFW3yHkG/ERXiPyod69NzlMOO4rxvuTQvFsxvRXs8NMrSpI9xhNyB0MibcFAIu75koIra6BwmqyQ=="
local RELAY = "https://xray-setup.ultimatejimmy.workers.dev"
-- Adversarial fixtures from the same public algorithm (Node WebCrypto), with
-- the same plaintext but keyed by the legacy fallbacks the receiver must NOT
-- accept: SHA256("AB12CD") (the session ID), SHA256("XRAY-DEFAULT") and the
-- first 32 hex of KEY zero-padded. *_FLIP are the valid vector with one bit
-- flipped in the IV, tag and ciphertext respectively, keeping the prefix.
local SESSION_KEYED = "HMAC:AQIDBAUGBwgJCgsMDQ4PEIiUGBeQyXVYg9FjzhpUy7vz3AyxBAbBZG3shQbkrh57ywDEZmu6rK2jtevR9+nJF7vtCq+Aop6hN4nlzSE3ZUYxI0PhYg36Yu3T20YI8tE6ByJwow=="
local DEFAULT_KEYED = "HMAC:AQIDBAUGBwgJCgsMDQ4PEB7B4/w+JaHwjm+ZYOsnIyN/AL2ASAEYaSGEI6yZ/qbGV86Smvvf0dWUVabPvmGx+KbWVBjG20EuaY6FUr01/4upveQvqlwWJrQVAhoZsdY+SDYyIg=="
local PADDED_KEYED = "HMAC:AQIDBAUGBwgJCgsMDQ4PECkiqdixLnzgXyn+iYtutqLQDuZYpFg/u4VUTACcQnYaSgWEnUqkjRHs/5Uie1erx8UY24DFoqkjqeR+9z9do+8REnauH9YdWMCm8h/QPZL3fgNEYw=="
local IV_FLIP = "HMAC:AAIDBAUGBwgJCgsMDQ4PEFCQPlEM8osZ0WaDjWsKPYy471jk8ssDEp4DmiiFW3yHkG/ERXiPyod69NzlMOO4rxvuTQvFsxvRXs8NMrSpI9xhNyB0MibcFAIu75koIra6BwmqyQ=="
local TAG_FLIP = "HMAC:AQIDBAUGBwgJCgsMDQ4PEFCQPlEN8osZ0WaDjWsKPYy471jk8ssDEp4DmiiFW3yHkG/ERXiPyod69NzlMOO4rxvuTQvFsxvRXs8NMrSpI9xhNyB0MibcFAIu75koIra6BwmqyQ=="
local CT_FLIP = "HMAC:AQIDBAUGBwgJCgsMDQ4PEFCQPlEM8osZ0WaDjWsKPYy471jk8ssDEp8DmiiFW3yHkG/ERXiPyod69NzlMOO4rxvuTQvFsxvRXs8NMrSpI9xhNyB0MibcFAIu75koIra6BwmqyQ=="
local json = require("dkjson")

describe("Phone code transfer", function()
    local T, calls, responses, clock, entropy_bytes, hook, previous_json
    local function hexToBytes(hex)
        return (hex:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end))
    end
    before_each(function()
        previous_json = package.loaded.json
        package.loaded.json = json
        package.loaded.xray_code_transfer = nil
        local Module = dofile("xray.koplugin/xray_code_transfer.lua")
        calls, responses, clock, entropy_bytes, hook = {}, {}, 1000, hexToBytes(KEY), nil
        T = Module.new({
            time = function() return clock end,
            entropy = function(n) assert.are.equal(32, n) return entropy_bytes end,
            http = { request = function(_, url, method, headers, body, timeout)
                calls[#calls + 1] = { url = url, method = method, headers = headers, body = body, timeout = timeout }
                if hook then hook() end
                local r = table.remove(responses, 1) or { true, 204, "" }
                return r[1], r[2], r[3]
            end },
        })
    end)
    after_each(function()
        package.loaded.json = previous_json
    end)
    local function ready(payload)
        return { true, 200, '{"status":"ready","payload":"' .. payload .. '"}' }
    end
    local function session()
        responses[#responses + 1] = { true, 200, '{"session_id":"AB12CD"}' }
        local s = T:start(clock + 300)
        assert.is_table(s)
        return s
    end

    it("creates a pinned relay session with a fragment-only 64-hex secret", function()
        local s = session()
        assert.are.equal(RELAY .. "/api/session/create", calls[1].url)
        assert.are.equal("POST", calls[1].method)
        assert.are.equal(RELAY .. "/?s=AB12CD#" .. KEY, s.url)
        assert.are.equal("AB12CD", s.id)
        assert.is_nil(calls[1].headers.Authorization)
        assert.is_nil(calls[1].body:find(KEY, 1, true))
    end)

    it("fails closed before network without strong entropy", function()
        for _, bad in ipairs({ false, "short", string.rep("x", 31), string.rep("x", 33) }) do
            entropy_bytes = bad or nil
            local s, code = T:start(clock + 300)
            assert.is_nil(s)
            assert.are.equal("entropy_unavailable", code)
        end
        T.entropy = function() error("boom") end
        assert.is_nil(T:start(clock + 300))
        assert.are.equal(0, #calls)
    end)

    it("caps lifetime to the flow expiry and 600 seconds and rejects expired flows", function()
        responses[1] = { true, 200, '{"session_id":"AB12CD"}' }
        assert.are.equal(clock + 600, T:start(clock + 5000).expires_at)
        local s, code = T:start(clock)
        assert.is_nil(s) assert.are.equal("expired", code)
        assert.is_nil(T:start(nil))
        assert.are.equal(1, #calls)
    end)

    it("rejects malformed or unexpected relay session IDs", function()
        for _, body in ipairs({ '{"session_id":"ab12cd"}', '{"session_id":"AB12CD7"}', '{"session_id":"AB/2CD"}',
            '{"session_id":12}', "not json", '{}' }) do
            responses[1] = { true, 200, body }
            local s, code = T:start(clock + 300)
            assert.is_nil(s) assert.are.equal("relay_error", code)
        end
        responses[1] = { true, 500, '{"session_id":"AB12CD"}' }
        assert.is_nil(T:start(clock + 300))
        responses[1] = { nil, "tls_failed", "x" }
        assert.is_nil(T:start(clock + 300))
    end)

    it("decrypts the public page vector and returns only the api_key text once", function()
        local s = session()
        responses[1] = ready(VECTOR)
        assert.are.equal("synthetic-code#state", T:poll(s))
        assert.are.equal(RELAY .. "/api/session/AB12CD/poll", calls[2].url)
        assert.are.equal("GET", calls[2].method)
        assert.is_nil(s.secret) assert.is_nil(s.url)
        local n = #calls
        local code, err = T:poll(s)
        assert.is_nil(code) assert.are.equal("consumed", err)
        assert.are.equal(n, #calls)
    end)

    it("keeps pending on 204, transport errors, garbage and non-ready JSON", function()
        local s = session()
        for _, r in ipairs({ { true, 204, "" }, { nil, "network_error" }, { true, 200, "garbage" },
            { true, 200, '{"status":"waiting"}' }, { true, 500, "" },
            { true, 200, string.rep(" ", 20000) } }) do
            responses[1] = r
            local code, state = T:poll(s)
            assert.is_nil(code) assert.are.equal("pending", state)
        end
    end)

    it("treats tampered, non-canonical, oversize and wrong-key ciphertext as pending", function()
        local s = session()
        local body = VECTOR:sub(6)
        local flipped = body:sub(1, 30) .. (body:sub(31, 31) == "A" and "B" or "A") .. body:sub(32)
        local bad = {
            flipped, body, "HMAC:" .. body:sub(1, -2), "HMAC:" .. body .. "\n",
            "HMAC: " .. body, "HMAC:" .. body:gsub("==$", "=A"), "HMAC:AAAA",
            "HMAC:" .. string.rep("A", 9000), "HMAC:" .. body:gsub("Q==$", "R=="),
        }
        for _, p in ipairs(bad) do
            responses[1] = ready((p:gsub("\n", "\\n")))
            local code, state = T:poll(s)
            assert.is_nil(code) assert.are.equal("pending", state)
        end
        assert.is_truthy(s.secret)
    end)

    it("rejects ciphertext keyed by session ID, default or padded keys and bit flips", function()
        -- Sanity: the legacy multi-key decryptor accepts these fixtures, so
        -- they really are the fallback-keyed ciphertexts.
        local Legacy = dofile("xray.koplugin/xray_crypto.lua")
        for _, v in ipairs({ SESSION_KEYED, DEFAULT_KEYED }) do
            assert.is_truthy(Legacy:decryptPayload(v, nil, "AB12CD"))
        end
        assert.is_truthy(Legacy:decryptPayload(PADDED_KEYED, KEY:sub(1, 32), nil))
        local s = session()
        for _, v in ipairs({ SESSION_KEYED, DEFAULT_KEYED, PADDED_KEYED, IV_FLIP, TAG_FLIP, CT_FLIP }) do
            assert.is_nil(T:decrypt(v, KEY))
            responses[1] = ready(v)
            local code, state = T:poll(s)
            assert.is_nil(code) assert.are.equal("pending", state)
        end
        assert.is_truthy(s.secret)
        assert.is_nil(s.consumed)
    end)

    it("rejects oversize ciphertext before invoking crypto", function()
        local called = 0
        T.crypto = { decryptHMACStream = function() called = called + 1 return "{}" end }
        assert.is_nil(T:decrypt("HMAC:" .. string.rep("A", 8200), KEY))
        assert.is_nil(T:decrypt("HMAC:" .. string.rep("A", 5600), KEY))
        assert.is_nil(T:decrypt("HMAC:AAAA", KEY))
        assert.are.equal(0, called)
    end)

    it("only accepts the exact full 64-hex key", function()
        assert.are.equal('{"provider":"gemini","api_key":"synthetic-code#state","timestamp":1}',
            T:decrypt(VECTOR, KEY))
        assert.is_nil(T:decrypt(VECTOR, KEY:sub(1, 32)))
        assert.is_nil(T:decrypt(VECTOR, KEY .. "00"))
        assert.is_nil(T:decrypt(VECTOR, KEY:sub(1, 63) .. "g"))
        assert.is_nil(T:decrypt(VECTOR, string.rep("0", 64)))
        assert.is_nil(T:decrypt(VECTOR, nil))
        assert.is_nil(T:decrypt(VECTOR:sub(6), KEY))
    end)

    it("strict base64 rejects non-canonical input", function()
        local d = T.strictBase64Decode
        assert.are.equal("hi", d("aGk="))
        assert.are.equal("h", d("aA=="))
        assert.is_nil(d("aGl=")) assert.is_nil(d("aB==")) assert.is_nil(d("aGk"))
        assert.is_nil(d("aG k=")) assert.is_nil(d("a=Gk")) assert.is_nil(d("aGk=aGk="))
        assert.is_nil(d("")) assert.is_nil(d("a-_k"))
    end)

    it("rejects missing, empty, oversized or control-bearing api_key", function()
        local s = session()
        T.decrypt = function(_, _, _) return T.plain end
        for _, plain in ipairs({ '{"provider":"x"}', '{"api_key":""}', '{"api_key":5}',
            '{"api_key":"a\\u0000b"}', '{"api_key":"' .. string.rep("a", 3000) .. '"}', "[]" }) do
            T.plain = plain
            responses[1] = ready("x")
            local code, state = T:poll(s)
            assert.is_nil(code) assert.are.equal("pending", state)
        end
        T.plain = '{"api_key":"  code  ","provider":"openai","endpoint":"https://evil"}'
        responses[1] = ready("x")
        assert.are.equal("code", T:poll(s))
    end)

    it("cancel discards secrets and prevents further requests", function()
        local s = session()
        T:cancel(s)
        assert.is_nil(s.secret) assert.is_nil(s.url)
        local n = #calls
        local code, err = T:poll(s)
        assert.is_nil(code) assert.are.equal("cancelled", err)
        assert.are.equal(n, #calls)
    end)

    it("does not deliver when cancelled or expired while a poll is in flight", function()
        local s = session()
        hook = function() T:cancel(s) end
        responses[1] = ready(VECTOR)
        local code, err = T:poll(s)
        assert.is_nil(code) assert.are.equal("cancelled", err)
        s = session()
        hook = function() clock = clock + 1000 end
        responses[1] = ready(VECTOR)
        code, err = T:poll(s)
        assert.is_nil(code) assert.are.equal("expired", err)
        assert.is_nil(s.secret)
    end)

    it("rechecks cancellation after decryption before latching", function()
        local s = session()
        local real = T.decrypt
        T.decrypt = function(self, p, k) local r = real(self, p, k) T:cancel(s) return r end
        responses[1] = ready(VECTOR)
        local code, err = T:poll(s)
        assert.is_nil(code) assert.are.equal("cancelled", err)
        assert.is_nil(s.consumed)
    end)

    it("uses a short poll timeout capped by the remaining lifetime", function()
        local s = session()
        T:poll(s)
        assert.are.equal(4, calls[2].timeout)
        clock = clock + 298
        T:poll(s)
        assert.are.equal(2, calls[3].timeout)
    end)

    it("expires without network after the deadline, keeps 404 pending and ends on 410", function()
        local s = session()
        clock = clock + 301
        local n = #calls
        local code, err = T:poll(s)
        assert.is_nil(code) assert.are.equal("expired", err)
        assert.are.equal(n, #calls)
        clock = 1000
        s = session()
        responses[1] = { true, 404, "" }
        code, err = T:poll(s)
        assert.is_nil(code) assert.are.equal("pending", err)
        assert.is_truthy(s.secret)
        responses[1] = { true, 410, "" }
        code, err = T:poll(s)
        assert.is_nil(code) assert.are.equal("expired", err)
        assert.is_nil(s.secret)
    end)
end)
