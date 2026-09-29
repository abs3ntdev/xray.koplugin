-- xray_lookupmanager_spec.lua
require("spec/spec_helper")

describe("xray_lookupmanager", function()
    local LookupManager
    local lm
    local plugin

    setup(function()
        LookupManager = require("xray_lookupmanager")
        plugin = createMockPlugin()
        plugin.characters = {}
        plugin.historical_figures = {}
        plugin.locations = {}
        lm = LookupManager:new(plugin)
    end)

    describe("normalize", function()
        it("should lowercase and strip non-alphanumeric at ends", function()
            assert.are.equal("hello", lm:normalize("...Hello!"))
            assert.are.equal("john's", lm:normalize("John's"))
            assert.are.equal("watson", lm:normalize("Watson,"))
        end)

        it("should normalize Cyrillic Russian text with and without punctuation", function()
            assert.are.equal("раскольников", lm:normalize("Раскольников"))
            assert.are.equal("раскольников", lm:normalize("«Раскольников»"))
            assert.are.equal("раскольников", lm:normalize("“Раскольников”"))
            assert.are.equal("раскольников", lm:normalize("...Раскольников!"))
            assert.are.equal("родион раскольников", lm:normalize("Родион Раскольников"))
            assert.are.equal("война и мир", lm:normalize("«Война и мир»"))
        end)

        it("should normalize CJK and Latin-extended text", function()
            assert.are.equal("阿q", lm:normalize("「阿Q」"))
            assert.are.equal("红楼梦", lm:normalize("《红楼梦》"))
            assert.are.equal("émile zola", lm:normalize("“Émile Zola”"))
            assert.are.equal("łódź", lm:normalize("Łódź,"))
        end)
    end)

    describe("lookupAll", function()
        before_each(function()
            plugin.characters = {
                { name = "Sherlock Holmes", _norm_name = "sherlock holmes", aliases = {"Sherlock"}, _norm_aliases = {"sherlock"} },
                { name = "John Watson", _norm_name = "john watson" }
            }
            plugin.locations = {
                { name = "221B Baker Street", _norm_name = "221b baker street" }
            }
        end)

        it("should find exact match", function()
            local results = lm:lookupAll("John Watson")
            assert.are.equal(1, #results)
            assert.are.equal("John Watson", results[1].item.name)
            assert.are.equal(100, results[1].score)
        end)

        it("should find exact alias match", function()
            local results = lm:lookupAll("Sherlock")
            assert.are.equal(1, #results)
            assert.are.equal("Sherlock Holmes", results[1].item.name)
            assert.are.equal(95, results[1].score)
        end)

        it("should find contains match", function()
            local results = lm:lookupAll("Holmes")
            assert.are.equal(1, #results)
            assert.are.equal("Sherlock Holmes", results[1].item.name)
            assert.are.equal(50, results[1].score)
        end)

        it("should find contained match", function()
            local results = lm:lookupAll("John Watson and someone else")
            assert.are.equal(1, #results)
            assert.are.equal("John Watson", results[1].item.name)
            assert.are.equal(50, results[1].score)
        end)

        it("should prioritize better matches", function()
            -- Add a character whose alias is a substring of another
            table.insert(plugin.characters, { name = "Holmes Senior", _norm_name = "holmes senior" })
            
            local results = lm:lookupAll("Sherlock Holmes")
            -- "Sherlock Holmes" matches exactly.
            -- "Holmes Senior" might match partially (query contains "holmes").
            assert.are.equal(100, results[1].score)
            assert.are.equal("Sherlock Holmes", results[1].item.name)
        end)

        it("should filter out partial matches when an exact match is present", function()
            -- Add "Coherence" which is a substring/partial match
            plugin.terms = {
                { name = "associative coherence", _norm_name = "associative coherence" },
                { name = "Coherence", _norm_name = "coherence" }
            }
            local results = lm:lookupAll("associative coherence")
            -- Should only return "associative coherence" (score 100), not "Coherence" (score 30)
            assert.are.equal(1, #results)
            assert.are.equal("associative coherence", results[1].item.name)
            assert.are.equal(100, results[1].score)
        end)

        it("should correctly lookup Cyrillic characters, aliases, and inflected forms (Issue #116)", function()
            plugin.characters = {
                { name = "Родион Раскольников", aliases = {"Раскольников", "Родя"} },
                { name = "Софья Семёновна Мармеладова", aliases = {"Соня", "Сонечка"} }
            }
            plugin.historical_figures = {
                { name = "Наполеон I Бонапарт", aliases = {"Наполеон"} }
            }
            plugin.locations = {
                { name = "Санкт-Петербург", aliases = {"Петербург", "Питер"} }
            }
            plugin.terms = {
                { name = "Жёлтый билет" }
            }

            -- Exact match on full Cyrillic name
            local r1 = lm:lookupAll("Родион Раскольников")
            assert.are.equal(1, #r1)
            assert.are.equal("Родион Раскольников", r1[1].item.name)
            assert.are.equal(100, r1[1].score)

            -- Exact match on Cyrillic alias
            local r2 = lm:lookupAll("Раскольников")
            assert.are.equal(1, #r2)
            assert.are.equal("Родион Раскольников", r2[1].item.name)
            assert.are.equal(95, r2[1].score)

            -- Cyrillic alias with Russian guillemets «...»
            local r3 = lm:lookupAll("«Раскольников»")
            assert.are.equal(1, #r3)
            assert.are.equal("Родион Раскольников", r3[1].item.name)
            assert.are.equal(95, r3[1].score)

            -- Short nickname alias
            local r4 = lm:lookupAll("Родя")
            assert.are.equal(1, #r4)
            assert.are.equal("Родион Раскольников", r4[1].item.name)
            assert.are.equal(95, r4[1].score)

            -- Inflected Russian form in text matching base alias
            local r5 = lm:lookupAll("Раскольникова")
            assert.are.equal(1, #r5)
            assert.are.equal("Родион Раскольников", r5[1].item.name)
            assert.are.equal(40, r5[1].score)

            -- Historical figure in Russian
            local r6 = lm:lookupAll("Наполеон")
            assert.are.equal(1, #r6)
            assert.are.equal("Наполеон I Бонапарт", r6[1].item.name)
            assert.are.equal(95, r6[1].score)

            -- Location in Russian
            local r7 = lm:lookupAll("Питер")
            assert.are.equal(1, #r7)
            assert.are.equal("Санкт-Петербург", r7[1].item.name)
            assert.are.equal(95, r7[1].score)

            -- Term in Russian with 'ё'
            local r8 = lm:lookupAll("жёлтый билет")
            assert.are.equal(1, #r8)
            assert.are.equal("Жёлтый билет", r8[1].item.name)
            assert.are.equal(100, r8[1].score)
        end)
    end)

    describe("handleLookup table text payloads", function()
        before_each(function()
            plugin.characters = {
                { name = "Sherlock Holmes", aliases = {"Sherlock"} },
                { name = "John Watson" }
            }
        end)

        it("unwraps table text payloads and looks up correctly", function()
            local shown = false
            plugin.showCharacterDetails = function() shown = true end
            lm:handleLookup({ text = "John Watson" }, 1, 2)
            assert.is_true(shown)
        end)

        it("unwraps Cyrillic table text payload and shows character details", function()
            plugin.characters = {
                { name = "Родион Раскольников", aliases = {"Раскольников"} }
            }
            local shown_item = nil
            plugin.showCharacterDetails = function(self, item) shown_item = item end
            lm:handleLookup({ text = "Раскольников" }, 1, 2)
            assert.is_not_nil(shown_item)
            assert.are.equal("Родион Раскольников", shown_item.name)
        end)
    end)

    describe("showResult normalization", function()
        local called
        before_each(function()
            called = {}
            plugin.showCharacterDetails = function(self, item, opts) called.character = { item = item, opts = opts } end
            plugin.showHistoricalFigureDetails = function(self, item, opts) called.historical = { item = item, opts = opts } end
            plugin.showLocationDetails = function(self, item, opts) called.location = { item = item, opts = opts } end
            plugin.showTermDetails = function(self, item, opts) called.term = { item = item, opts = opts } end
        end)

        it("dispatches correctly for capitalized and whitespace-formatted item types", function()
            local item = { name = "Test Entity" }

            lm:showResult(item, "Character")
            assert.is_not_nil(called.character)
            assert.are.equal(item, called.character.item)
            assert.are.equal("in_text", called.character.opts.source)

            lm:showResult(item, "Historical Figure")
            assert.is_not_nil(called.historical)
            assert.are.equal(item, called.historical.item)

            lm:showResult(item, "historical")
            assert.is_not_nil(called.historical)

            lm:showResult(item, "LOCATION")
            assert.is_not_nil(called.location)

            lm:showResult(item, "Term")
            assert.is_not_nil(called.term)
        end)
    end)

    describe("word boundary and false positive prevention (Issue #140)", function()
        before_each(function()
            plugin.characters = {
                { name = "Eo of Lykos", aliases = {"Eo"} },
                { name = "Son", aliases = {} },
                { name = "Io", aliases = {} },
                { name = "Callisto", aliases = {} },
                { name = "Rim", aliases = {} },
                { name = "Red", aliases = {} },
                { name = "Cat", aliases = {} },
                { name = "Ян", aliases = {} },
                { name = "Родион Раскольников", aliases = {"Раскольников"} },
                { name = "Sherlock Holmes", aliases = {"Watson's friend"} },
                { name = "Watson", aliases = {} },
            }
            plugin.terms = {
                { name = "罗辑" },
                { name = "هارون" }
            }
        end)

        it("does not match names hidden inside other words", function()
            -- "Matteo" contains "Eo"
            assert.are.equal(0, #lm:lookupAll("Matteo"))
            -- "person" and "Jefferson" contain "Son"
            assert.are.equal(0, #lm:lookupAll("person"))
            assert.are.equal(0, #lm:lookupAll("Jefferson"))
            -- "Additionally" contains "Io"
            assert.are.equal(0, #lm:lookupAll("Additionally"))
            -- "All" contained inside "Callisto"
            assert.are.equal(0, #lm:lookupAll("All"))
            -- "Crime" contains "Rim"
            assert.are.equal(0, #lm:lookupAll("Crime"))
        end)

        it("requires names shorter than 3 characters to match a whole word", function()
            assert.are.equal(0, #lm:lookupAll("eon"))
            assert.are.equal(0, #lm:lookupAll("ion"))
            assert.are.equal(0, #lm:lookupAll("январь"))
            assert.are.equal(0, #lm:lookupAll("баян"))

            -- Matches whole words
            local r_eo = lm:lookupAll("Eo")
            assert.are.equal(1, #r_eo)
            assert.are.equal("Eo of Lykos", r_eo[1].item.name)

            local r_eo_phrase = lm:lookupAll("Eo was a martyr")
            assert.are.equal(1, #r_eo_phrase)
            assert.are.equal("Eo of Lykos", r_eo_phrase[1].item.name)

            local r_yan = lm:lookupAll("Ян пошёл")
            assert.are.equal(1, #r_yan)
            assert.are.equal("Ян", r_yan[1].item.name)
        end)

        it("matches inflected words up to 3 run-on characters", function()
            local r_reds = lm:lookupAll("Reds")
            assert.are.equal(1, #r_reds)
            assert.are.equal("Red", r_reds[1].item.name)

            local r_rus1 = lm:lookupAll("Раскольникова")
            assert.are.equal(1, #r_rus1)
            assert.are.equal("Родион Раскольников", r_rus1[1].item.name)

            local r_rus2 = lm:lookupAll("Раскольниковым")
            assert.are.equal(1, #r_rus2)
            assert.are.equal("Родион Раскольников", r_rus2[1].item.name)
        end)

        it("rejects run-ons longer than 3 characters", function()
            assert.are.equal(0, #lm:lookupAll("redistribution"))
            assert.are.equal(0, #lm:lookupAll("category"))
        end)

        it("recognizes punctuation and quotes as word breaks", function()
            local r_watson = lm:lookupAll("Watson's journal")
            assert.are.equal(1, #r_watson)
            assert.are.equal("Watson", r_watson[1].item.name)
        end)

        it("preserves substring lookup for CJK and Arabic scripts", function()
            local r_cjk = lm:lookupAll("罗辑在冥王星")
            assert.are.equal(1, #r_cjk)
            assert.are.equal("罗辑", r_cjk[1].item.name)

            local r_ar = lm:lookupAll("وهارون")
            assert.are.equal(1, #r_ar)
            assert.are.equal("هارون", r_ar[1].item.name)
        end)
    end)

    describe("stale _norm_aliases and _norm_name recovery (Issue #140)", function()
        it("detects and rebuilds stale _norm_aliases loaded from cache", function()
            plugin.characters = {
                {
                    name = "LowRed",
                    aliases = { "Red", "Reds", "Helldivers", "LowColors" },
                    _norm_aliases = { "red", "reds" } -- stale on disk
                }
            }

            local results = lm:lookupAll("Helldivers")
            assert.are.equal(1, #results)
            assert.are.equal("LowRed", results[1].item.name)
            assert.are.equal(95, results[1].score)
        end)

        it("detects and refreshes updated entity name", function()
            local item = { name = "Initial Name", _norm_name = "initial name", _norm_name_src = "Initial Name" }
            plugin.characters = { item }

            local r1 = lm:lookupAll("Initial Name")
            assert.are.equal(1, #r1)

            -- Rename entity
            item.name = "Updated Character"
            local r2 = lm:lookupAll("Updated Character")
            assert.are.equal(1, #r2)
            assert.are.equal("Updated Character", r2[1].item.name)
            assert.are.equal(100, r2[1].score)
        end)
    end)
end)
