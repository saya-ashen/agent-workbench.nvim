-- Regression: a tool block must round-trip through native folds without
-- replacing transcript lines. Complete output stays addressable in buffer;
-- fold state only controls window visibility.

local Config = require("pi.config")
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

local function bash_collapsed(h, tab_id)
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
