-- Stream coalescing: rapid RPC deltas accumulate and flush at most once per
-- History._stream_flush_ms, while structural events (tool blocks, thinking
-- blocks, turn boundaries) drain the pending stream in dispatch order.

local Config = require("agent-workbench.config")
local History = require("agent-workbench.ui.chat.history")

local TAB = 903

local function pump(ms)
    vim.wait(ms or 30)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function text_of(buf)
    return table.concat(lines_of(buf), "\n")
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

local function wait_line(buf, sub)
    vim.wait(2000, function()
        return #rows_with(buf, sub) > 0
    end, 5)
end

describe("stream coalescing", function()
    local saved_flush_ms
    before_each(function()
        saved_flush_ms = History._stream_flush_ms
        History._stream_flush_ms = 1
        Config.options.render = { engine = "builtin" }
        require("agent-workbench.ui.render")._reset()
    end)
    after_each(function()
        History._stream_flush_ms = saved_flush_ms
        Config.options.render = { engine = "builtin" }
        require("agent-workbench.ui.render")._reset()
    end)

    it("keeps the agent label above the first text when the block opens lazily", function()
        -- Chat opens the assistant block lazily: the first non-whitespace
        -- text_delta calls History:on_agent_start and History:on_text_delta
        -- back-to-back in one dispatch, before any scheduled callback ran. The
        -- first delta must still land *below* the label line.
        local h = History.new(TAB)
        h:on_agent_start(nil)
        h:on_text_delta("first chunk ")
        pump(80)
        h:on_text_delta("second chunk")
        pump(80)
        local buf = h:buf()
        local icon = Config.options.labels.agent_response
        local label = rows_with(buf, icon)
        local first = rows_with(buf, "first chunk")
        assert.are.equal(1, #label, "label rendered")
        assert.are.equal(1, #first, "first chunk rendered")
        assert.is_true(label[1] < first[1], "label precedes first streamed text")
    end)

    it("renders many rapid text deltas completely and in order", function()
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        for i = 1, 200 do
            h:on_text_delta(("chunk-%d "):format(i))
        end
        local buf = h:buf()
        vim.wait(2000, function()
            return text_of(buf):find("chunk%-200", 1) ~= nil
        end, 5)
        local text = text_of(buf)
        assert.is_true(text:find("chunk%-1 ", 1) ~= nil, "first chunk present")
        assert.is_true(text:find("chunk%-200 ", 1) ~= nil, "last chunk present")
        -- in-order: chunk-7 must appear before chunk-42
        local a = text:find("chunk%-7 ")
        local b = text:find("chunk%-42 ")
        assert.is_true(a < b, "chunks render in order")
        -- exactly one contiguous run: all 200 chunks landed
        assert.is_true(text:find("chunk%-199 chunk%-200", 1) ~= nil, "adjacent chunks joined")
    end)

    it("keeps text and tool blocks in stream order", function()
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        h:on_text_delta("before-tool\n")
        h:on_tool_start("bash", "t1", { command = "make build" })
        h:on_text_delta("after-tool-start\n")
        h:on_tool_end("bash", "t1", { content = { { type = "text", text = "ok" } } }, false)
        h:on_text_delta("after-tool-end")
        h:on_agent_end()
        pump(80)
        local buf = h:buf()
        local pre = rows_with(buf, "before-tool")
        local tool = rows_with(buf, "make build")
        local mid = rows_with(buf, "after-tool-start")
        local post = rows_with(buf, "after-tool-end")
        assert.are.equal(1, #pre)
        assert.is_true(#tool >= 1)
        assert.are.equal(1, #mid)
        assert.are.equal(1, #post)
        assert.is_true(pre[1] < tool[1], "text before tool block")
        -- Text that streams in while the tool body is the buffer's last line
        -- appends into that line (pre-existing behavior, identical to the old
        -- per-delta pipeline): it may share the tool row but never precedes it.
        assert.is_true(tool[1] <= mid[1], "mid text never precedes the tool block")
        assert.is_true(mid[1] < post[1], "mid text before trailing text")
    end)

    it("renders text after tool_end on its own row (breathing line)", function()
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        h:on_text_delta("before-tool\n")
        h:on_tool_start("bash", "t1", { command = "make build" })
        h:on_tool_end("bash", "t1", { content = { { type = "text", text = "ok" } } }, false)
        h:on_text_delta("after-tool-end")
        h:on_agent_end()
        pump(80)
        local buf = h:buf()
        local pre = rows_with(buf, "before-tool")
        local tool = rows_with(buf, "make build")
        local post = rows_with(buf, "after-tool-end")
        assert.are.equal(1, #pre)
        assert.is_true(#tool >= 1)
        assert.are.equal(1, #post)
        assert.is_true(pre[1] < tool[1], "text before tool block")
        assert.is_true(tool[1] < post[1], "tool block strictly before trailing text")
    end)

    it("coalesces thinking deltas and freezes the block on thinking_end", function()
        Config.options.show_thinking = true
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        h:on_thinking_start()
        pump(30)
        for i = 1, 50 do
            h:on_thinking_delta(("think-%d "):format(i))
        end
        h:on_thinking_end()
        pump(80)
        local buf = h:buf()
        assert.are.equal(1, #rows_with(buf, "Thought for"), "thinking block frozen")
        -- all deltas merged into the stored accum lines
        local block = h._thinking_blocks[#h._thinking_blocks]
        local joined = table.concat(block.lines, "\n")
        assert.is_true(joined:find("think%-1 ") ~= nil, "first thinking delta stored")
        assert.is_true(joined:find("think%-50 ") ~= nil, "last thinking delta stored")
        Config.options.show_thinking = false
    end)

    it("handles thinking deltas dispatched in the same batch as thinking_start", function()
        Config.options.show_thinking = true
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        -- No pump between start and deltas: simulates one stdout chunk carrying
        -- thinking_start + deltas + thinking_end (no scheduled callback ran yet).
        h:on_thinking_start()
        h:on_thinking_delta("early thinking")
        h:on_thinking_end()
        pump(80)
        local buf = h:buf()
        assert.are.equal(1, #rows_with(buf, "Thought for"), "block created and frozen")
        local block = h._thinking_blocks[#h._thinking_blocks]
        assert.is_true(table.concat(block.lines, "\n"):find("early thinking", 1, true) ~= nil)
        Config.options.show_thinking = false
    end)

    it("keeps a running tool title-only, then folds its short final output", function()
        local h = History.new(TAB)
        local original_buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_win_set_buf(0, h:buf())
        h:set_win(0)
        h:on_agent_start(nil)
        pump(30)
        h:on_tool_start("bash", "t1", { command = "make" })
        pump(30)
        h:on_tool_update("bash", "t1", { partialResult = { content = { { type = "text", text = "stale-output" } } } })
        h:on_tool_update("bash", "t1", { partialResult = { content = { { type = "text", text = "fresh-output" } } } })
        pump(60)

        local buf = h:buf()
        local block = h._tool_blocks.t1
        local header_row = vim.api.nvim_buf_get_extmark_by_id(buf, h:ns(), block.icon_extmark, {})[1]
        local footer_row = vim.api.nvim_buf_get_extmark_by_id(buf, h:ns(), block.end_extmark, {})[1]
        local header = vim.api.nvim_buf_get_lines(buf, header_row, header_row + 1, false)[1]
        assert.is_truthy(header:find("make", 1, true))
        assert.are.equal(0, #rows_with(buf, "fresh-output"))
        assert.are.equal(0, #rows_with(buf, "stale-output"))
        assert.are.equal(0, #vim.tbl_keys(h._pending_tool_updates))
        assert.is_true(vim.fn.foldclosed(header_row + 1) ~= -1)
        assert.are.equal(-1, vim.fn.foldclosed(footer_row + 1))

        h:on_tool_end("bash", "t1", { content = { { type = "text", text = "done" } } }, false)
        pump(80)
        footer_row = vim.api.nvim_buf_get_extmark_by_id(buf, h:ns(), block.end_extmark, {})[1]
        assert.is_true(block.foldable)
        assert.is_true(vim.fn.foldclosed(header_row + 1) ~= -1)
        assert.are.equal(-1, vim.fn.foldclosed(footer_row + 1))
        assert.are.equal(1, #rows_with(buf, "done"))

        vim.wo[0].winfixbuf = false
        vim.api.nvim_win_set_buf(0, original_buf)
    end)

    it("drops tool updates for unknown tools", function()
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        h:on_tool_update("bash", "nope", { partialResult = { content = { { type = "text", text = "ghost" } } } })
        pump(50)
        assert.are.equal(0, #rows_with(h:buf(), "ghost"))
        assert.are.equal(0, #vim.tbl_keys(h._pending_tool_updates), "pending update dropped")
    end)

    it("joins coalesced bash chunks with correct partial-line handling", function()
        local h = History.new(TAB)
        h:on_bash_start("b1", "cmd", false)
        pump(30)
        -- Three chunks in one flush window; partial line spans chunk boundary.
        h:on_bash_output("b1", "hel")
        h:on_bash_output("b1", "lo\nwor")
        h:on_bash_output("b1", "ld\n")
        local buf = h:buf()
        wait_line(buf, "world")
        pump(20)
        local text = text_of(buf)
        assert.is_true(text:find("hello", 1, true) ~= nil, "joined partial line")
        assert.is_true(text:find("world", 1, true) ~= nil, "completed line")
    end)

    it("renders straggler text after agent_end before the next turn's header", function()
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        h:on_text_delta("turn one text")
        h:on_agent_end()
        -- Straggler arrives after agent_end but before its scheduled callback ran.
        h:on_text_delta("straggler")
        pump(80)
        h:on_agent_start(nil)
        pump(80)
        local buf = h:buf()
        local stray = rows_with(buf, "straggler")
        assert.are.equal(1, #stray, "straggler rendered")
        -- And it lands before the second turn's content.
        h:on_text_delta("turn two text")
        local b2 = h:buf()
        wait_line(b2, "turn two text")
        local two = rows_with(b2, "turn two text")
        assert.is_true(stray[1] < two[1], "straggler precedes next turn content")
    end)

    it("clear() drops pending stream content and disarms the timer", function()
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        h:on_text_delta("pending text")
        h:on_thinking_start()
        h:on_thinking_delta("pending thinking")
        h:on_bash_start("b1", "cmd", false)
        h:on_bash_output("b1", "pending output\n")
        h:on_tool_update("bash", "t9", { partialResult = { content = { { type = "text", text = "x" } } } })
        h:clear()
        assert.is_nil(h._stream_timer)
        assert.are.equal(1, #h._text_batches) -- one empty open batch (invariant)
        assert.are.equal(0, h._structural_inflight)
        assert.are.equal(0, #vim.tbl_keys(h._pending_thinking))
        assert.are.equal(0, #vim.tbl_keys(h._pending_bash))
        assert.are.equal(0, #vim.tbl_keys(h._pending_tool_updates))
        pump(60) -- let any queued callbacks run; pending stream content stays dropped
        local text = text_of(h:buf())
        assert.is_nil(text:find("pending text", 1, true))
        assert.is_nil(text:find("pending output", 1, true))
    end)

    it("agent_end table scan sees the fully drained text", function()
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        -- A complete markdown table streamed as small deltas, then agent_end
        -- immediately: the drain inside on_agent_end must land the text before
        -- _render_tables scans the range.
        h:on_text_delta("| a | b |\n")
        h:on_text_delta("| - | - |\n")
        h:on_text_delta("| 1 | 2 |\n")
        h:on_agent_end()
        pump(80)
        local buf = h:buf()
        assert.is_true(
            text_of(buf):find("─", 1, true) ~= nil or #rows_with(buf, "│") > 0,
            "table rendered from drained text"
        )
    end)
end)
