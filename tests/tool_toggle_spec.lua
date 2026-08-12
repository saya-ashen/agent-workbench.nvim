-- Regression: a tool block must round-trip through native folds without
-- replacing transcript lines. Complete output stays addressable in buffer;
-- fold state only controls window visibility.

local Config = require("pi.config")
local Chat = require("pi.ui.chat")
local History = require("pi.ui.chat.history")

local function pump(ms)
    vim.wait(ms or 60)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function rows_with(buf, sub)
    local out = {}
    for i, l in ipairs(lines_of(buf)) do
        if l:find(sub, 1, true) then
            out[#out + 1] = i - 1
        end
    end
    return out
end

local function bash_collapsed(h)
    local output = table.concat({
        "o1",
        "o2",
        "o3",
        "o4",
        "o5",
        "o6",
        "o7",
        "o8",
        "o9",
        "o10",
    }, "\n")
    h:on_tool_start("bash", "b1", { command = "cmd" })
    pump()
    h:on_tool_end("bash", "b1", { content = { { type = "text", text = output } } }, false)
    pump(120)
end

local function bash_output_collapsed(h, id, count)
    local output = {}
    for i = 1, count do
        output[i] = id .. "-" .. i
    end
    h:on_tool_start("bash", id, { command = "cmd" })
    pump()
    h:on_tool_end("bash", id, { content = { { type = "text", text = table.concat(output, "\n") } } }, false)
    pump(120)
    return output
end

local function end_alive(h, block)
    local r = vim.api.nvim_buf_get_extmark_by_id(h:buf(), h:ns(), block.end_extmark, {})
    return r[1] ~= nil
end

local function end_is_single_line(h, block)
    local d = vim.api.nvim_buf_get_extmark_by_id(h:buf(), h:ns(), block.end_extmark, { details = true })
    local start_row = d[1]
    local details = d[3] or {}
    -- get_extmark_by_id returns absolute end_row.  A single-line mark has
    -- end_row == start_row (or no end_row).  The set_lines gravity bug produces
    -- a multi-line mark whose end_row differs from start_row.
    return not details.end_row or details.end_row == start_row
end

describe("tool block expand/collapse round-trip", function()
    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    it("expands output of exactly 30 lines inline", function()
        local h = History.new(960)
        bash_output_collapsed(h, "boundary", 30)
        local block = h._tool_blocks.boundary
        local history_buf = h:buf()

        vim.api.nvim_win_set_buf(0, history_buf)
        h:set_win(0)
        local header_row = vim.api.nvim_buf_get_extmark_by_id(history_buf, h:ns(), block.icon_extmark, {})[1]
        vim.api.nvim_win_set_cursor(0, { header_row + 1, 0 })

        assert.is_true(h:toggle_tool_block())
        assert.are.equal(history_buf, vim.api.nvim_get_current_buf())
        assert.is_true(block.expanded)
    end)

    it("opens output longer than 30 lines in a read-only split", function()
        local h = History.new(961)
        local output = bash_output_collapsed(h, "long", 31)
        local block = h._tool_blocks.long
        local history_buf = h:buf()

        vim.api.nvim_win_set_buf(0, history_buf)
        h:set_win(0)
        local header_row = vim.api.nvim_buf_get_extmark_by_id(history_buf, h:ns(), block.icon_extmark, {})[1]
        vim.api.nvim_win_set_cursor(0, { header_row + 1, 0 })

        assert.is_true(h:open_tool_output_at_cursor())
        local viewer_buf = vim.api.nvim_get_current_buf()
        assert.is_true(viewer_buf ~= history_buf)
        assert.are.same(output, lines_of(viewer_buf))
        assert.are.equal("nofile", vim.bo[viewer_buf].buftype)
        assert.is_false(vim.bo[viewer_buf].modifiable)
        assert.is_true(vim.bo[viewer_buf].readonly)
        assert.are.equal("Close tool output", vim.fn.maparg("q", "n", false, true).desc)
        assert.is_false(block.expanded, "long block must stay collapsed in chat")

        vim.api.nvim_win_close(0, true)
    end)

    it("opens long output from a floating history in a normal split", function()
        local h = History.new(962)
        local output = bash_output_collapsed(h, "float", 31)
        local block = h._tool_blocks.float
        local history_buf = h:buf()
        local float_win = vim.api.nvim_open_win(history_buf, true, {
            relative = "editor",
            row = 1,
            col = 1,
            width = 40,
            height = 8,
        })
        h:set_win(float_win)
        local header_row = vim.api.nvim_buf_get_extmark_by_id(history_buf, h:ns(), block.icon_extmark, {})[1]
        vim.api.nvim_win_set_cursor(float_win, { header_row + 1, 0 })

        assert.is_true(h:open_tool_output_at_cursor())
        local viewer_win = vim.api.nvim_get_current_win()
        assert.are.equal("", vim.api.nvim_win_get_config(viewer_win).relative)
        assert.are.same(output, lines_of(vim.api.nvim_win_get_buf(viewer_win)))
        assert.is_false(block.expanded)

        vim.api.nvim_win_close(viewer_win, true)
        vim.api.nvim_win_close(float_win, true)
    end)

    it("previews and opens a long batch child from the real buffer layout", function()
        local chat = Chat.new(vim.api.nvim_get_current_tabpage(), "buffer", {})
        chat:show()
        vim.cmd("stopinsert")
        local h = chat._history
        local output = {}
        for i = 1, 31 do
            output[i] = "item-" .. i
        end
        local batch_lines = {
            "Batch: 2/2 succeeded",
            "",
            "## 1. read",
            "Status: completed",
            "short-1",
            "short-2",
            "",
            "## 2. read",
            "Status: completed",
        }
        vim.list_extend(batch_lines, output)
        h:on_tool_start("tool_batch", "batch", { calls = { {}, {} } })
        pump()
        local events = {}
        local refresh = h._refresh_native_folds
        h._refresh_native_folds = function(self)
            events[#events + 1] = "refresh"
            refresh(self)
        end
        h._should_auto_scroll = function()
            return true
        end
        h._scroll_to_bottom = function()
            events[#events + 1] = "scroll"
        end
        h:on_tool_end("tool_batch", "batch", {
            content = { { type = "text", text = table.concat(batch_lines, "\n") } },
            details = {
                items = {
                    { toolName = "read", args = { path = "/tmp/short.md" }, isError = false },
                    { toolName = "read", args = { path = "/tmp/example.md" }, isError = false },
                },
            },
        }, false)
        pump(200)
        assert.are.same({ "refresh", "scroll" }, events)

        local parent = h._tool_blocks.batch
        local first = h._tool_blocks["batch:batch:1"]
        local block = h._tool_blocks["batch:batch:2"]
        local history_win = chat._layout:history_win()
        local first_row = vim.api.nvim_buf_get_extmark_by_id(h:buf(), h:ns(), first.icon_extmark, {})[1]
        local first_header = vim.api.nvim_buf_get_lines(h:buf(), first_row, first_row + 1, false)[1]
        local header_row = vim.api.nvim_buf_get_extmark_by_id(h:buf(), h:ns(), block.icon_extmark, {})[1]
        local header = vim.api.nvim_buf_get_lines(h:buf(), header_row, header_row + 1, false)[1]
        assert.is_false(parent.foldable)
        assert.is_true(first.foldable)
        assert.is_nil(first.preview_extmark)
        assert.is_truthy(first_header:find("󰈙", 1, true))
        assert.is_truthy(first_header:find("/tmp/short.md", 1, true))
        assert.is_true(block.foldable)
        assert.is_false(block.expanded)
        assert.is_truthy(header:find("󰈙", 1, true))
        assert.is_truthy(header:find("read", 1, true))
        assert.is_truthy(header:find("/tmp/example.md", 1, true))
        assert.is_nil(header:find("## 1.", 1, true))
        assert.is_true(vim.api.nvim_win_call(history_win, function()
            return vim.fn.foldclosed(header_row + 1) ~= -1
        end))
        assert.is_nil(block.preview_extmark)

        vim.api.nvim_set_current_win(history_win)
        vim.api.nvim_win_set_cursor(history_win, { header_row + 1, 0 })
        vim.fn.maparg("zo", "n", false, true).callback()
        assert.is_false(block.expanded)
        assert.is_true(block.preview_expanded)
        assert.is_true(vim.api.nvim_win_call(history_win, function()
            return vim.fn.foldclosed(header_row + 1) ~= -1
        end))
        local preview = vim.api.nvim_buf_get_extmark_by_id(h:buf(), h:ns(), block.preview_extmark, { details = true })
        local preview_lines = preview[3].virt_lines
        assert.are.equal(5, #preview_lines)
        assert.is_truthy(preview_lines[1][1][1]:find("item%-1"))
        assert.is_truthy(preview_lines[4][1][1]:find("item%-4"))
        assert.is_truthy(preview_lines[5][1][1]:find("27 more lines", 1, true))
        assert.are.equal(header, vim.api.nvim_buf_get_lines(h:buf(), header_row, header_row + 1, false)[1])

        vim.fn.maparg("zc", "n", false, true).callback()
        assert.is_false(block.expanded)
        assert.is_false(block.preview_expanded)
        assert.is_nil(block.preview_extmark)
        vim.fn.maparg("o", "n", false, true).callback()
        assert.is_true(block.preview_expanded)
        assert.is_not_nil(block.preview_extmark)

        local tab_map = vim.fn.maparg("<Tab>", "n", false, true)
        assert.are.equal("Open π block output", tab_map.desc)
        tab_map.callback()

        assert.are.equal("pi-tool-output", vim.bo.filetype)
        assert.are.same(output, lines_of(vim.api.nvim_get_current_buf()))
        vim.api.nvim_win_close(0, true)
        chat:hide()
    end)

    for _, engine in ipairs({ "builtin", "render-markdown" }) do
        describe(engine .. " engine", function()
            before_each(function()
                Config.options.render = { engine = engine }
            end)

            it("keeps the footer anchor alive and single-line after expand", function()
                local h = History.new(930 + (engine == "builtin" and 0 or 1))
                bash_collapsed(h)
                local b = h._tool_blocks["b1"]
                assert.is_true(end_alive(h, b), "end_extmark alive while collapsed")

                h:_set_tool_block_expanded(b, true)
                assert.is_true(end_alive(h, b), "end_extmark must survive expand")
                assert.is_true(end_is_single_line(h, b), "end_extmark must stay single-line after expand")
            end)

            it("collapses again after being expanded (round-trip)", function()
                local h = History.new(940 + (engine == "builtin" and 0 or 1))
                bash_collapsed(h)
                local b = h._tool_blocks["b1"]
                local buf = h:buf()
                local line_count = vim.api.nvim_buf_line_count(buf)

                h:_set_tool_block_expanded(b, true)
                assert.is_true(b.expanded, "expanded after first toggle")

                local changed = h:_set_tool_block_expanded(b, false)
                assert.is_true(changed, "second toggle (collapse) must report a change")
                assert.is_false(b.expanded, "collapsed after second toggle")
                assert.is_true(end_alive(h, b), "end_extmark alive after round-trip")
                assert.are.equal(
                    line_count,
                    vim.api.nvim_buf_line_count(buf),
                    "folding must not replace transcript lines"
                )
                assert.is_true(#rows_with(buf, "o10") == 1, "complete output remains in buffer")
            end)

            it("round-trips through the cursor-driven toggle_tool_block", function()
                local h = History.new(950 + (engine == "builtin" and 0 or 1))
                bash_collapsed(h)
                local b = h._tool_blocks["b1"]
                local buf = h:buf()

                -- Put the buffer in a window so toggle_tool_block can read a cursor.
                vim.api.nvim_win_set_buf(0, buf)
                h:set_win(0)

                local function cursor_on_header()
                    local hr = vim.api.nvim_buf_get_extmark_by_id(buf, h:ns(), b.icon_extmark, {})[1]
                    vim.api.nvim_win_set_cursor(0, { hr + 1, 0 })
                end

                cursor_on_header()
                assert.is_true(h:toggle_tool_block(), "expand via <Tab>")
                assert.is_true(b.expanded)

                cursor_on_header()
                assert.is_true(h:toggle_tool_block(), "collapse via <Tab> must work")
                assert.is_false(b.expanded)
                assert.is_true(#rows_with(buf, "o10") == 1, "complete output remains in buffer")
            end)
        end)
    end
end)
