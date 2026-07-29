--- Tests for the shared @-mention / /command matching logic (pi.completion).

describe("completion matcher", function()
    local Matcher = require("pi.completion")
    local FilesCache = require("pi.cache.files")
    local CommandsCache = require("pi.cache.commands")

    local orig_list = FilesCache.list
    local orig_commands_list = CommandsCache.list

    --- Install a fixed project file list for complete_files.
    ---@param files string[]
    local function with_files(files)
        FilesCache.list = function()
            return files
        end
    end

    --- Install a fixed command list for complete_commands.
    ---@param commands pi.SlashCommand[]
    local function with_commands(commands)
        CommandsCache.list = function()
            return commands
        end
    end

    --- Run complete_files and collect (path|dir, kind, is_fuzzy) tuples.
    ---@param prefix string
    ---@return table[] { [1]=path, [2]=kind, [3]=is_fuzzy }
    local function run_files(prefix)
        local out = {}
        Matcher.complete_files(prefix, function(path, kind, is_fuzzy)
            out[#out + 1] = { path, kind, is_fuzzy }
            return { path = path }
        end)
        return out
    end

    after_each(function()
        FilesCache.list = orig_list
        CommandsCache.list = orig_commands_list
    end)

    describe("fuzzy_match", function()
        it("matches subsequences in order", function()
            assert.True(Matcher.fuzzy_match("abc", "aXbXc"))
            assert.True(Matcher.fuzzy_match("abc", "abc"))
            assert.False(Matcher.fuzzy_match("abc", "acb"))
            assert.False(Matcher.fuzzy_match("abc", "ab"))
        end)

        it("is case-insensitive on both sides", function()
            assert.True(Matcher.fuzzy_match("ABC", "axbxc"))
            assert.True(Matcher.fuzzy_match("abc", "AXBXC"))
        end)
    end)

    describe("complete_files", function()
        it("empty prefix lists top-level dirs (collapsed) and files", function()
            with_files({ "lua/pi/init.lua", "lua/pi/config.lua", "README.md", "a/b/c.txt" })
            local got = run_files("")
            assert.same({
                { "lua/", "dir", false },
                { "README.md", "file", false },
                { "a/", "dir", false },
            }, got)
        end)

        it("prefix matches are case-sensitive; fuzzy pass still catches other cases", function()
            with_files({ "lua/pi/init.lua", "lua/pi/config.lua", "luax.txt", "LUA/upper.txt" })
            local got = run_files("lua")
            assert.same({
                { "lua/", "dir", false }, -- prefix (case-sensitive), collapsed
                { "luax.txt", "file", false }, -- prefix
                { "LUA/upper.txt", "file", true }, -- fuzzy, case-insensitive
            }, got)
        end)

        it("collapses directories relative to the typed prefix", function()
            with_files({ "lua/pi/init.lua", "lua/pi/config.lua", "lua/other/x.lua" })
            local got = run_files("lua/")
            assert.same({
                { "lua/pi/", "dir", false },
                { "lua/other/", "dir", false },
            }, got)
        end)

        it("fuzzy pass is case-insensitive, skips prefix matches, comes last", function()
            with_files({ "src/main2.lua", "main.lua", "docs/MAIN.md", "src/util.lua" })
            local got = run_files("main")
            assert.same({
                { "main.lua", "file", false }, -- prefix match first
                { "src/main2.lua", "file", true }, -- fuzzy, scan order
                { "docs/MAIN.md", "file", true }, -- fuzzy, case-insensitive
            }, got)
        end)

        it("fuzzy results are capped", function()
            local files = {}
            for i = 1, 250 do
                files[i] = string.format("dir%03d/needle_%03d.txt", i, i)
            end
            with_files(files)
            local got = run_files("needle")
            local fuzzy = 0
            for _, item in ipairs(got) do
                if item[3] then
                    fuzzy = fuzzy + 1
                end
            end
            assert.same(100, fuzzy)
            -- Capped results are still the earliest scan-order matches.
            assert.same({ "dir001/needle_001.txt", "file", true }, got[1])
            assert.same({ "dir100/needle_100.txt", "file", true }, got[100])
        end)

        it("lowered-path memo follows cache identity", function()
            -- Same table identity: second call reuses memoized lowercase
            -- paths (behavior identical).
            local files = { "Foo/BAR.txt" }
            with_files(files)
            assert.same({ { "Foo/BAR.txt", "file", true } }, run_files("bar"))
            assert.same({ { "Foo/BAR.txt", "file", true } }, run_files("bar"))
        end)
    end)

    describe("complete_commands", function()
        ---@type pi.SlashCommand[]
        local commands = {
            { name = "help", description = "show help", source = "prompt" },
            { name = "compact", description = "compact", source = "extension" },
            { name = "skill:deploy-helper", description = "deploy", source = "skill" },
        }

        --- Run complete_commands and collect (name, is_fuzzy) tuples.
        ---@param prefix string
        ---@return table[]
        local function run_commands(prefix)
            local out = {}
            Matcher.complete_commands(prefix, function(cmd, is_fuzzy)
                out[#out + 1] = { cmd.name, is_fuzzy }
                return { name = cmd.name }
            end)
            return out
        end

        it("empty prefix lists everything", function()
            with_commands(commands)
            assert.same({
                { "help", false },
                { "compact", false },
                { "skill:deploy-helper", false },
            }, run_commands(""))
        end)

        it("prefix matches on name and skill short name, case-insensitive", function()
            with_commands(commands)
            assert.same({ { "compact", false } }, run_commands("COM"))
            assert.same({ { "skill:deploy-helper", false } }, run_commands("dep"))
        end)

        it("fuzzy matches on full name", function()
            with_commands(commands)
            -- c(1)..m(4)..p(6) in "compact"; no other command contains a c.
            assert.same({ { "compact", true } }, run_commands("cmp"))
        end)

        it("prefix matches come before fuzzy matches", function()
            with_commands(commands)
            -- "he" prefixes "help" and fuzzes "skill:deploy-helper" (h..e).
            assert.same({
                { "help", false },
                { "skill:deploy-helper", true },
            }, run_commands("he"))
        end)
    end)
end)
