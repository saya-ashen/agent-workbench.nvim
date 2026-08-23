-- Tool blocks are structural UI, not Markdown. Their text must be preserved
-- exactly and must never receive display-only wrapper/auto-closing fences.

local Config = require("agent-workbench.config")
local History = require("agent-workbench.ui.chat.history")
local Render = require("agent-workbench.ui.render")

local TAB = 910

local function pump(ms)
    vim.wait(ms or 50)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function rows_exact(buf, text)
    local out = {}
    for index, line in ipairs(lines_of(buf)) do
        if line == text then
            out[#out + 1] = index - 1
        end
    end
    return out
end

local function new_history()
    Config.options.render = { markdown = { enabled = false } }
    local history = History.new(TAB)
    history._blocks_expanded = true
    return history
end

local function finish_tool(history, name, id, input, output)
    history:on_tool_start(name, id, input)
    pump()
    history:on_tool_end(name, id, { content = { { type = "text", text = output } } }, false)
    pump()
end

describe("tool text stays outside Markdown", function()
    after_each(function()
        Config.options.render = { markdown = { enabled = true, debounce_ms = 30, features = {}, symbols = {} } }
        Render._reset()
    end)

    it("preserves an unclosed fence without adding a closing marker", function()
        local history = new_history()
        finish_tool(history, "bash", "b1", { command = "echo hi" }, "before\n```lua\nprint(1)")
        assert.are.equal(1, #rows_exact(history:buf(), "```lua"))
        assert.are.equal(0, #rows_exact(history:buf(), "```"))
    end)

    it("preserves indented and arbitrary-length backtick runs verbatim", function()
        local history = new_history()
        local output = "before\n  ```sh\necho hi\n  ````\n`````"
        finish_tool(history, "bash", "b2", { command = "printf test" }, output)
        assert.are.equal(1, #rows_exact(history:buf(), "  ```sh"))
        assert.are.equal(1, #rows_exact(history:buf(), "  ````"))
        assert.are.equal(1, #rows_exact(history:buf(), "`````"))
    end)

    it("does not reinterpret heading, table, or link-like tool output", function()
        local history = new_history()
        finish_tool(history, "my_custom_tool", "c1", { query = "test" }, "### heading\n| a | b |\n[x](url)")
        assert.are.equal(1, #rows_exact(history:buf(), "### heading"))
        assert.are.equal(1, #rows_exact(history:buf(), "| a | b |"))
        assert.are.equal(1, #rows_exact(history:buf(), "[x](url)"))
    end)

    it("collapsed sections contain only real input and output lines", function()
        local history = new_history()
        finish_tool(history, "bash", "b3", { command = "echo hi" }, "o1\no2\no3\no4\no5")
        local block = assert(history._tool_blocks.b3)
        local input, output = require("agent-workbench.ui.chat.tools").extract_tool_sections(history, block)
        assert.are.same({ "echo hi" }, input)
        assert.are.same({ "o1", "o2", "o3", "o4", "o5" }, output)
    end)

    it("keeps native folds and complete raw output", function()
        local history = History.new(TAB)
        local output = table.concat({ "line1", "line2", "line3", "line4", "line5", "line6", "line7", "line8" }, "\n")
        finish_tool(history, "bash", "b4", { command = "echo hi" }, output)
        assert.are.equal(1, #rows_exact(history:buf(), "line1"))
        assert.are.equal(1, #rows_exact(history:buf(), "line8"))
    end)
end)
