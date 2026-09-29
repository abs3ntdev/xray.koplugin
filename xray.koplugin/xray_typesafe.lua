-- xray_typesafe.lua
-- Optional, opt-in TypeSafe Jev decision helper (NOT a generative provider).
--
-- Contract source: https://docs.typesafe.ai/api.md and /models.md (read
-- 2026-09-29). POST https://api.typesafe.ai/v1/systemone with Bearer auth,
-- body { state, model, questions }, answers keyed by question id.
--
-- Pure module: builds requests, validates typed answers and applies
-- conservative decision policy. No network I/O, no credential storage, and
-- error strings never contain keys or response bodies. A typed answer is not
-- proof of correctness: every uncertain, malformed or low-confidence result
-- maps to "no decision" so callers keep their existing behavior.

local ok_json, json = pcall(require, "json")
if not ok_json then ok_json, json = pcall(require, "rapidjson") end

local TS = {}

TS.PROVIDER_ID = "typesafe"
TS.ENDPOINT = "https://api.typesafe.ai/v1/systemone"
-- Pinned versioned model (models.md). Aliases like jev-latest can move and
-- change answers without notice.
TS.MODEL = "jev-1.13.0"
TS.TIMEOUT = 20
TS.MAX_REQUEST_BYTES = 48 * 1024
TS.MAX_RESPONSE_BYTES = 256 * 1024
TS.MAX_QUESTIONS = 16
TS.PAIRS_PER_REQUEST = 12
TS.MAX_PAIR_REQUESTS = 3

-- Book type labels already consumed by X-Ray (prompts book_type_detect).
TS.BOOK_TYPES = {
    prose_fiction = "Prose fiction: novels, novellas or short stories.",
    prose_nonfiction = "Prose non-fiction: history, biography, science, essays, self-help.",
    manga = "Manga.",
    graphic_novel = "Graphic novels or comics (non-manga).",
    children = "Children's picture or early-reader books.",
    poetry = "Poetry or verse collections.",
    cookbook = "Cookbooks or recipe collections.",
    textbook = "Textbooks, academic course material or technical manuals.",
    travel = "Travel guides.",
}
-- Conservative heuristic thresholds. NOT calibrated or validated for book
-- metadata or literary entity matching. The API guarantees answer types, not
-- accuracy; anything below these falls back to existing behavior.
TS.BOOK_TYPE_MIN_PROBABILITY = 0.8
TS.BOOK_TYPE_MIN_CONFIDENCE = 0.7
TS.PAIR_MIN_CONFIDENCE = 0.6

local messages = {
    error_auth = "TypeSafe rejected the API key.",
    error_rate_limit = "TypeSafe is busy or rate limited. Try again later.",
    error_invalid = "TypeSafe rejected the request.",
    error_api = "TypeSafe request failed.",
    error_parse = "TypeSafe returned an unexpected response.",
    error_config = "TypeSafe is not configured.",
    error_size = "TypeSafe request is too large.",
}
local function failure(code)
    return nil, code, messages[code] or messages.error_api
end
TS.message = function(code) return messages[code] or messages.error_api end

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
local function unit(n) return finite(n) and n >= 0 and n <= 1 end

local function clip(s, n)
    if type(s) ~= "string" then return nil end
    s = s:gsub("%c", " ")
    if #s > n then
        s = s:sub(1, n)
        -- Do not leave a truncated UTF-8 sequence.
        s = s:gsub("[\192-\255][\128-\191]*$", "")
    end
    return s
end

-- A plausible API key: printable, no whitespace, bounded. The format is not
-- documented, so this only rejects obviously broken input.
function TS.validKey(key)
    return type(key) == "string" and #key >= 8 and #key <= 512 and not key:find("[%s%c]")
        and not key:find("[\128-\255]")
end

function TS.isPinnedRequest(req)
    return type(req) == "table" and req.url == TS.ENDPOINT and req.provider == TS.PROVIDER_ID
end

