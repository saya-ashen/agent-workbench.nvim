-- Dedicated history renderers for the pi-web-access extension tools
-- (web_search, fetch_content, source_check, get_search_content):
-- compact input summary lines, dedicated icons, and auto-collapse of their
-- characteristically long outputs (issue #51).

local Config = require("pi.config")
local History = require("pi.ui.chat.history")
local Tools = require("pi.ui.chat.tools")

local function pump(ms)
    vim.wait(ms or 60)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Rows (0-indexed) of every buffer line containing `sub` (plain match).
local function rows_with(buf, sub)
    local out = {}
    for i, l in ipairs(lines_of(buf)) do
        if l:find(sub, 1, true) then
            out[#out + 1] = i - 1
        end
    end
    return out
end

--- Live-event shaped tool result.
local function result_text(text)
    return { content = { { type = "text", text = text } } }
end

describe("pi-web-access tool renderers (issue #51)", function()
    before_each(function()
        Config.options.render = { engine = "builtin" }
    end)

    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    describe("renderer lookup", function()
        it("returns dedicated renderers with collapse thresholds", function()
            local default = Tools.get_renderer("__no_such_tool__")
            for _, name in ipairs({ "web_search", "fetch_content", "source_check", "get_search_content" }) do
                local r = Tools.get_renderer(name)
                assert.is_not(r, default, name .. " must not fall through to default_renderer")
                assert.are.equal(1, r.input_visible)
                assert.are.equal(1, r.output_visible)
                assert.is_nil(r.inline)
            end
        end)

        it("provides dedicated icons", function()
            local generic = Config.options.labels.tool
            assert.are.equal(vim.fn.nr2char(0xF0349, 1), Tools.get_tool_icon("web_search"))
            assert.are.equal(vim.fn.nr2char(0xF059F, 1), Tools.get_tool_icon("fetch_content"))
            assert.are.equal(vim.fn.nr2char(0xF0565, 1), Tools.get_tool_icon("source_check"))
            assert.are.equal(vim.fn.nr2char(0xF0866, 1), Tools.get_tool_icon("get_search_content"))
            assert.is_not(generic, Tools.get_tool_icon("fetch_content"))
        end)
    end)

    describe("web_search input summary", function()
        it("shows a single query", function()
            local h = History.new(960)
            h:on_tool_start("web_search", "t1", { query = "rust async" })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "rust async") == 1)
        end)

        it("joins queries with a separator", function()
            local h = History.new(961)
            h:on_tool_start("web_search", "t1", { queries = { "alpha", "beta" } })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "alpha · beta") == 1)
        end)

        it("truncates query lists longer than three", function()
            local h = History.new(962)
            h:on_tool_start("web_search", "t1", { queries = { "q1", "q2", "q3", "q4", "q5" } })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "q1 · q2 · q3 · …(+2)") == 1)
        end)
    end)

    describe("fetch_content input summary", function()
        it("shows a single url", function()
            local h = History.new(963)
            h:on_tool_start("fetch_content", "t1", { url = "https://example.com/guide" })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "https://example.com/guide") == 1)
        end)

        it("shows each url of a urls array on its own line", function()
            local h = History.new(964)
            h:on_tool_start("fetch_content", "t1", { urls = { "https://a.example", "https://b.example" } })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "https://a.example") == 1)
            assert.is_true(#rows_with(h:buf(), "https://b.example") == 1)
        end)
    end)

    describe("source_check input summary", function()
        it("shows the claim", function()
            local h = History.new(965)
            h:on_tool_start("source_check", "t1", { claim = "the api supports streaming" })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "the api supports streaming") == 1)
        end)
    end)

    describe("get_search_content input summary", function()
        it("shows responseId with a urlIndex selector", function()
            local h = History.new(966)
            h:on_tool_start("get_search_content", "t1", { responseId = "abc123", urlIndex = 1 })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "abc123 · urlIndex 1") == 1)
        end)

        it("shows responseId with query and offset-free selectors", function()
            local h = History.new(967)
            h:on_tool_start("get_search_content", "t1", { responseId = "xyz", url = "https://c.example" })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "xyz · https://c.example") == 1)
        end)
    end)

    describe("auto-collapse", function()
        it("collapses long web_search output and expands back", function()
            local h = History.new(968)
            h:on_tool_start("web_search", "t1", { query = "q" })
            pump(60)
            local out = table.concat({ "line1", "line2", "line3", "line4", "line5" }, "\n")
            h:on_tool_end("web_search", "t1", result_text(out), false)
            pump(120)
            local buf = h:buf()
            local b = h._tool_blocks["t1"]
            assert.is_false(b.expanded, "long output must auto-collapse")
            assert.is_true(#rows_with(buf, Tools.GLYPHS.FOLD_CLOSE) >= 1, "header shows folded glyph")
            assert.is_true(#rows_with(buf, "…4 lines") == 1, "collapsed summary counts hidden lines")
            assert.is_true(#rows_with(buf, "line2") == 0, "hidden output lines are not in the buffer")
            assert.is_true(#rows_with(buf, "line5") == 1, "tail output line stays visible")

            h:_set_tool_block_expanded(b, true)
            pump(60)
            assert.is_true(b.expanded, "expand restores the block")
            assert.is_true(#rows_with(buf, "line2") == 1, "hidden lines reappear after expand")
        end)

        it("does not collapse short output", function()
            local h = History.new(969)
            h:on_tool_start("fetch_content", "t1", { url = "https://example.com" })
            pump(60)
            h:on_tool_end("fetch_content", "t1", result_text("ok"), false)
            pump(120)
            local b = h._tool_blocks["t1"]
            assert.is_true(b.expanded, "short output stays expanded")
            assert.is_true(#rows_with(h:buf(), "…") == 0, "no collapsed summary for short output")
        end)

        it("keeps unknown tools on the default renderer (behavior unchanged)", function()
            local h = History.new(970)
            h:on_tool_start("some_other_extension_tool", "t1", { query = "q" })
            pump(60)
            local out = table.concat({ "a1", "b2", "c3", "d4" }, "\n")
            h:on_tool_end("some_other_extension_tool", "t1", result_text(out), false)
            pump(120)
            local buf = h:buf()
            local b = h._tool_blocks["t1"]
            -- Default renderer keeps its own 1/1 thresholds and input picking.
            assert.is_not(b.expanded, "default renderer still collapses long output")
            assert.is_true(#rows_with(buf, "…3 lines") == 1, "default collapsed summary")
            assert.is_true(#rows_with(buf, "q") >= 1, "default input summary (first short string)")
        end)
    end)

    describe("replay compatibility", function()
        it("renders plain-string result content from replayed toolResult", function()
            local h = History.new(971)
            h:on_tool_start("source_check", "t1", { claim = "the sky is blue" })
            pump(60)
            h:on_tool_end("source_check", "t1", { content = "Status: supported" }, false)
            pump(120)
            assert.is_true(#rows_with(h:buf(), "Status: supported") == 1)
        end)
    end)
end)
