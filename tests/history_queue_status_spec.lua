-- Tests for history-side live status rendering:
-- * busy spinner and pending queue render after latest output, with no bottom
--   padding and no whole-buffer scans on the hot path (G22);
-- * busy display model and queue count are also pushed to listeners.

local Config = require("agent-workbench.config")
local History = require("agent-workbench.ui.chat.history")

local ns = vim.api.nvim_create_namespace("pi-chat")
local TAB = 960

local function pump(ms)
    vim.wait(ms or 30)
end

describe("history queue status rendering", function()
    local saved_spinner

    before_each(function()
        saved_spinner = Config.options.spinner
    end)

    after_each(function()
        Config.options.spinner = saved_spinner
    end)

    local function setup_history(line_count)
        local h = History.new(TAB)
        vim.api.nvim_win_set_buf(0, h:buf())
        h:set_win(0)
        if line_count and line_count > 1 then
            h:_with_modifiable(function()
                local lines = {}
                for i = 1, line_count do
                    lines[i] = "line " .. i
                end
                vim.api.nvim_buf_set_lines(h:buf(), 0, -1, false, lines)
            end)
        end
        return h
    end

    local function status_virt_lines(h)
        local marks = vim.api.nvim_buf_get_extmarks(h:buf(), ns, 0, -1, { details = true })
        for _, m in ipairs(marks) do
            if m[4].virt_lines then
                return m[4].virt_lines, m[2]
            end
        end
        return nil
    end

    it("renders busy status after latest output", function()
        Config.options.spinner = { refresh_rate = 1000, frames = { "x" } }
        local h = setup_history(5)
        h:set_status({ type = "agent", text = "Working…" })
        pump(50)
        local virt_lines, anchor_row = status_virt_lines(h)
        assert.is_not_nil(virt_lines)
        assert.are.equal(vim.api.nvim_buf_line_count(h:buf()) - 1, anchor_row)
        assert.are.equal(2, #virt_lines) -- 1 divider + 1 busy row
        local divider = ""
        for _, chunk in ipairs(virt_lines[1]) do
            divider = divider .. chunk[1]
        end
        assert.is_not_nil(divider:find("─", 1, true))
        local text = ""
        for _, chunk in ipairs(virt_lines[2]) do
            text = text .. chunk[1]
        end
        assert.is_not_nil(text:find("x  Working…", 1, true))

        h:set_status(nil)
        pump(50)
        assert.is_nil(status_virt_lines(h))
        assert.are.equal(0, h._status_virt_line_count)
    end)

    it("opens active folds only on output transitions", function()
        Config.options.spinner = { refresh_rate = 1000, frames = { "x" } }
        local h = setup_history(5)
        local anchor = vim.api.nvim_buf_set_extmark(h:buf(), h:ns(), 0, 0, {})
        h._message_blocks = { { anchor = anchor, role = "assistant" } }
        h._active_fold_anchors[1] = anchor
        pump(20) -- let set_win() finish its deferred fold setup
        vim.wo.foldmethod = "manual"
        vim.cmd("1,5fold")
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        assert.are.equal(1, vim.fn.foldclosed(1))

        h._status_text = "Working…"
        h:_update_status_extmark()

        assert.are.equal(1, vim.fn.foldclosed(1), "status refresh must not mutate folds")
        h:_open_active_output_folds()
        assert.are.equal(-1, vim.fn.foldclosed(1), "output transition opens the active fold")
        local _, status_row = status_virt_lines(h)
        assert.are.equal(vim.api.nvim_buf_line_count(h:buf()) - 1, status_row)

        h._status_text = nil
        h:_update_status_extmark()
        vim.wo.foldmethod = "expr"
    end)

    it("does not rewrite unchanged status extmarks", function()
        Config.options.spinner = { refresh_rate = 1000, frames = { "x" } }
        local h = setup_history(5)
        h._status_text = "Working…"
        h:_update_status_extmark()

        local orig = vim.api.nvim_buf_set_extmark
        local calls = 0
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.api.nvim_buf_set_extmark = function(...)
            calls = calls + 1
            return orig(...)
        end
        local ok = pcall(function()
            h:_update_status_extmark()
            h:_update_status_extmark()
        end)
        vim.api.nvim_buf_set_extmark = orig
        assert.is_true(ok)
        assert.are.equal(0, calls)

        h._status_text = nil
        h:_update_status_extmark()
    end)

    it("never calls nvim_win_text_height on the append hot path (G22)", function()
        local h = setup_history(200)
        h:set_status({ type = "agent", text = "Working…" })
        pump(50)

        local orig = vim.api.nvim_win_text_height
        local calls = 0
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.api.nvim_win_text_height = function(...)
            calls = calls + 1
            return orig(...)
        end
        local ok = pcall(function()
            h:_append_lines({ "streamed" })
            h:_update_status_extmark()
        end)
        vim.api.nvim_win_text_height = orig
        assert.is_true(ok)
        assert.are.equal(0, calls)
    end)

    it("follows streamed text without recentering the viewport", function()
        local h = setup_history(50)
        local original_height = vim.api.nvim_win_get_height(0)
        vim.api.nvim_win_set_height(0, 10)
        h:_scroll_to_bottom()
        local original_top = vim.fn.line("w0")

        local forced_scrolls = 0
        h._scroll_to_bottom = function()
            forced_scrolls = forced_scrolls + 1
        end

        h:_append_text(" streamed")
        assert.are.equal(original_top, vim.fn.line("w0"), "same-line text must not move the viewport")

        h:_append_text("\nstreamed one\nstreamed two")
        assert.are.equal(original_top + 2, vim.fn.line("w0"), "new lines should push old lines upward")
        assert.are.equal(vim.api.nvim_buf_line_count(h:buf()), vim.fn.line("w$"))
        assert.are.equal(0, forced_scrolls)
        pump(30)
        assert.are.equal(0, forced_scrolls, "streaming must not queue a forced recenter")
        vim.api.nvim_win_set_height(0, original_height)
    end)

    it("keeps status virtual lines visible below streamed output", function()
        Config.options.spinner = { refresh_rate = 1000, frames = { "x" } }
        local h = setup_history(50)
        local original_height = vim.api.nvim_win_get_height(0)
        vim.api.nvim_win_set_height(0, 10)
        h:set_status({ type = "agent", text = "Working…" })
        pump(30)
        vim.api.nvim_win_call(0, function()
            vim.cmd("normal! G$zb")
        end)

        h:_follow_stream_bottom()

        local height = vim.api.nvim_win_get_height(0)
        assert.are.equal(2, h._status_virt_line_count)
        assert.is_true((height - vim.fn.winline()) >= h._status_virt_line_count)
        local top = vim.fn.line("w0")
        h:_follow_stream_bottom()
        assert.are.equal(top, vim.fn.line("w0"), "visible status rows must not trigger repeated scrolling")

        h:set_status(nil)
        vim.api.nvim_win_set_height(0, original_height)
    end)

    it("does not pin streamed text after the user scrolls up", function()
        local h = setup_history(50)
        local original_height = vim.api.nvim_win_get_height(0)
        vim.api.nvim_win_set_height(0, 10)
        vim.api.nvim_win_call(0, function()
            vim.cmd("normal! ggzt")
        end)

        local follows = 0
        h._follow_stream_bottom = function()
            follows = follows + 1
        end
        h:_append_text("\nstreamed")

        assert.are.equal(0, follows)
        vim.api.nvim_win_set_height(0, original_height)
    end)

    it("does not follow streamed text when the cursor leaves the final line", function()
        local h = setup_history(50)
        local original_height = vim.api.nvim_win_get_height(0)
        vim.api.nvim_win_set_height(0, 10)
        h:_scroll_to_bottom()
        vim.api.nvim_win_set_cursor(0, { 45, 0 })

        assert.are.equal(50, vim.fn.line("w$"), "the latest output is still visible")
        h:_append_text("\nstreamed")

        assert.are.equal(45, vim.api.nvim_win_get_cursor(0)[1])
        vim.api.nvim_win_set_height(0, original_height)
    end)

    it("cancels a queued auto-scroll after the cursor moves", function()
        local h = setup_history(50)
        local original_height = vim.api.nvim_win_get_height(0)
        vim.api.nvim_win_set_height(0, 10)
        h:_scroll_to_bottom()

        h:_maybe_scroll()
        vim.api.nvim_win_set_cursor(0, { 45, 0 })
        pump()

        assert.are.equal(45, vim.api.nvim_win_get_cursor(0)[1])
        vim.api.nvim_win_set_height(0, original_height)
    end)

    it("keeps following structural output when the cursor remains at the end", function()
        local h = setup_history(50)
        local original_height = vim.api.nvim_win_get_height(0)
        vim.api.nvim_win_set_height(0, 10)
        h:_scroll_to_bottom()

        h:_append_lines({ "structural one", "structural two" })
        pump()

        assert.are.equal(52, vim.api.nvim_win_get_cursor(0)[1])
        vim.api.nvim_win_set_height(0, original_height)
    end)

    it("does not force the cursor down for a compaction summary", function()
        local h = setup_history(50)
        local original_height = vim.api.nvim_win_get_height(0)
        vim.api.nvim_win_set_height(0, 10)
        h:_scroll_to_bottom()
        vim.api.nvim_win_set_cursor(0, { 45, 0 })

        h:_append_compaction_summary("summary", 100)
        pump()

        assert.are.equal(45, vim.api.nvim_win_get_cursor(0)[1])
        vim.api.nvim_win_set_height(0, original_height)
    end)

    it("scrolls to the final screen row of wrapped output", function()
        local h = setup_history(1)
        local text = string.rep("wrapped output ", 20)
        h:_with_modifiable(function()
            vim.api.nvim_buf_set_lines(h:buf(), 0, -1, false, { text })
        end)
        local original_width = vim.api.nvim_win_get_width(0)
        vim.api.nvim_win_set_width(0, 20)

        h:_scroll_to_bottom()

        assert.are.equal(#text - 1, vim.api.nvim_win_get_cursor(0)[2])
        vim.api.nvim_win_set_width(0, original_width)
    end)

    it("suppresses scrolling until replay finishes", function()
        local h = setup_history(50)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        h._replaying = true

        h:_scroll_to_bottom()
        assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])

        h._replaying = false
        h:scroll_to_bottom()
        assert.are.equal(50, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("renders a divider plus one row per queue entry", function()
        local h = setup_history(3)
        h:add_pending_queue_entry("follow_up", "first queued", "first queued")
        h:add_pending_queue_entry("steer", "second queued", "second queued")
        local virt_lines = status_virt_lines(h)
        assert.is_not_nil(virt_lines)
        assert.are.equal(3, #virt_lines) -- 1 divider + 2 rows
        local row_text = ""
        for _, chunk in ipairs(virt_lines[2]) do
            row_text = row_text .. chunk[1]
        end
        assert.is_not_nil(row_text:find("first queued", 1, true))

        h:remove_pending_queue_entry("first queued")
        virt_lines = status_virt_lines(h)
        assert.are.equal(2, #virt_lines) -- 1 divider + 1 row

        h:clear_pending_queue()
        assert.is_nil(status_virt_lines(h))
    end)

    it("pushes the busy display model to the status listener", function()
        Config.options.spinner = { refresh_rate = 10, frames = { "a", "b", "c" } }
        local h = setup_history(3)
        -- NB: models[#models + 1] = nil would be a no-op, so mark clears.
        ---@type (agent_workbench.StatusLineBusy|string)[]
        local models = {}
        h:set_status_listener(function(model)
            models[#models + 1] = model or "CLEARED"
        end)

        h:set_status({ type = "agent", text = "Working…" })
        pump(50)
        assert.is_true(#models >= 1)
        assert.are.equal("Working…", models[1].text)
        assert.are.equal("a", models[1].frame)
        assert.is_false(models[1].thinking)

        -- Spinner ticks push updated frames.
        vim.wait(60)
        assert.is_true(#models >= 2)

        h:set_status(nil)
        pump(50)
        assert.are.equal("CLEARED", models[#models])
    end)

    it("marks the busy model as thinking during thinking blocks", function()
        local h = setup_history(3)
        ---@type agent_workbench.StatusLineBusy?[]
        local models = {}
        h:set_status_listener(function(model)
            models[#models + 1] = model
        end)
        h:set_status({ type = "agent", text = "Working…" })
        pump(50)

        h:on_thinking_start()
        pump(50)
        assert.is_true(models[#models].thinking)

        h:on_thinking_end()
        pump(50)
        assert.is_false(models[#models].thinking)
    end)

    it("pushes queue counts to the queue listener", function()
        local h = setup_history(3)
        local counts = {}
        h:set_queue_listener(function(count)
            counts[#counts + 1] = count
        end)
        h:add_pending_queue_entry("follow_up", "one", "one")
        h:add_pending_queue_entry("steer", "two", "two")
        h:remove_pending_queue_entry("one")
        h:clear_pending_queue()
        assert.are.same({ 1, 2, 1, 0 }, counts)
    end)

    it("leaves a one-blank margin after the thinking header (breathing line)", function()
        Config.options.show_thinking = true
        -- Case 1: buffer ends with a breathing blank — it becomes the single
        -- trailing blank, and the breathing flag is set so the next text delta
        -- prepends a newline, leaving exactly one blank of separation (#48).
        local h = setup_history(1)
        h:on_thinking_start()
        pump(50)
        local lines = vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
        assert.are.equal(3, #lines) -- lead blank, header, one trailing blank
        assert.are.equal("", lines[1])
        assert.is_true(lines[2] ~= "", "thinking header line")
        assert.are.equal("", lines[3])
        assert.is_true(h._needs_breathing_line, "breathing flag set for the next block")

        -- The next text delta goes through the breathing path (_render_text_deltas
        -- prepends a newline), so exactly one blank line stays after the header.
        h:_render_text_deltas("answer")
        lines = vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
        assert.are.equal(4, #lines)
        assert.are.equal("", lines[3])
        assert.are.equal("answer", lines[4])

        -- Case 2: buffer ends with real content (e.g. an inline tool) — one
        -- trailing blank is inserted after the header.
        local h2 = setup_history(1)
        h2:_with_modifiable(function()
            vim.api.nvim_buf_set_lines(h2:buf(), 0, -1, false, { "read tool output" })
        end)
        h2:on_thinking_start()
        pump(50)
        lines = vim.api.nvim_buf_get_lines(h2:buf(), 0, -1, false)
        assert.are.equal(4, #lines) -- content, lead blank, header, one trailing blank
        assert.are.equal("", lines[2])
        assert.is_true(lines[3] ~= "", "thinking header line")
        assert.are.equal("", lines[4])
        assert.is_true(h2._needs_breathing_line)
    end)
end)
