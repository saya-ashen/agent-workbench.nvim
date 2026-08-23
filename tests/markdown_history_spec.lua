local Config = require("agent-workbench.config")
local History = require("agent-workbench.ui.chat.history")
local Render = require("agent-workbench.ui.render")

local function text_of(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function has_hl_after(buf, row, group)
    for _, mark in
        ipairs(vim.api.nvim_buf_get_extmarks(buf, Render._namespace, { row, 0 }, { -1, -1 }, { details = true }))
    do
        if mark[4].hl_group == group then
            return true
        end
    end
    return false
end

describe("History Markdown block lifecycle", function()
    local original_parser
    local original_flush
    local original_buf
    local history

    before_each(function()
        original_parser = package.loaded["markview.parser"]
        original_flush = History._stream_flush_ms
        original_buf = vim.api.nvim_get_current_buf()
        package.loaded["markview.parser"] = {
            init = function()
                return { markdown = {}, markdown_inline = {} }, {}
            end,
        }
        Config.options.render = {
            markdown = { enabled = true, debounce_ms = 1, features = {}, symbols = {} },
        }
        History._stream_flush_ms = 1
        Render._reset()
        history = History.new(1200)
        vim.api.nvim_win_set_buf(0, history:buf())
        history:set_win(0)
    end)

    after_each(function()
        if original_buf and vim.api.nvim_buf_is_valid(original_buf) then
            vim.api.nvim_win_set_buf(0, original_buf)
        end
        if history and vim.api.nvim_buf_is_valid(history:buf()) then
            vim.api.nvim_buf_delete(history:buf(), { force = true })
        end
        package.loaded["markview.parser"] = original_parser
        History._stream_flush_ms = original_flush
        Config.options.render = { markdown = { enabled = false } }
        Render._reset()
    end)

    it("creates separate assistant segments around a tool block", function()
        history:on_agent_start(1, "output", false)
        history:on_text_delta("```lua\nlocal x = 1")
        vim.wait(30)
        history:on_tool_start("bash", "t1", { command = "echo hi" })
        vim.wait(30)
        history:on_tool_end("bash", "t1", { content = { { type = "text", text = "### tool output" } } }, false)
        vim.wait(30)
        history:on_agent_start(1, "output", true)
        history:on_text_delta("### Next")
        history:on_agent_end()
        vim.wait(80)

        assert.are.equal(2, #history._markdown_blocks)
        assert.are.equal("```lua\nlocal x = 1", table.concat(history._markdown_blocks[1].source_chunks))
        assert.are.equal("### Next", table.concat(history._markdown_blocks[2].source_chunks))
        assert.is_true(history._markdown_blocks[1].complete)
        assert.is_true(history._markdown_blocks[2].complete)
        assert.is_not_nil(text_of(history:buf()):find("### tool output", 1, true))
        assert.is_not_nil(text_of(history:buf()):find("### Next", 1, true))

        local second_anchor = vim.api.nvim_buf_get_extmark_by_id(
            history:buf(),
            Render._namespace,
            history._markdown_blocks[2].anchor,
            {}
        )[1]
        assert.is_true(has_hl_after(history:buf(), second_anchor, "AgentWorkbenchMarkdownHeading3"))
    end)

    it("creates separate assistant segments around thinking", function()
        history:on_agent_start(1, "output", false)
        history:on_text_delta("**before**")
        vim.wait(20)
        history:on_thinking_start({ unmeasured = true })
        history:on_thinking_delta("reasoning")
        history:on_thinking_end()
        vim.wait(30)
        history:on_agent_start(1, "output", true)
        history:on_text_delta("**after**")
        history:on_agent_end()
        vim.wait(60)

        assert.are.equal(2, #history._markdown_blocks)
        assert.are.equal("**before**", table.concat(history._markdown_blocks[1].source_chunks))
        assert.are.equal("**after**", table.concat(history._markdown_blocks[2].source_chunks))
        assert.is_true(history._markdown_blocks[1].complete)
        assert.is_true(history._markdown_blocks[2].complete)
    end)

    it("finalizes assistant Markdown before an error block", function()
        history:on_agent_start(1, "output", false)
        history:on_text_delta("partial **answer**")
        vim.wait(20)
        history:on_error("boom")
        vim.wait(50)
        assert.is_nil(history._active_markdown_block)
        assert.is_true(history._markdown_blocks[1].complete)
        assert.is_not_nil(text_of(history:buf()):find("boom", 1, true))
    end)

    it("parses user and assistant documents independently", function()
        history:add_user_message("# User", 1)
        history:on_agent_start(2, "output", false)
        history:on_text_delta("# Assistant")
        history:on_agent_end()
        vim.wait(80)
        assert.are.equal(2, #history._markdown_blocks)
        assert.are.equal("user", history._markdown_blocks[1].role)
        assert.are.equal(2, history._markdown_blocks[1].col_prefix)
        assert.are.equal("assistant", history._markdown_blocks[2].role)
        assert.are.equal(0, history._markdown_blocks[2].col_prefix)
    end)

    it("keeps Markdown anchors aligned when a parallel tool inserts output above", function()
        history:on_tool_start("bash", "p1", { command = "one" })
        history:on_tool_start("bash", "p2", { command = "two" })
        vim.wait(40)
        history:on_agent_start(2, "output", true)
        history:on_text_delta("### After tools")
        vim.wait(40)
        local block = assert(history._active_markdown_block)
        local before = vim.api.nvim_buf_get_extmark_by_id(history:buf(), Render._namespace, block.anchor, {})[1]

        history:on_tool_end(
            "bash",
            "p1",
            { content = { { type = "text", text = "inserted one\ninserted two" } } },
            false
        )
        vim.wait(50)
        history:on_agent_end()
        vim.wait(50)

        local after = vim.api.nvim_buf_get_extmark_by_id(history:buf(), Render._namespace, block.anchor, {})[1]
        assert.is_true(after > before)
        assert.is_true(has_hl_after(history:buf(), after, "AgentWorkbenchMarkdownHeading3"))
    end)

    it("clear removes Markdown block state and decorations", function()
        history:add_user_message("**bold**", 1)
        vim.wait(40)
        assert.are.equal(1, #history._markdown_blocks)
        history:clear()
        assert.are.equal(0, #history._markdown_blocks)
        assert.is_nil(history._active_markdown_block)
        assert.are.equal(0, #Render._states()[history:buf()].blocks)
    end)
end)
