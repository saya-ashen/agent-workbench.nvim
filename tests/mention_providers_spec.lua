--- Tests for dynamic @-mention providers (pi.mention_providers) and their
--- expansion in pi.ui.chat.mentions.

describe("mention providers", function()
    local Providers = require("pi.mention_providers")
    local Config = require("pi.config")

    local orig_providers = Config.options.mention_providers

    after_each(function()
        Config.options.mention_providers = orig_providers
    end)

    describe("registry", function()
        it("lists the four built-ins in fixed order", function()
            local names = {}
            for _, provider in ipairs(Providers.list()) do
                names[#names + 1] = provider.name
            end
            assert.same({ "git-diff", "git-log", "lsp-errors", "quickfix" }, names)
        end)

        it("has() recognizes built-ins and rejects unknown names", function()
            assert.is_true(Providers.has("git-diff"))
            assert.is_true(Providers.has("quickfix"))
            assert.is_false(Providers.has("nope"))
        end)

        it("appends custom providers from config, sorted by name", function()
            Config.options.mention_providers = {
                zebra = function()
                    return "z"
                end,
                alpha = function()
                    return "a"
                end,
            }
            local names = {}
            for _, provider in ipairs(Providers.list()) do
                names[#names + 1] = provider.name
            end
            assert.same({ "git-diff", "git-log", "lsp-errors", "quickfix", "alpha", "zebra" }, names)
        end)

        it("normalizes spec-table entries with description and lang", function()
            Config.options.mention_providers = {
                todos = {
                    fn = function()
                        return "TODO: x"
                    end,
                    description = "open TODOs",
                    lang = "text",
                },
            }
            local provider = Providers.get("todos")
            assert.is_not_nil(provider)
            assert.same("open TODOs", provider.description)
            assert.same("text", provider.lang)
        end)

        it("ignores malformed config entries", function()
            Config.options.mention_providers = {
                bad = "not a function",
                worse = { description = "no fn" },
            }
            assert.is_nil(Providers.get("bad"))
            assert.is_nil(Providers.get("worse"))
        end)
    end)

    describe("materialize", function()
        it("returns trimmed provider output", function()
            Config.options.mention_providers = {
                padded = function()
                    return "  hello  "
                end,
            }
            assert.same("hello", Providers.materialize("padded"))
        end)

        it("returns nil for empty or nil output", function()
            Config.options.mention_providers = {
                empty = function()
                    return ""
                end,
                blank = function()
                    return "   "
                end,
                none = function()
                    return nil
                end,
            }
            assert.is_nil(Providers.materialize("empty"))
            assert.is_nil(Providers.materialize("blank"))
            assert.is_nil(Providers.materialize("none"))
        end)

        it("returns nil for unknown providers", function()
            assert.is_nil(Providers.materialize("nope"))
        end)

        it("catches provider errors and returns nil", function()
            Config.options.mention_providers = {
                boom = function()
                    error("kaboom")
                end,
            }
            assert.is_nil(Providers.materialize("boom"))
        end)

        it("truncates oversized output with a marker", function()
            Config.options.mention_providers = {
                huge = function()
                    return string.rep("x", 256 * 1024 + 99)
                end,
            }
            local content = Providers.materialize("huge")
            assert.is_not_nil(content)
            assert.is_true(content:find("… %(truncated%)$", 1, false) ~= nil)
            assert.is_true(#content < 256 * 1024 + 50)
        end)
    end)

    describe("quickfix provider", function()
        it("formats entries as path:lnum:col under the list title", function()
            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_name(buf, "/tmp/qf_target.txt")
            vim.fn.setqflist({}, " ", {
                title = "grep: needle",
                items = {
                    { bufnr = buf, lnum = 3, col = 5, text = "found needle" },
                    { bufnr = buf, lnum = 9, text = "another needle" },
                },
            })
            local content = Providers.materialize("quickfix")
            assert.is_not_nil(content)
            assert.is_true(content:find("grep: needle", 1, true) ~= nil)
            assert.is_true(content:find("qf_target.txt:3:5: found needle", 1, true) ~= nil)
            assert.is_true(content:find("qf_target.txt:9: another needle", 1, true) ~= nil)
            vim.fn.setqflist({}, "r", { title = "", items = {} })
        end)

        it("returns nil when the quickfix list is empty", function()
            vim.fn.setqflist({}, "r", { title = "", items = {} })
            assert.is_nil(Providers.materialize("quickfix"))
        end)
    end)

    describe("lsp-errors provider", function()
        it("formats ERROR diagnostics sorted by location", function()
            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_name(buf, "/tmp/diag_target.txt")
            local ns = vim.api.nvim_create_namespace("pi-test-diag")
            vim.diagnostic.set(ns, buf, {
                { lnum = 4, col = 2, message = "second", severity = vim.diagnostic.severity.ERROR },
                { lnum = 0, col = 0, message = "first", severity = vim.diagnostic.severity.ERROR, source = "lua_ls" },
                { lnum = 1, col = 0, message = "just a warning", severity = vim.diagnostic.severity.WARN },
            })
            local content = Providers.materialize("lsp-errors")
            assert.is_not_nil(content)
            assert.is_true(content:find("diag_target.txt:1:1: first [lua_ls]", 1, true) ~= nil)
            assert.is_true(content:find("diag_target.txt:5:3: second", 1, true) ~= nil)
            assert.is_nil(content:find("warning"))
            vim.diagnostic.reset(ns)
        end)

        it("returns nil when there are no errors", function()
            local ns = vim.api.nvim_create_namespace("pi-test-diag-none")
            vim.diagnostic.reset(ns)
            -- Other namespaces (none registered in this hermetic env) stay empty.
            assert.is_nil(Providers.materialize("lsp-errors"))
        end)
    end)
end)

describe("mentions.expand with dynamic providers", function()
    local Providers = require("pi.mention_providers")
    local Mentions = require("pi.ui.chat.mentions")

    local orig_materialize = Providers.materialize
    local orig_get = Providers.get
    local orig_has = Providers.has

    --- Stub the registry: `contents` maps provider name -> materialized text.
    --- Use `false` for a registered provider that produces no content;
    --- unmapped names are treated as unknown providers.
    ---@param contents table<string, string|boolean>
    local function with_providers(contents)
        Providers.get = function(name)
            if contents[name] == nil then
                return nil
            end
            return { name = name, lang = name == "git-diff" and "diff" or nil }
        end
        Providers.has = function(name)
            return contents[name] ~= nil
        end
        Providers.materialize = function(name)
            local content = contents[name]
            if content == nil or content == false then
                return nil
            end
            return content
        end
    end

    before_each(function()
        with_providers({})
    end)

    after_each(function()
        Providers.get = orig_get
        Providers.materialize = orig_materialize
        Providers.has = orig_has
    end)

    it("lifts dynamic mentions out and appends fenced context blocks", function()
        with_providers({ ["git-diff"] = "+new line" })
        local out = Mentions.expand("review @git-diff please")
        assert.same("review please", out:match("^(.-)\n\n"))
        assert.is_true(out:find('<context name="git-diff">', 1, true) ~= nil)
        assert.is_true(out:find("```diff\n+new line\n```", 1, true) ~= nil)
        assert.is_true(out:find("</context>$") ~= nil)
    end)

    it("preserves order of first mention and dedupes repeats", function()
        with_providers({ ["git-diff"] = "D", quickfix = "Q" })
        local out = Mentions.expand("@quickfix and @git-diff and @quickfix again")
        local q = out:find('<context name="quickfix">', 1, true)
        local d = out:find('<context name="git-diff">', 1, true)
        assert.is_true(q ~= nil and d ~= nil and q < d)
        local _, count = out:gsub('<context name="quickfix">', "")
        assert.same(1, count)
    end)

    it("drops mentions whose provider produced nothing", function()
        with_providers({ ["git-log"] = false })
        assert.same("anything else", Mentions.expand("anything @git-log else"))
    end)

    it("strips trailing punctuation before matching providers", function()
        with_providers({ quickfix = "Q" })
        local out = Mentions.expand("(see @quickfix.)")
        assert.same("(see.)", out:match("^(.-)\n\n"))
        assert.is_true(out:find('<context name="quickfix">', 1, true) ~= nil)
    end)

    it("keeps file mentions working alongside dynamic ones", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local file = dir .. "/real.txt"
        local f = io.open(file, "w")
        f:write("x")
        f:close()
        local cwd = vim.uv.cwd()
        vim.cmd("cd " .. dir)
        with_providers({ ["git-diff"] = "D" })
        local out = Mentions.expand("@real.txt and @git-diff")
        assert.is_true(out:find("[file: real.txt]", 1, true) ~= nil)
        assert.is_true(out:find('<context name="git-diff">', 1, true) ~= nil)
        vim.cmd("cd " .. cwd)
    end)

    it("returns blocks alone when the prompt was only a dynamic mention", function()
        with_providers({ ["git-diff"] = "D" })
        local out = Mentions.expand("@git-diff")
        assert.is_true(out:find('^<context name="git%-diff">') ~= nil)
    end)
end)

describe("complete_providers", function()
    local Matcher = require("pi.completion")
    local Providers = require("pi.mention_providers")
    local Config = require("pi.config")

    local orig_providers = Config.options.mention_providers

    --- Run complete_providers and collect (name, is_fuzzy) tuples.
    ---@param prefix string
    ---@return table[]
    local function run(prefix)
        local out = {}
        Matcher.complete_providers(prefix, function(provider, is_fuzzy)
            out[#out + 1] = { provider.name, is_fuzzy }
            return { name = provider.name }
        end)
        return out
    end

    after_each(function()
        Config.options.mention_providers = orig_providers
    end)

    it("empty prefix lists every provider", function()
        assert.same({
            { "git-diff", false },
            { "git-log", false },
            { "lsp-errors", false },
            { "quickfix", false },
        }, run(""))
    end)

    it("prefix matching is case-insensitive", function()
        assert.same({ { "git-diff", false }, { "git-log", false } }, run("GIT"))
        assert.same({ { "quickfix", false } }, run("quick"))
    end)

    it("fuzzy matches come after prefix matches", function()
        -- "qf" fuzzes "quickfix" (q..f); no prefix match.
        assert.same({ { "quickfix", true } }, run("qf"))
        -- "log" prefixes "git-log"... no: "git-log" does not start with "log",
        -- so it is fuzzy.
        assert.same({ { "git-log", true } }, run("log"))
    end)

    it("includes custom providers", function()
        Config.options.mention_providers = {
            todos = function()
                return "t"
            end,
        }
        assert.same({ { "todos", false } }, run("tod"))
    end)
end)
