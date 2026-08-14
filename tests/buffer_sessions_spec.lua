local Config = require("pi.config")
local Ft = require("pi.filetypes")
local Rpc = require("pi.rpc")
local SessionHistory = require("pi.sessions.history")
local Sessions = require("pi.sessions.manager")
local Workspace = require("pi.workspace")
local WorkspaceBuffers = require("pi.workspace_buffers")

Config.setup({})

local real_rpc = { start = Rpc.start, stop = Rpc.stop, send = Rpc.send }
local real_history = { list = SessionHistory.list, load_messages = SessionHistory.load_messages }

local function install_stub()
    Rpc.start = function(self)
        self._job_id = self._tab
        return true
    end
    Rpc.stop = function(self)
        self._job_id = nil
        self._pending = {}
    end
    Rpc.send = function(self, _, _)
        return self._job_id ~= nil
    end
end

local function restore_stub()
    Sessions._reset()
    Rpc.start = real_rpc.start
    Rpc.stop = real_rpc.stop
    Rpc.send = real_rpc.send
    SessionHistory.list = real_history.list
    SessionHistory.load_messages = real_history.load_messages
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == Ft.history then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end
end

---@return table[] pending
local function install_pending_rpc()
    local pending = {}
    Rpc.send = function(self, msg, callback)
        pending[#pending + 1] = { rpc = self, msg = msg, callback = callback }
        return self._job_id ~= nil
    end
    return pending
end

---@param pending table[]
---@param rpc pi.Rpc
---@param command string
---@return table
local function take_pending(pending, rpc, command)
    for i, entry in ipairs(pending) do
        if entry.rpc == rpc and entry.msg.type == command then
            table.remove(pending, i)
            return entry
        end
    end
    error("missing pending " .. command)
end

---@param pending table[]
local function clear_pending(pending)
    for i = #pending, 1, -1 do
        table.remove(pending, i)
    end
end

describe("buffer-owned sessions", function()
    before_each(function()
        install_stub()
        Sessions.setup_autocmds()
    end)

    after_each(function()
        WorkspaceBuffers._reset()
        restore_stub()
    end)

    it("switches full chat view when a listed History buffer is entered", function()
        local first = assert(Sessions.get_or_create({ layout = "buffer" }))
        local second = assert(Sessions.get_or_create({ new = true, layout = "buffer" }))
        vim.wait(20)

        assert.is_true(vim.bo[first.history_buf].buflisted)
        assert.is_true(vim.bo[second.history_buf].buflisted)
        assert.is_true(first.rpc:is_running())
        assert.is_true(second.rpc:is_running())
        assert.are.equal(second, Sessions.get())
        assert.is_true(second.chat:is_visible())
        assert.is_false(first.chat:is_visible())

        local second_prompt_win = second.chat:prompt_win()
        assert.is_not_nil(second_prompt_win)
        vim.api.nvim_set_current_win(second_prompt_win)
        vim.cmd("buffer " .. first.history_buf)
        vim.wait(100, function()
            local history_win = first.chat._layout:history_win()
            return history_win ~= nil
                and vim.api.nvim_win_get_buf(history_win) == first.history_buf
                and vim.api.nvim_get_current_win() == history_win
        end)

        assert.are.equal(first, Sessions.get())
        assert.is_true(first.chat:is_visible())
        assert.is_false(second.chat:is_visible())
        local history_win = first.chat._layout:history_win()
        local prompt_win = first.chat:prompt_win()
        assert.is_not_nil(history_win)
        assert.is_not_nil(prompt_win)
        assert.are.equal(first.history_buf, vim.api.nvim_win_get_buf(history_win))
        assert.are.equal(history_win, vim.api.nvim_get_current_win())
        assert.is_not.equal("i", vim.api.nvim_get_mode().mode)
        assert.are.equal(first.chat:prompt_buf(), vim.api.nvim_win_get_buf(prompt_win))
        assert.is_true(first.rpc:is_running())
        assert.is_true(second.rpc:is_running())
    end)

    it("keeps prompt navigation and zen layout Normal unless a History insert key is used", function()
        local session = assert(Sessions.get_or_create({ layout = "buffer" }))
        local history_win = assert(session.chat._layout:history_win())
        local prompt_win = assert(session.chat:prompt_win())

        session.chat:focus_history()
        vim.wait(100, function()
            return vim.api.nvim_get_current_win() == history_win
        end)
        vim.cmd("wincmd j")
        vim.wait(100, function()
            return vim.api.nvim_get_current_win() == prompt_win
        end)
        assert.is_not.equal("i", vim.api.nvim_get_mode().mode)

        session.chat:focus_history()
        vim.wait(100, function()
            return vim.api.nvim_get_current_win() == history_win
        end)
        session.chat:focus_prompt()
        vim.wait(100, function()
            return vim.api.nvim_get_current_win() == prompt_win
        end)
        assert.is_not.equal("i", vim.api.nvim_get_mode().mode)

        session.chat:zen_toggle()
        assert.is_true(session.chat:zen_active())
        assert.is_not.equal("i", vim.api.nvim_get_mode().mode)
        session.chat:zen_toggle()
        vim.wait(100, function()
            return not session.chat:zen_active() and vim.api.nvim_get_current_win() == prompt_win
        end)
        assert.is_not.equal("i", vim.api.nvim_get_mode().mode)

        local insert_callback
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(session.history_buf, "n")) do
            if map.lhs == "i" then
                insert_callback = map.callback
                break
            end
        end
        assert.is_not_nil(insert_callback)
        local requested_insert
        local ensure_shown = session.chat.ensure_shown_and_focus_prompt
        session.chat.ensure_shown_and_focus_prompt = function(_, insert)
            requested_insert = insert
        end
        insert_callback()
        session.chat.ensure_shown_and_focus_prompt = ensure_shown
        assert.is_true(requested_insert)
    end)

    it("restores History cursor after a same-window buffer round trip", function()
        local session = assert(Sessions.get_or_create({ layout = "buffer" }))
        local history = session.chat:history()
        local history_win = assert(session.chat._layout:history_win())

        session.chat:focus_history()
        assert.is_true(vim.wait(100, function()
            return vim.api.nvim_get_current_win() == history_win
        end))
        local line = vim.api.nvim_buf_get_lines(session.history_buf, 1, 2, false)[1] or ""
        local cursor = { 2, math.min(3, #line) }
        vim.api.nvim_win_set_cursor(history_win, cursor)
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = session.history_buf })
        assert.same(cursor, session.chat._history_cursor)

        local editor_buf = vim.api.nvim_create_buf(true, false)
        vim.cmd("buffer " .. editor_buf)
        vim.wait(100, function()
            return vim.api.nvim_get_current_buf() == editor_buf and not session.chat:is_visible()
        end)
        assert.same(cursor, session.chat._history_cursor)

        local startup_calls = 0
        local show_loading_startup = history.show_loading_startup
        history.show_loading_startup = function(...)
            startup_calls = startup_calls + 1
            return show_loading_startup(...)
        end
        vim.cmd("buffer " .. session.history_buf)
        vim.wait(100, function()
            return vim.api.nvim_get_current_win() == session.chat._layout:history_win()
        end)
        history.show_loading_startup = show_loading_startup

        local restored_history_win = assert(session.chat._layout:history_win())
        assert.same(cursor, vim.api.nvim_win_get_cursor(restored_history_win))
        assert.are.equal(0, startup_calls)
    end)

    it("keeps background reload completion out of the active session view", function()
        local first = assert(Sessions.get_or_create({ layout = "buffer" }))
        local pending = install_pending_rpc()
        Sessions.reload_messages(first)
        vim.wait(20)
        local get_messages = take_pending(pending, first.rpc, "get_messages")

        local second = assert(Sessions.get_or_create({ new = true, layout = "buffer" }))
        clear_pending(pending)
        get_messages.callback({ success = true, data = { messages = {} } })
        vim.wait(40)
        local get_commands = take_pending(pending, first.rpc, "get_commands")
        get_commands.callback({ success = true, data = { commands = {} } })
        vim.wait(40)

        Sessions.handle_event(first, { type = "agent_start" })
        Sessions.handle_event(first, {
            type = "message_update",
            assistantMessageEvent = { type = "text_delta", delta = "background output" },
        })
        vim.wait(40)

        assert.are.equal(second, Sessions.get_for_tab())
        assert.are.equal(second, Sessions.get())
        assert.is_false(first.chat:is_visible())
        assert.is_true(second.chat:is_visible())
        local history_win = second.chat._layout:history_win()
        local prompt_win = second.chat:prompt_win()
        assert.is_not_nil(history_win)
        assert.is_not_nil(prompt_win)
        assert.are.equal(second.history_buf, vim.api.nvim_win_get_buf(history_win))
        assert.are.equal(second.chat:prompt_buf(), vim.api.nvim_win_get_buf(prompt_win))
    end)

    it("blocks prompts until a persisted session finishes switching", function()
        local pending = install_pending_rpc()
        local path = vim.fn.tempname() .. ".jsonl"
        local uri = Workspace.uri(Workspace.cwd(), path, 1)
        local preview = { messages = { { role = "user", content = "persisted message" } } }
        SessionHistory.list = function()
            return { { id = vim.fs.basename(path):gsub("%.jsonl$", ""), path = path } }
        end
        SessionHistory.load_messages = function()
            return preview
        end

        assert.is_true(Sessions.open_uri(uri))
        local session = assert(Sessions.get_for_tab())
        assert.is_true(session._switching_session)
        vim.api.nvim_buf_set_lines(session.chat:prompt_buf(), 0, -1, false, { "new message" })
        session.chat:submit()
        assert.are.equal("new message", session.chat._prompt:text())
        for _, entry in ipairs(pending) do
            assert.are_not.equal("prompt", entry.msg.type)
        end

        local switch = take_pending(pending, session.rpc, "switch_session")
        clear_pending(pending)
        switch.callback({ success = true, data = { cancelled = false } })
        local messages = take_pending(pending, session.rpc, "get_messages")
        clear_pending(pending)
        messages.callback({ success = true, data = preview })
        vim.wait(40)

        local prompt_win = assert(session.chat:prompt_win())
        assert.are.equal(prompt_win, vim.api.nvim_get_current_win())
        assert.are.equal(session.chat:prompt_buf(), vim.api.nvim_win_get_buf(prompt_win))
        assert.is_not.equal("i", vim.api.nvim_get_mode().mode)
        assert.is_false(session._switching_session)
        session.chat:submit()
        assert.are.equal("prompt", take_pending(pending, session.rpc, "prompt").msg.type)
    end)

    it("restarts active session in the new workspace cwd after :tcd", function()
        WorkspaceBuffers.setup()
        local old_cwd = vim.fn.getcwd()
        local new_cwd = vim.fn.tempname()
        vim.fn.mkdir(new_cwd, "p")
        new_cwd = assert(vim.uv.fs_realpath(new_cwd))
        local first = assert(Sessions.get_or_create({ layout = "buffer" }))
        local history_win = assert(first.chat._layout:history_win())
        local prompt_win = assert(first.chat:prompt_win())
        local window_count = #vim.api.nvim_tabpage_list_wins(0)

        vim.cmd("tcd " .. vim.fn.fnameescape(new_cwd))
        vim.wait(100, function()
            local current = Sessions.get()
            return current ~= nil and current ~= first
        end)

        local second = assert(Sessions.get())
        assert.are.equal(new_cwd, second.cwd)
        assert.are.equal(new_cwd, second.rpc._cwd)
        assert.is_false(first.rpc:is_running())
        assert.is_false(vim.list_contains(Sessions.list(), first))
        assert.is_false(vim.api.nvim_buf_is_valid(first.history_buf))
        assert.is_true(second.rpc:is_running())
        assert.is_false(first.chat:is_visible())
        assert.is_true(second.chat:is_visible())
        assert.are.equal(window_count, #vim.api.nvim_tabpage_list_wins(0))
        assert.are.equal(history_win, second.chat._layout:history_win())
        assert.are.equal(second.history_buf, vim.api.nvim_win_get_buf(history_win))
        assert.are.equal(prompt_win, second.chat:prompt_win())
        assert.are.equal(second.chat:prompt_buf(), vim.api.nvim_win_get_buf(prompt_win))
        assert.is_true(#vim.api.nvim_buf_get_lines(second.history_buf, 0, -1, false) > 1)

        if vim.api.nvim_buf_is_valid(second.history_buf) then
            vim.api.nvim_buf_delete(second.history_buf, { force = true })
        end
        vim.cmd("tcd " .. vim.fn.fnameescape(old_cwd))
        vim.fn.delete(new_cwd, "rf")
    end)

    it("keeps a running session in its original workspace cwd", function()
        local old_cwd = vim.fn.getcwd()
        local new_cwd = vim.fn.tempname()
        vim.fn.mkdir(new_cwd, "p")
        new_cwd = assert(vim.uv.fs_realpath(new_cwd))
        local session = assert(Sessions.get_or_create({ layout = "buffer" }))
        for _, state in ipairs({ "_streaming", "_compacting", "_retrying", "_bash_running" }) do
            session.chat._streaming = false
            session.chat._compacting = false
            session.chat._retrying = false
            session.chat._bash_running = false
            session.chat[state] = true

            vim.cmd("tcd " .. vim.fn.fnameescape(new_cwd))

            assert.are.equal(old_cwd, vim.fn.getcwd())
            assert.are.equal(session, Sessions.get())
            assert.is_true(session.rpc:is_running())
        end
        vim.fn.delete(new_cwd, "rf")
    end)

    it("rebinds session ownership when a persisted URI attaches a new History", function()
        WorkspaceBuffers.setup()
        local History = require("pi.ui.chat.history")
        local session = assert(Sessions.get_or_create({ layout = "buffer" }))
        local old_buf = session.history_buf
        local history = History.new(session.id, "agent://test/rebound/transcript", 999)
        local new_buf = history:buf()

        Sessions._rebind_history(session, history)

        assert.are.equal(new_buf, session.history_buf)
        assert.are.equal("agent://test/rebound/transcript", session.uri)
        assert.are.equal(session, Sessions.get())
        assert.is_nil(vim.b[old_buf].pi_session_id)
        assert.are.equal(session.id, vim.b[new_buf].pi_session_id)
        assert.is_false(WorkspaceBuffers._contains(old_buf, session.workspace_tab))
        assert.is_true(WorkspaceBuffers._contains(new_buf, session.workspace_tab))
        assert.is_true(vim.api.nvim_buf_is_valid(old_buf))
        vim.api.nvim_buf_delete(old_buf, { force = true })
    end)

    it("stops current session when its visible History buffer is deleted", function()
        local session = assert(Sessions.get_or_create({ layout = "buffer" }))
        local history_win = session.chat._layout:history_win()
        assert.is_not_nil(history_win)
        vim.api.nvim_set_current_win(history_win)
        vim.cmd("bdelete! " .. session.history_buf)
        vim.wait(20)

        assert.is_false(session.rpc:is_running())
        assert.are.equal(0, #Sessions.list())
        assert.is_true(vim.api.nvim_win_is_valid(vim.api.nvim_get_current_win()))
    end)

    it("stops only session whose History buffer is deleted", function()
        local first = assert(Sessions.get_or_create({ layout = "buffer" }))
        local second = assert(Sessions.get_or_create({ new = true, layout = "buffer" }))
        vim.api.nvim_buf_delete(first.history_buf, { force = true })
        vim.wait(20)

        assert.is_false(first.rpc:is_running())
        assert.is_true(second.rpc:is_running())
        assert.are.equal(1, #Sessions.list())
        assert.are.equal(second, Sessions.list()[1])
    end)

    it("keeps a session running when its History is hidden by another workspace", function()
        WorkspaceBuffers.setup()
        local session = assert(Sessions.get_or_create({ layout = "buffer" }))
        vim.cmd("tabnew")
        local other_tab = vim.api.nvim_get_current_tabpage()
        vim.wait(20)

        assert.is_false(WorkspaceBuffers._contains(session.history_buf, other_tab))
        assert.is_true(session.rpc:is_running())
        assert.is_true(vim.list_contains(Sessions.list(), session))

        vim.api.nvim_buf_delete(session.history_buf, { force = true })
        vim.wait(20)
        assert.is_false(session.rpc:is_running())
    end)
end)