-- Build a SecureHTTP-ready request. spec = { kind, questions = {id -> def} }.
function TS.buildRequest(api_key, state, spec)
    if not ok_json then return failure("error_config") end
    if not TS.validKey(api_key) then return failure("error_config") end
    if type(spec) ~= "table" or type(spec.questions) ~= "table" then return failure("error_invalid") end
    local count = 0
    for id in pairs(spec.questions) do
        if type(id) ~= "string" or not id:match("^[%w_]+$") then return failure("error_invalid") end
        count = count + 1
    end
    if count == 0 or count > TS.MAX_QUESTIONS then return failure("error_invalid") end
    local ok, body = pcall(json.encode, { state = state, model = TS.MODEL, questions = spec.questions })
    if not ok or type(body) ~= "string" then return failure("error_invalid") end
    if #body > TS.MAX_REQUEST_BYTES then return failure("error_size") end
    return {
        provider = TS.PROVIDER_ID, secure = true, url = TS.ENDPOINT, method = "POST",
        model = TS.MODEL, typesafe_spec = spec,
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["Authorization"] = "Bearer " .. api_key,
        },
        body = body,
    }
end

local function classifyStatus(status)
    if status == 401 or status == 403 then return "error_auth" end
    if status == 429 or status == 529 or status == 503 then return "error_rate_limit" end
    if status == 400 or status == 422 then return "error_invalid" end
    return "error_api"
end

local function validChoice(ans, def)
    if type(ans.choice) ~= "string" or def.criteria[ans.choice] == nil then return false end
    if not unit(ans.confidence) or type(ans.probabilities) ~= "table" then return false end
    local sum, n = 0, 0
    for k, p in pairs(ans.probabilities) do
        if def.criteria[k] == nil or not unit(p) then return false end
        sum, n = sum + p, n + 1
    end
    for k in pairs(def.criteria) do if ans.probabilities[k] == nil then return false end end
    if math.abs(sum - 1) > 0.02 then return false end
    -- `choice` is documented as the highest-probability option.
    local chosen = ans.probabilities[ans.choice]
    for _, p in pairs(ans.probabilities) do if p > chosen + 1e-6 then return false end end
    return n > 0
end

local function validScore(ans, def)
    local levels = #def.criteria
    if not finite(ans.score) or ans.score < 0 or ans.score > levels - 1 then return false end
    if not unit(ans.confidence) or type(ans.probabilities) ~= "table" then return false end
    if type(ans.legend) ~= "table" then return false end
    local sum, expected = 0, 0
    for k, p in pairs(ans.probabilities) do
        local i = type(k) == "string" and k:match("^%d+$") and tonumber(k)
        if not i or i >= levels or not unit(p) then return false end
        sum, expected = sum + p, expected + i * p
    end
    for i = 0, levels - 1 do
        if ans.probabilities[tostring(i)] == nil then return false end
        if type(ans.legend[tostring(i)]) ~= "string" then return false end
    end
    for k in pairs(ans.legend) do
        local i = type(k) == "string" and k:match("^%d+$") and tonumber(k)
        if not i or i >= levels then return false end
    end
    if math.abs(sum - 1) > 0.02 then return false end
    -- Score is documented as the probability-weighted value.
    if math.abs(expected - ans.score) > 0.05 then return false end
    return true
end

local function validNoul(ans) return unit(ans.noul) end

-- Validate an HTTP result against the request's question spec.
-- Returns answers table (id -> answer) or nil, safe_code, safe_message.
function TS.parseResponse(status, body, spec)
    if not ok_json then return failure("error_config") end
    status = tonumber(status)
    if status ~= 200 then return failure(classifyStatus(status)) end
    if type(body) ~= "string" or #body == 0 or #body > TS.MAX_RESPONSE_BYTES then return failure("error_parse") end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" or type(data.answers) ~= "table" then return failure("error_parse") end
    -- Pinned request: the answering model must be the pinned version.
    if data.model ~= TS.MODEL then return failure("error_parse") end
    local out = {}
    for id, def in pairs(spec.questions) do
        local ans = data.answers[id]
        if type(ans) ~= "table" or ans.type ~= def.type then return failure("error_parse") end
        local valid = (def.type == "choice" and validChoice(ans, def))
            or (def.type == "score" and validScore(ans, def))
            or (def.type == "noul" and validNoul(ans))
        if not valid then return failure("error_parse") end
        out[id] = ans
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Book type classification
-- ---------------------------------------------------------------------------
function TS.bookTypeSpec()
    local criteria = {}
    for k, v in pairs(TS.BOOK_TYPES) do criteria[k] = v end
    criteria.uncertain = "The metadata does not clearly indicate one of the other book types."
    return {
        kind = "book_type",
        questions = {
            book_type = {
                type = "choice",
                instructions = "Based only on this book's metadata (`title`, `author`, `series`, `description`), which type of book is it? Metadata can be sparse or misleading; pick uncertain when the type is not clear.",
                criteria = criteria,
            },
        },
    }
