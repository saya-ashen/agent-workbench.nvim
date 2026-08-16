-- Regression (issue #62): gf / History:goto_path_at_cursor threw
-- E1513 ("Cannot switch buffer. 'winfixbuf' is enabled") when the sessions
-- list window was the only non-chat window in the tab. The target-selection
-- loop filtered π panels by filetype but PI_PANEL_FILETYPES omitted the
-- sessions list filetype, and the loop never checked 'winfixbuf'. These
-- specs pin the window-selection contract: never target a π panel or any
-- winfixbuf-pinned window; fall back to a fresh split otherwise.

local Config = require("agent-workbench.config")
local Ft = require("agent-workbench.filetypes")
local History = require("agent-workbench.ui.chat.history")
local SessionList = require("agent-workbench.ui.sessions")

--- Windows that existed before the test started; restored in after_each.
local base_wins = {}
local saved_agent_dir

--- Create a History whose buffer has a single line holding `path`.
---@param path string
---@return agent_workbench.ChatHistory
local function make_history(path)
    local tab = vim.api.nvim_get_current_tabpage()
    local h = History.new(tab)
    vim.bo[h:buf()].modifiable = true
    vim.api.nvim_buf_set_lines(h:buf(), 0, -1, false, { path })
    vim.bo[h:buf()].modifiable = false
    return h
end

--- Open the history buffer in a side-layout-style window (winfixbuf like
--- the real layout sets) and wire it to the History.
---@param h agent_workbench.ChatHistory
---@return integer win
local function open_history_win(h)
    vim.cmd("topleft vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, h:buf())
    vim.wo[win].winfixbuf = true
    h:set_win(win)
    return win
end

--- Focus the first history line and invoke goto_path_at_cursor.
---@param h agent_workbench.ChatHistory
---@param hist_win integer
---@return boolean ok
---@return boolean? opened
local function goto_first_line(h, hist_win)
    vim.api.nvim_set_current_win(hist_win)
    vim.api.nvim_win_set_cursor(hist_win, { 1, 0 })
    local ok, opened = pcall(function()
        return h:goto_path_at_cursor()
    end)
    return ok, opened
end

describe("goto_path_at_cursor window selection (issue #62)", function()
    local target

    before_each(function()
        base_wins = vim.api.nvim_list_wins()
        saved_agent_dir = Config.options.agent_dir
        Config.options.agent_dir = vim.fn.tempname()

        target = vim.fn.tempname() .. ".txt"
        vim.fn.writefile({ "hello" }, target)
    end)

    after_each(function()
        Config.options.agent_dir = saved_agent_dir
        pcall(SessionList.close)
        SessionList._reset()

        -- Close every window created by the test; keep the originals.
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if not vim.tbl_contains(base_wins, w) then
                pcall(vim.api.nvim_win_close, w, true)
            end
        end
        if #base_wins > 0 and vim.api.nvim_win_is_valid(base_wins[1]) then
            vim.api.nvim_set_current_win(base_wins[1])
        end
    end)

    it("skips the sessions list window and opens a new split (no E1513)", function()
        local h = make_history(target)
        local hist_win = open_history_win(h)

        -- Drop the pre-existing base window so only π windows remain.
        for _, w in ipairs(base_wins) do
            pcall(vim.api.nvim_win_close, w, true)
        end

        SessionList._reset()
        SessionList.open()

        -- Sanity: the sessions window is open and winfixbuf-pinned.
        local sessions_win
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == Ft.sessions then
                sessions_win = w
            end
        end
        assert.is_not_nil(sessions_win, "sessions list window should be open")
        assert.is_true(vim.wo[sessions_win].winfixbuf)
        local sessions_buf = vim.api.nvim_win_get_buf(sessions_win)

        local ok, opened = goto_first_line(h, hist_win)
        assert.is_true(ok, "goto_path_at_cursor must not raise E1513")
        assert.is_true(opened)

        -- The file opened in a fresh window, not in the sessions list.
        assert.is_not_equal(sessions_win, vim.api.nvim_get_current_win())
        assert.equals(target, vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
        -- Sessions window untouched.
        assert.equals(sessions_buf, vim.api.nvim_win_get_buf(sessions_win))
    end)

    it("prefers a plain editor window over the sessions list", function()
        local h = make_history(target)
        local hist_win = open_history_win(h)

        -- Drop the pre-existing base window so only crafted windows remain.
        for _, w in ipairs(base_wins) do
            pcall(vim.api.nvim_win_close, w, true)
        end

        SessionList._reset()
        SessionList.open()

        -- A normal, unpinned editor window. enew: a vsplit inherits the
        -- buffer (and thus filetype) of the window it splits from.
        vim.cmd("botright vsplit")
        local editor_win = vim.api.nvim_get_current_win()
        vim.cmd("enew")

        local ok, opened = goto_first_line(h, hist_win)
        assert.is_true(ok)
        assert.is_true(opened)

        assert.equals(editor_win, vim.api.nvim_get_current_win())
        assert.equals(target, vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
    end)

    it("skips winfixbuf-pinned user windows and opens a new split", function()
        local h = make_history(target)
        local hist_win = open_history_win(h)

        -- Drop the pre-existing base window so only crafted windows remain.
        for _, w in ipairs(base_wins) do
            pcall(vim.api.nvim_win_close, w, true)
        end

        -- A user window pinned by the user or another plugin.
        vim.cmd("botright vsplit")
        local pinned_win = vim.api.nvim_get_current_win()
        vim.cmd("enew")
        local pinned_buf = vim.api.nvim_get_current_buf()
        vim.wo[pinned_win].winfixbuf = true

        local ok, opened = goto_first_line(h, hist_win)
        assert.is_true(ok, "goto_path_at_cursor must not raise E1513")
        assert.is_true(opened)

        assert.is_not_equal(pinned_win, vim.api.nvim_get_current_win())
        assert.equals(target, vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
        -- Pinned window untouched.
        assert.equals(pinned_buf, vim.api.nvim_win_get_buf(pinned_win))
    end)
end)
