-- Unit tests for pi.ui.chat.statusline: center group placement, spinner/queue
-- components, abort priority chain, and the G22 pad-scan gate.

local Config = require("pi.config")
local StatusLine = require("pi.ui.chat.statusline")

local ns = vim.api.nvim_create_namespace("pi-statusline")

describe("statusline", function()
    local buf
    local sl
    local saved_statusline_cfg

    before_each(function()
        saved_statusline_cfg = Config.options.statusline
        Config.options.statusline = vim.tbl_deep_extend("force", {}, saved_statusline_cfg, { enabled = true })
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        sl = StatusLine.new(buf, 1, function()
            return 0
        end)
    end)

    after_each(function()
        Config.options.statusline = saved_statusline_cfg
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    --- Concatenated text of the status row (last virt_line of the extmark).
    local function status_row()
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        assert.are.equal(1, #marks, "expected exactly one statusline extmark")
        local virt_lines = marks[1][4].virt_lines
        assert.is_table(virt_lines)
        local row = virt_lines[#virt_lines]
        local text = ""
        for _, chunk in ipairs(row) do
            text = text .. chunk[1]
        end
        return text, row
    end

    local function busy_model(overrides)
        local m = { frame = "-", text = "Working…", elapsed = "", thinking = false }
        if overrides then
            for k, v in pairs(overrides) do
                m[k] = v
            end
        end
        return m
    end

    it("hides the spinner component when idle", function()
        local text = status_row()
        assert.is_nil(text:find("Working", 1, true))
    end)

    it("renders the busy spinner centered", function()
        sl:set_busy(busy_model())
        local text = status_row()
        local body = "-  Working…"
        local s = text:find(body, 1, true)
        assert.is_not_nil(s, "spinner text should be present")
        local width = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].width
        local expect = math.floor((width - vim.fn.strdisplaywidth(body)) / 2)
        assert.are.equal(expect, s - 1)
    end)

    it("renders elapsed time and thinking suffix as separate chunks", function()
        sl:set_busy(busy_model({ elapsed = " 12s", thinking = true }))
        local text = status_row()
        assert.is_not_nil(text:find(" 12s", 1, true))
        assert.is_not_nil(text:find(Config.options.labels.thinking, 1, true))
    end)

    it("clears the spinner when busy becomes nil", function()
        sl:set_busy(busy_model())
        sl:set_busy(nil)
        local text = status_row()
        assert.is_nil(text:find("Working", 1, true))
    end)

    it("abort hint replaces the spinner; aborted notice outranks both", function()
        sl:set_busy(busy_model())
        sl:set_abort_hint("Press <Esc> again to abort")
        local text = status_row()
        assert.is_not_nil(text:find("Press <Esc>", 1, true))
        assert.is_nil(text:find("Working", 1, true))

        sl:set_aborted_notice("Aborted")
        text = status_row()
        assert.is_not_nil(text:find("Aborted", 1, true))
        assert.is_nil(text:find("Press <Esc>", 1, true))

        sl:clear_aborted_notice()
        text = status_row()
        assert.is_not_nil(text:find("Press <Esc>", 1, true))

        sl:clear_abort_hint()
        text = status_row()
        assert.is_not_nil(text:find("Working", 1, true))
    end)

    it("keeps abort feedback when expanded statusline is disabled", function()
        Config.options.statusline.enabled = false
        sl:render()
        assert.are.equal(0, sl:virt_line_count())

        sl:set_abort_hint("Press <Esc> again to abort")
        assert.is_not_nil(status_row():find("Press <Esc>", 1, true))

        sl:clear_abort_hint()
        assert.are.equal(0, sl:virt_line_count())
    end)

    it("shows the queue count only when non-zero", function()
        assert.is_nil(status_row():find("⏵", 1, true))
        sl:set_queue_count(2)
        local text = status_row()
        assert.is_not_nil(text:find("⏵ 2", 1, true))
        sl:set_queue_count(0)
        assert.is_nil(status_row():find("⏵", 1, true))
    end)

    it("center wins over a wide left group (left is truncated)", function()
        Config.options.statusline = vim.tbl_deep_extend("force", {}, saved_statusline_cfg, {
            enabled = true,
            layout = {
                left = {
                    function()
                        return string.rep("L", 70)
                    end,
                },
            },
        })
        sl:set_busy(busy_model())
        local text = status_row()
        local body = "-  Working…"
        local s = text:find(body, 1, true)
        assert.is_not_nil(s)
        -- Left group must end at least min_gap columns before the center start.
        local left_end = text:find("[^L ]")
        local l_run_end = 0
        for i = 1, #text do
            if text:sub(i, i) == "L" then
                l_run_end = i
            end
        end
        assert.is_true(l_run_end > 0, "some of the left group should remain")
        assert.is_true(l_run_end < s - 1, "left must be truncated before the center group")
        assert(left_end or true)
    end)

    it("skips nvim_win_text_height when prompt lines fill the window (G22)", function()
        local text_rows = vim.api.nvim_win_get_height(0)
        local lines = {}
        for i = 1, text_rows + 10 do
            lines[i] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

        local orig = vim.api.nvim_win_text_height
        local calls = 0
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.api.nvim_win_text_height = function(...)
            calls = calls + 1
            return orig(...)
        end
        local ok = pcall(function()
            sl:set_busy(busy_model())
        end)
        vim.api.nvim_win_text_height = orig
        assert.is_true(ok)
        assert.are.equal(0, calls)
    end)
end)
