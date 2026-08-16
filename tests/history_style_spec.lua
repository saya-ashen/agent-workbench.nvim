-- Visual-polish regression tests for issue #47.
--
-- These assert the *styling* contract only (highlight definitions and the
-- extmarks that paint container backgrounds / diff sign colors / thinking
-- preview). They never touch behavior: collapse thresholds, event flow, and
-- buffer text are out of scope.

local Config = require("agent-workbench.config")
local History = require("agent-workbench.ui.chat.history")
local Highlights = require("agent-workbench.ui.highlights")

local function pump(ms)
    vim.wait(ms or 60)
end

--- First line_hl_group found on a row, or nil.
local function row_line_hl(h, row)
    local ems = vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), { row, 0 }, { row, -1 }, { details = true })
    for _, em in ipairs(ems) do
        local d = em[4] or {}
        if d.line_hl_group then
            return d.line_hl_group
        end
    end
    return nil
end

--- Collect the hl_group of every extmark in the buffer into a set.
local function hl_groups_present(h)
    local set = {}
    local ems = vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), 0, -1, { details = true })
    for _, em in ipairs(ems) do
        local hl = (em[4] or {}).hl_group
        if hl then
            set[hl] = true
        end
    end
    return set
end

describe("history visual polish (issue #47)", function()
    before_each(function()
        Config.options.render = { engine = "builtin" }
        require("agent-workbench.ui.render")._reset()
    end)

    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("agent-workbench.ui.render")._reset()
    end)

    describe("highlight definitions", function()
        before_each(function()
            Highlights.setup()
        end)

        it("makes tool input the main body level (normal text color)", function()
            local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
            local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
            local tool_call = vim.api.nvim_get_hl(0, { name = "PiToolCall", link = false })
            assert.are.equal(normal.fg, tool_call.fg, "PiToolCall should use normal text color")
            assert.are_not.equal(comment.fg, tool_call.fg, "PiToolCall should not be Comment gray")
        end)

        it("defines a distinct, subdued thinking preview group", function()
            local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
            local preview = vim.api.nvim_get_hl(0, { name = "PiThinkingPreview", link = false })
            assert.are.equal(comment.fg, preview.fg, "PiThinkingPreview should be Comment gray")
            assert.is_true(preview.italic, "PiThinkingPreview should be italic")
            -- Header keeps the louder Special color, so the two are distinct.
            local header = vim.api.nvim_get_hl(0, { name = "PiThinking", link = false })
            assert.are_not.equal(header.fg, preview.fg, "preview must differ from the thinking header")
        end)

        it("defines semantic diff sign groups with a real foreground", function()
            local add_sign = vim.api.nvim_get_hl(0, { name = "PiDiffAddSign", link = false })
            local del_sign = vim.api.nvim_get_hl(0, { name = "PiDiffDeleteSign", link = false })
            assert.are.equal("number", type(add_sign.fg), "PiDiffAddSign needs a foreground")
            assert.are.equal("number", type(del_sign.fg), "PiDiffDeleteSign needs a foreground")
            assert.is_true(add_sign.bold, "PiDiffAddSign should be bold")
            assert.is_true(del_sign.bold, "PiDiffDeleteSign should be bold")
        end)
    end)

    describe("tool block container background", function()
        it("paints header, body, and footer with one continuous background", function()
            local h = History.new(960)
            h:on_tool_start("bash", "t1", { command = "echo hi" })
            pump()
            h:on_tool_end("bash", "t1", { content = { { type = "text", text = "hi" } } }, false)
            pump(120)

            local b = h._tool_blocks["t1"]
            local buf, ns = h:buf(), h:ns()
            local header_row = vim.api.nvim_buf_get_extmark_by_id(buf, ns, b.icon_extmark, {})[1]
            local footer_row = vim.api.nvim_buf_get_extmark_by_id(buf, ns, b.end_extmark, {})[1]
            assert.is_not_nil(header_row)
            assert.is_not_nil(footer_row)
            assert.is_true(footer_row > header_row + 1, "block has a body between header and footer")

            assert.are.equal("PiToolBody", row_line_hl(h, header_row), "header carries the container bg")
            assert.are.equal("PiToolBody", row_line_hl(h, header_row + 1), "body carries the container bg")
            assert.are.equal("PiToolBody", row_line_hl(h, footer_row), "footer carries the container bg")
        end)

        it("keeps the footer background across a collapse/expand round-trip", function()
            local h = History.new(961)
            local output = table.concat({ "o1", "o2", "o3", "o4", "o5", "o6", "o7", "o8", "o9", "o10" }, "\n")
            h:on_tool_start("bash", "t2", { command = "cmd" })
            pump()
            h:on_tool_end("bash", "t2", { content = { { type = "text", text = output } } }, false)
            pump(120)

            local b = h._tool_blocks["t2"]
            local buf, ns = h:buf(), h:ns()

            h:_set_tool_block_expanded(b, true)
            h:_set_tool_block_expanded(b, false)
            assert.is_false(b.expanded)

            local footer_row = vim.api.nvim_buf_get_extmark_by_id(buf, ns, b.end_extmark, {})[1]
            assert.are.equal("PiToolBody", row_line_hl(h, footer_row), "footer bg survives the round-trip")
        end)
    end)

    describe("bash direct-execution block container background", function()
        it("paints header and footer with the container background", function()
            local h = History.new(962)
            h:on_bash_start("bs1", "ls -la", false)
            pump()
            h:on_bash_output("bs1", "file1\nfile2\n")
            pump(120)
            h:on_bash_end("bs1", { output = "file1\nfile2\n", exitCode = 0 })
            pump(120)

            local bb = h._bash_blocks["bs1"]
            local buf, ns = h:buf(), h:ns()
            local header_row = vim.api.nvim_buf_get_extmark_by_id(buf, ns, bb.header_extmark, {})[1]
            local footer_row = vim.api.nvim_buf_get_extmark_by_id(buf, ns, bb.end_extmark, {})[1]
            assert.is_not_nil(header_row)
            assert.is_not_nil(footer_row)

            assert.are.equal("PiToolBody", row_line_hl(h, header_row), "bash header carries the container bg")
            assert.are.equal("PiToolBody", row_line_hl(h, footer_row), "bash footer carries the container bg")
        end)

        it("keeps excluded-from-context (!!) headers dim now that PiToolCall is body color", function()
            local h = History.new(966)
            h:on_bash_start("bs2", "secret", true) -- exclude_from_context = true
            pump()

            local bb = h._bash_blocks["bs2"]
            local buf, ns = h:buf(), h:ns()
            local header_row = vim.api.nvim_buf_get_extmark_by_id(buf, ns, bb.header_extmark, {})[1]
            local line = vim.api.nvim_buf_get_lines(buf, header_row, header_row + 1, false)[1] or ""

            -- The header text (after the fold glyph) must stay receded, not the
            -- loud normal-color PiToolCall nor the warning-color PiBashHeader.
            local text_hl = nil
            for _, em in
                ipairs(
                    vim.api.nvim_buf_get_extmarks(buf, ns, { header_row, 0 }, { header_row, -1 }, { details = true })
                )
            do
                local d = em[4] or {}
                if d.hl_group and em[3] > 0 and d.end_col == #line then
                    text_hl = d.hl_group
                end
            end
            assert.are.equal("PiToolBorder", text_hl, "excluded bash header renders dim")
        end)
    end)

    describe("diff sign semantic colors", function()
        it("splits the sign column into PiDiffAddSign / PiDiffDeleteSign", function()
            local h = History.new(963)
            h._blocks_expanded = true -- keep the diff expanded (write auto-collapses output)
            local tmp = vim.fn.tempname()
            vim.fn.writefile({ "a", "b", "c" }, tmp)

            h:on_tool_start("write", "w1", { path = tmp, content = "a\nB\nc" })
            pump()
            h:on_tool_end("write", "w1", {}, false)
            pump(120)

            local present = hl_groups_present(h)
            assert.is_true(present["PiDiffAddSign"], "a + line gets a PiDiffAddSign sign")
            assert.is_true(present["PiDiffDeleteSign"], "a - line gets a PiDiffDeleteSign sign")
            -- Line numbers stay gray: the prefix still carries PiDiffLineNr.
            assert.is_true(present["PiDiffLineNr"], "line numbers keep PiDiffLineNr")
        end)

        it("places the sign highlight on the sign column (prefix_len - 2)", function()
            local h = History.new(964)
            h._blocks_expanded = true -- keep the diff expanded (write auto-collapses output)
            local tmp = vim.fn.tempname()
            vim.fn.writefile({ "a", "b", "c" }, tmp)

            h:on_tool_start("write", "w2", { path = tmp, content = "a\nB\nc" })
            pump()
            h:on_tool_end("write", "w2", {}, false)
            pump(120)

            local buf, ns = h:buf(), h:ns()
            local ems = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
            local checked = 0
            for _, em in ipairs(ems) do
                local d = em[4] or {}
                if d.hl_group == "PiDiffAddSign" or d.hl_group == "PiDiffDeleteSign" then
                    -- "%4d X " prefix: the sign char sits at column 5, one cell wide.
                    assert.are.equal(5, em[3], "sign highlight starts on the sign column")
                    assert.are.equal(6, d.end_col, "sign highlight covers exactly the sign char")
                    checked = checked + 1
                end
            end
            assert.is_true(checked >= 2, "saw at least one add and one delete sign")
        end)
    end)

    describe("thinking preview", function()
        it("renders the rolling preview in PiThinkingPreview, not PiThinking", function()
            local h = History.new(965)
            local row = h:_append_lines({ "thinking header" })
            local id = h:_set_thinking_preview(row, "some preview text", nil)
            assert.is_not_nil(id)

            -- get_extmark_by_id returns { row, col, details } (details at index 3).
            local em = vim.api.nvim_buf_get_extmark_by_id(h:buf(), h:ns(), id, { details = true })
            local vt = (em[3] or {}).virt_text
            assert.is_not_nil(vt and vt[1], "preview virt_text exists")
            assert.are.equal("PiThinkingPreview", vt[1][2], "preview uses PiThinkingPreview")
        end)
    end)
end)