end

function TS.bookTypeState(title, author, series, description)
    return {
        title = clip(title, 300) or "Unknown",
        author = clip(author, 300) or "Unknown",
        series = clip(series, 300) or "None",
        description = clip(description, 2000) or "None",
    }
end

-- Returns { book_type_label, typesafe = {...} } or nil when not confident.
function TS.decideBookType(answers)
    local a = type(answers) == "table" and answers.book_type
    if type(a) ~= "table" then return nil end
    local label = a.choice
    if not TS.BOOK_TYPES[label] then return nil end
    local p = a.probabilities[label]
    if not unit(p) or p < TS.BOOK_TYPE_MIN_PROBABILITY then return nil end
    if not unit(a.confidence) or a.confidence < TS.BOOK_TYPE_MIN_CONFIDENCE then return nil end
    return { book_type_label = label, typesafe = { probability = p, confidence = a.confidence, model = TS.MODEL } }
end

-- ---------------------------------------------------------------------------
-- Duplicate pair review (annotates existing candidates only)
-- ---------------------------------------------------------------------------
TS.PAIR_LEVELS = {
    "They are two different characters, places or things in this book.",
    "They may or may not be the same: related, similar names, or not enough information to tell.",
    "They are the same character, place or thing referred to by different names or entries.",
}

local function entityState(e)
    local aliases = {}
    if type(e.aliases) == "table" then
        for _, a in ipairs(e.aliases) do
            if #aliases >= 10 then break end
            if type(a) == "string" and a ~= "" then aliases[#aliases + 1] = clip(a, 80) end
        end
    end
    return {
        name = clip(e.name, 120) or "?",
        aliases = aliases,
        description = clip(e.description or e.biography or "", 400),
    }
end

-- Build batched request specs for candidate pairs. items: array of
-- { primary_item, secondary_item }. Returns array of { state, spec, indexes }.
function TS.pairBatches(book, items)
    local batches = {}
    local per, max_total = TS.PAIRS_PER_REQUEST, TS.PAIRS_PER_REQUEST * TS.MAX_PAIR_REQUESTS
    for start = 1, math.min(#items, max_total), per do
        local state = {
            book = { title = clip(book and book.title, 300) or "Unknown", author = clip(book and book.author, 300) or "Unknown",
                entity_type = clip(book and book.entity_type, 40) or "entities" },
            pairs = {},
        }
        local spec = { kind = "duplicates", questions = {} }
        local indexes = {}
        for i = start, math.min(start + per - 1, #items, max_total) do
            local slot = #state.pairs
            state.pairs[slot + 1] = { entity_a = entityState(items[i][1]), entity_b = entityState(items[i][2]) }
            spec.questions["p" .. i] = {
                type = "score",
                instructions = string.format(
                    "In the book described by `book`, do `pairs[%d].entity_a` and `pairs[%d].entity_b` refer to the same %s? Similar or equal names alone do not prove identity. Use only the supplied names, aliases and descriptions; do not rely on plot knowledge beyond them.",
                    slot, slot, state.book.entity_type),
                criteria = TS.PAIR_LEVELS,
            }
            indexes[#indexes + 1] = i
        end
        batches[#batches + 1] = { state = state, spec = spec, indexes = indexes }
    end
    return batches
end

-- Map a validated score answer to a displayed verdict.
function TS.pairVerdict(ans)
    if type(ans) ~= "table" or not finite(ans.score) or not unit(ans.confidence) then return "not_assessed" end
    if ans.confidence < TS.PAIR_MIN_CONFIDENCE then return "uncertain" end
    local level = math.floor(ans.score + 0.5)
    if level == 2 then return "same" elseif level == 0 then return "different" end
    return "uncertain"
end

return TS
