local Rpc = require("agent-workbench.rpc")

Rpc.start = function(self)
    self._job_id = 1
    return true
end
Rpc.send = function(self, _, callback)
    if callback then
        callback({ type = "response", success = true, data = {} })
    end
    return true
end
Rpc.stop = function(self)
    self._job_id = nil
    self._pending = {}
end

local ok, err = pcall(function()
    require("agent-workbench").setup({
        auto_start_session = false,
        keymaps = { preset = "recommended" },
    })
    assert(vim.fn.exists(":AgentWorkbenchReplaceSession") == 2, "replace command missing")
    assert(vim.fn.maparg("<Leader>aw", "n", false, true).desc == "Agent Workbench: pick workspace", "keymap missing")
    assert(
        vim.fn.maparg("<Leader>aW", "n", false, true).desc == "Agent Workbench: create workspace",
        "create workspace keymap missing"
    )
    assert(vim.fn.maparg("<M-h>", "n", false, true).desc == "Agent Workbench: previous buffer", "buffer keymap missing")

    local original_win = vim.api.nvim_get_current_win()
    local original_buf = vim.api.nvim_get_current_buf()
    vim.wo[original_win].winfixbuf = true
    local leader = vim.g.mapleader or "\\"
    local keys = vim.api.nvim_replace_termcodes(leader .. "aa", true, false, true)
    vim.api.nvim_feedkeys(keys, "xt", false)
    local Sessions = require("agent-workbench.sessions.manager")
    assert(
        vim.wait(500, function()
            return Sessions.get() ~= nil
        end),
        "recommended new-session keymap did not create a session"
    )
    local session = assert(Sessions.get(), "session missing")
    local history_win = assert(session.chat._layout:history_win(), "History window missing")
    assert(history_win ~= original_win, "History replaced the pinned window")
    assert(vim.api.nvim_win_get_buf(original_win) == original_buf, "pinned buffer changed")
    assert(vim.wo[original_win].winfixbuf, "pinned window was unpinned")
    session.chat:hide()
    assert(not vim.api.nvim_win_is_valid(history_win), "fallback History window was not closed")
    assert(vim.api.nvim_get_current_win() == original_win, "focus did not return to pinned window")
    vim.wo[original_win].winfixbuf = false

    require("agent-workbench").show({ layout = "side" })
    session = assert(Sessions.get(), "session missing")
    assert(vim.api.nvim_buf_is_valid(session.history_buf), "History buffer missing")
    assert(vim.api.nvim_buf_is_valid(session.chat:prompt_buf()), "prompt buffer missing")
end)

if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd("cq 1")
else
    vim.cmd("qa!")
end
