-- xray_typesafe_spec.lua
-- Optional TypeSafe Jev decision helper. Public AIHelper entrypoints
-- (detectBookTypeAsync, annotateDuplicatePairsAsync) -> real child chain
-- (_runChildRequests) -> checkAsyncResult. Mocked boundary: SecureHTTP
-- (fake transport, no network) and makeRequestAsync (captures the chain
-- instead of forking). No real keys, settings files or live model calls.
require("spec/spec_helper")

describe("TypeSafe Jev decision helper", function()
    local AIHelper, TS, json
    local saved, secure, captured, oauth
    local KEY = "ts_test_key_SECRET123"

    local function fakeSecure(responses)
        local s = { calls = {} }
        function s:request(url, method, headers, body, timeout)
            table.insert(self.calls, { url = url, headers = headers, body = body, timeout = timeout })
            local r = table.remove(responses, 1) or { 500, "" }
            if r[1] == nil then return nil, "network_error", "The secure connection failed.", {} end
            return 1, r[1], r[2], {}
        end
        return s
    end

    local function choiceAnswer(choice, probs, confidence)
        return { type = "choice", choice = choice, probabilities = probs, confidence = confidence }
    end

    local function bookTypeBody(choice, p, confidence, model)
        local probs = {}
        for k in pairs(TS.BOOK_TYPES) do probs[k] = 0 end
        probs.uncertain = 0
        probs[choice] = p
        -- Spread the remainder over "uncertain" (or prose_fiction if chosen).
        local rest = choice == "uncertain" and "prose_fiction" or "uncertain"
        probs[rest] = 1 - p
        return json.encode({ model = model or TS.MODEL, answers = { book_type = choiceAnswer(choice, probs, confidence) },
            usage = { input_tokens = 300, output_tokens = 10 } })
    end

    local function scoreAnswer(probs, confidence)
        local score = 0
        for i, p in ipairs(probs) do score = score + (i - 1) * p end
        return { type = "score", score = score, confidence = confidence,
            legend = { ["0"] = "a", ["1"] = "b", ["2"] = "c" },
            probabilities = { ["0"] = probs[1], ["1"] = probs[2], ["2"] = probs[3] } }
    end

    local function okStream(text)
        return "data: " .. json.encode({ type = "response.output_text.delta", delta = text }) .. "\n\n"
            .. "data: " .. json.encode({ type = "response.completed", response = { status = "completed" } }) .. "\n\n"
    end

    local function runChain(responses)
        secure = fakeSecure(responses)
        AIHelper._secure_http = secure
        local tmp = os.tmpname()
        local ok, err = pcall(AIHelper._runChildRequests, AIHelper, captured, tmp)
        assert(ok, err)
        return tmp
    end

    setup(function()
        json = require("json")
        AIHelper = require("xray_aihelper")
        TS = require("xray_typesafe")
    end)

    before_each(function()
        saved = { settings = AIHelper.settings, makeRequestAsync = AIHelper.makeRequestAsync,
            saveSettings = AIHelper.saveSettings, routes = AIHelper._async_routes }
        captured = nil
        oauth = {
            getStatus = function() return { connected = true } end,
            getAccessContext = function() return { access_token = "oat_SECRET", account_id = "acct" } end,
        }
        AIHelper._openai_auth = oauth
        AIHelper._openai_responses = nil
        AIHelper.settings = {
            primary_ai = { provider = "openai_account", model = "gpt-6-luna" },
            secondary_ai = { provider = "openai_account", model = "gpt-6-luna" },
            typesafe_api_key = KEY,
            typesafe_enabled = true,
        }
        AIHelper.saveSettings = function(self, updates)
            for k, v in pairs(updates or {}) do self.settings[k] = v end
        end
        AIHelper.makeRequestAsync = function(self, reqs) captured = reqs.url and { reqs } or reqs; return 4242 end
        saved.prompts = AIHelper.prompts
        AIHelper.prompts = { book_type_detect = "%s %s %s %s" }
    end)

    after_each(function()
        AIHelper.settings = saved.settings
        AIHelper.prompts = saved.prompts
        AIHelper.makeRequestAsync = saved.makeRequestAsync
        AIHelper.saveSettings = saved.saveSettings
        AIHelper._async_routes = saved.routes
        AIHelper._secure_http = nil
        AIHelper._openai_auth = nil
    end)

    describe("opt-in gating", function()
        it("a saved key alone never enables TypeSafe or counts as a generative key", function()
            AIHelper.settings.typesafe_enabled = nil
            assert.is_false(AIHelper:isTypeSafeEnabled())
            AIHelper:detectBookTypeAsync("T", "A", "S", "D", "/tmp/x")
            for _, r in ipairs(captured) do assert.are_not.equal("typesafe", r.provider) end
            assert.is_nil(AIHelper:annotateDuplicatePairsAsync({}, { { { name = "a" }, { name = "b" } } }, "/tmp/y"))
        end)

        it("setTypeSafeKey stores the key without toggling opt-in; clear disables", function()
            AIHelper.settings.typesafe_enabled = nil
            AIHelper.settings.typesafe_api_key = nil
            assert.is_false((AIHelper:setTypeSafeKey("bad key with spaces")))
            assert.is_true(AIHelper:setTypeSafeKey("  " .. KEY .. "  "))
            assert.are.equal(KEY, AIHelper.settings.typesafe_api_key)
            assert.is_nil(AIHelper.settings.typesafe_enabled)
            AIHelper:setTypeSafeEnabled(true)
            assert.is_true(AIHelper:isTypeSafeEnabled())
            AIHelper:clearTypeSafeKey()
            assert.is_false(AIHelper:isTypeSafeEnabled())
            assert.is_false(AIHelper.settings.typesafe_enabled)
        end)
    end)

    describe("book type via detectBookTypeAsync", function()
        it("sends a pinned request first and returns a confident decision without calling the generative route", function()
            AIHelper:detectBookTypeAsync("Dune", "Frank Herbert", "Dune", "Science fiction novel", "/tmp/x")
            assert.are.equal("typesafe", captured[1].provider)
            assert.are.equal("openai_account", captured[2].provider)
            local tmp = runChain({ { 200, bookTypeBody("prose_fiction", 0.93, 0.9) } })
            assert.are.equal(1, #secure.calls)
            local call = secure.calls[1]
            assert.are.equal("https://api.typesafe.ai/v1/systemone", call.url)
            assert.are.equal("Bearer " .. KEY, call.headers.Authorization)
            assert.is_true(call.timeout <= 20)
            local body = json.decode(call.body)
            assert.are.equal("jev-1.13.0", body.model)
            assert.are.equal("choice", body.questions.book_type.type)
            assert.is_not_nil(body.questions.book_type.criteria.uncertain)
            local res = AIHelper:checkAsyncResult(tmp)
            assert.are.equal("prose_fiction", res.book_type_label)
        end)

        local fallbacks = {
            { "uncertain choice", { 200, bookTypeBody("uncertain", 0.9, 0.9) } },
            { "low probability", { 200, bookTypeBody("manga", 0.6, 0.9) } },
            { "low confidence", { 200, bookTypeBody("manga", 0.85, 0.4) } },
            { "unpinned model", { 200, bookTypeBody("manga", 0.95, 0.95, "jev-9.9.9") } },
            { "HTTP 401", { 401, '{"detail":"bad key ts_test_key_SECRET123"}' } },
            { "HTTP 429", { 429, "" } },
            { "network failure", { nil } },
            { "non-JSON body", { 200, "<html>" } },
            { "missing answer", { 200, json.encode({ model = TS.MODEL, answers = {} }) } },
            { "choice outside options", { 200, json.encode({ model = TS.MODEL, answers = { book_type =
                choiceAnswer("novel", { novel = 1 }, 1) } }) } },
            { "probabilities not summing to one", { 200, (function()
                local b = json.decode(bookTypeBody("manga", 0.95, 0.9)); b.answers.book_type.probabilities.uncertain = 0.5
                return json.encode(b) end)() } },
            { "choice not the argmax", { 200, (function()
                local b = json.decode(bookTypeBody("manga", 0.3, 0.9)); b.answers.book_type.probabilities.uncertain = 0.7
                return json.encode(b) end)() } },
        }
        for _, case in ipairs(fallbacks) do
            it("falls through to the existing generative route on " .. case[1], function()
                AIHelper:detectBookTypeAsync("T", "A", "S", "D", "/tmp/x")
                local tmp = runChain({ case[2], { 200, okStream('{"book_type_label":"poetry"}') } })
                assert.are.equal(2, #secure.calls)
                assert.are.equal("https://chatgpt.com/backend-api/codex/responses", secure.calls[2].url)
                local res = AIHelper:checkAsyncResult(tmp)
                assert.are.equal("poetry", res.book_type_label)
            end)
        end

        it("a TypeSafe-only chain that is not confident reports a safe error without leaking the key", function()
            captured = { assert(TS.buildRequest(KEY, TS.bookTypeState("T"), TS.bookTypeSpec())) }
            local tmp = runChain({ { 401, "echo ts_test_key_SECRET123" } })
            local data, code, msg = AIHelper:checkAsyncResult(tmp)
            assert.is_false(data)
            assert.are.equal("error_auth", code)
            assert.is_nil(msg:find("SECRET", 1, true))
        end)
    end)

    describe("duplicate annotation via annotateDuplicatePairsAsync", function()
        local function items(n)
            local out = {}
            for i = 1, n do
                out[i] = { { name = "A" .. i, aliases = { "x" }, description = "d" }, { name = "B" .. i, description = "e" } }
            end
            return out
        end
        local function batchBody(req, probs, confidence)
            local answers = {}
            for id in pairs(json.decode(req.body).questions) do answers[id] = scoreAnswer(probs, confidence) end
            return json.encode({ model = TS.MODEL, answers = answers })
        end

        it("batches every candidate up to the cap and marks the rest not assessed", function()
            local pid, sent = AIHelper:annotateDuplicatePairsAsync({ title = "T", entity_type = "characters" }, items(40), "/tmp/y")
            assert.are.equal(4242, pid)
            assert.are.equal(36, sent)
            assert.are.equal(3, #captured)
            local responses = {}
            for i, req in ipairs(captured) do
                local probs = i == 1 and { 0, 0.05, 0.95 } or (i == 2 and { 0.9, 0.1, 0 } or { 0.2, 0.6, 0.2 })
                responses[i] = { 200, batchBody(req, probs, 0.8) }
            end
            local tmp = runChain(responses)
            assert.are.equal(3, #secure.calls)
            local res = AIHelper:checkAsyncResult(tmp)
            assert.are.equal(36, res.assessed)
            assert.are.equal("same", res.typesafe_annotations["1"].verdict)
            assert.are.equal("different", res.typesafe_annotations["13"].verdict)
            assert.are.equal("uncertain", res.typesafe_annotations["25"].verdict)
            assert.is_nil(res.typesafe_annotations["37"])
            assert.is_nil(res.duplicate_pairs)
        end)

        it("a failed batch leaves its pairs unassessed while other batches still annotate", function()
            AIHelper:annotateDuplicatePairsAsync({}, items(14), "/tmp/y")
            local tmp = runChain({ { 500, "" }, { 200, batchBody(captured[2], { 0, 0, 1 }, 0.9) } })
            local res = AIHelper:checkAsyncResult(tmp)
            assert.is_nil(res.typesafe_annotations["1"])
            assert.are.equal("same", res.typesafe_annotations["13"].verdict)
        end)

        it("rejects score answers inconsistent with their probabilities", function()
            AIHelper:annotateDuplicatePairsAsync({}, items(1), "/tmp/y")
            local a = scoreAnswer({ 1, 0, 0 }, 0.9); a.score = 2
            local tmp = runChain({ { 200, json.encode({ model = TS.MODEL, answers = { p1 = a } }) } })
            local res = AIHelper:checkAsyncResult(tmp)
            assert.are.equal(0, res.assessed)
        end)

        it("low confidence is shown as uncertain, never as a match", function()
            assert.are.equal("uncertain", TS.pairVerdict(scoreAnswer({ 0, 0.3, 0.7 }, 0.3)))
        end)
    end)

    describe("request bounds", function()
        it("refuses oversized payloads and malformed keys before any transport", function()
            local big = string.rep("x", TS.MAX_REQUEST_BYTES)
            local r, code = TS.buildRequest(KEY, big, TS.bookTypeSpec())
            assert.is_nil(r); assert.are.equal("error_size", code)
            assert.is_nil((TS.buildRequest("k\n", "s", TS.bookTypeSpec())))
        end)

        it("clips entity context so a batch stays under the request limit", function()
            local huge = { { { name = string.rep("n", 5000), description = string.rep("d", 50000),
                aliases = { string.rep("a", 5000) } }, { name = "b" } } }
            for i = 2, 12 do huge[i] = huge[1] end
            local batch = TS.pairBatches({}, huge)[1]
            assert.is_table((TS.buildRequest(KEY, batch.state, batch.spec)))
        end)
    end)
end)
