-- Session list (:PiSessions) help overlay: `?` toggles a non-focusable float
-- listing the list's shortcuts; it closes with the list window and is
-- per-tab-window like the list itself.

local SessionList = require("pi.ui.sessions")

--- Find the help float: a pi-dialog buffer showing the session list shortcuts.
---@return integer?, integer?
local function find_help_win()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "pi-dialog" then
            local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            if text:find("Toggle this help", 1, true) then
                return win, buf
            end
        end
    end
    return nil, nil
end

--- Press `?` in the current window through the real key path.
local function press_question()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("?", true, false, true), "x", false)
end

--- Count help overlays among open windows.
---@return integer
local function count_help_wins()
    local count = 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "pi-dialog" then
            local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            if text:find("Toggle this help", 1, true) then
                count = count + 1
            end
        end
    end
    return count
end

describe("session list help overlay", function()
    before_each(function()
        SessionList._reset()
        SessionList.open()
    end)

    after_each(function()
        pcall(SessionList.close)
        SessionList._reset()
    end)

    it("binds ? in the list buffer", function()
        local map = vim.fn.maparg("?", "n", false, true)
        assert.equals(1, map.buffer)
        assert.equals("Toggle help", map.desc)
    end)

    it("opens a non-focusable float listing the shortcuts", function()
        local before = vim.api.nvim_get_current_win()
        press_question()

        local win, buf = find_help_win()
        assert.is_not_nil(win)
        -- The overlay must not steal focus from the list.
        assert.equals(before, vim.api.nvim_get_current_win())

        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        for _, key in ipairs({ "<CR>, o", "r", "R", "q", "?" }) do
            assert.is_truthy(text:find(key, 1, true), "help should list " .. key)
        end
        assert.is_truthy(text:find("Rename the session under the cursor", 1, true), "help should describe rename")
        assert.is_truthy(text:find("Refresh the list", 1, true), "help should describe refresh")
    end)

    it("binds r to rename and R to refresh in the list buffer", function()
        local rename = vim.fn.maparg("r", "n", false, true)
        assert.equals(1, rename.buffer)
        assert.equals("Rename this session", rename.desc)
        local refresh = vim.fn.maparg("R", "n", false, true)
        assert.equals(1, refresh.buffer)
        assert.equals("Refresh session list", refresh.desc)
    end)

    it("closes the overlay on a second ?", function()
        press_question()
        assert.is_not_nil(find_help_win())

        press_question()
        assert.is_nil(find_help_win())
    end)

    it("closes the overlay together with the list window", function()
        press_question()
        assert.is_not_nil(find_help_win())

        SessionList.close()
        assert.is_nil(find_help_win())
    end)

    it("gives each window on the shared buffer its own overlay", function()
        press_question()
        local first = find_help_win()
        assert.is_not_nil(first)

        -- A second window on the shared list buffer stands in for another
        -- tab's view of the list.
        vim.cmd("vsplit")
        local second_list_win = vim.api.nvim_get_current_win()
        press_question()
        assert.equals(2, count_help_wins())

        -- Closing the second window closes only its overlay.
        vim.api.nvim_win_close(second_list_win, true)
        assert.equals(1, count_help_wins())

        vim.api.nvim_win_close(first, true)
        assert.equals(0, count_help_wins())
    end)
end)
