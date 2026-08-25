local Config = require("agent-workbench.config")
local Ft = require("agent-workbench.filetypes")
local Rpc = require("agent-workbench.rpc")
local SessionHistory = require("agent-workbench.sessions.history")
local Sessions = require("agent-workbench.sessions.manager")
local Workspace = require("agent-workbench.workspace")
local WorkspaceBuffers = require("agent-workbench.workspace_buffers")

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
---@param rpc agent_workbench.Rpc
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
    local original_render

    before_each(function()
        original_render = vim.deepcopy(Config.options.render)
        Config.options.render = { markdown = { enabled = false } }
        install_stub()
        Sessions.setup_autocmds()
    end)

    after_each(function()
        Config.options.render = original_render
        WorkspaceBuffers._reset()
        restore_stub()
    end)

    it("does not create a session when a workspace tab opens by default", function()
        assert.is_false(Config.options.auto_start_session)
        vim.cmd("tabnew")
        vim.wait(20)
        local current = Sessions.get()
        local count = #Sessions.list()
        vim.cmd("tabclose")

        assert.is_nil(current)
        assert.are.equal(0, count)
    end)

    it("creates a session buffer without replacing a winfixbuf-pinned window", function()
        local original_win = vim.api.nvim_get_current_win()
        local original_buf = vim.api.nvim_get_current_buf()
        vim.wo[original_win].winfixbuf = true

        local ok, err = pcall(Sessions.new_session)
        local session = Sessions.get()
        local history_win = session and session.chat._layout:history_win() or nil
        local original_unchanged = vim.api.nvim_win_get_buf(original_win) == original_buf
        local pin_preserved = vim.wo[original_win].winfixbuf
        local hide_ok, hide_err = true, nil
        if session and session.chat:is_visible() then
            hide_ok, hide_err = pcall(session.chat.hide, session.chat)
        end
        local history_closed = history_win ~= nil and not vim.api.nvim_win_is_valid(history_win)
        local returned_to_original = vim.api.nvim_get_current_win() == original_win
        vim.wo[original_win].winfixbuf = false

        assert.is_true(ok, err)
        assert.is_true(hide_ok, hide_err)
        assert.is_not_nil(session)
        assert.is_not_nil(history_win)
        assert.are_not.equal(original_win, history_win)
        assert.is_true(original_unchanged)
        assert.is_true(pin_preserved)
        assert.is_true(history_closed)
        assert.is_true(returned_to_original)
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

    it("activates a session in its owning workspace", function()
        local owner_tab = vim.api.nvim_get_current_tabpage()
        local first = assert(Sessions.get_or_create({ layout = "buffer" }))

        vim.cmd("tabnew")
        local other_tab = vim.api.nvim_get_current_tabpage()
        local second = assert(Sessions.get_or_create({ layout = "buffer" }))
        vim.wait(20)
        assert.are.equal(other_tab, vim.api.nvim_get_current_tabpage())
        local second_history_win = second.chat._layout:history_win()
        assert.is_not_nil(second_history_win)
        assert.are.equal(second.history_buf, vim.api.nvim_win_get_buf(second_history_win))

        Sessions.activate(first)
        vim.wait(20)

        assert.are.equal(owner_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(first, Sessions.get_for_tab(owner_tab))
        assert.are.equal(second, Sessions.get_for_tab(other_tab))
        local first_history_win = first.chat._layout:history_win()
        local second_history_win_after = second.chat._layout:history_win()
        assert.is_not_nil(first_history_win)
        assert.is_not_nil(second_history_win_after)
        assert.are.equal(first.history_buf, vim.api.nvim_win_get_buf(first_history_win))
        assert.are.equal(second.history_buf, vim.api.nvim_win_get_buf(second_history_win_after))
    end)

    it("ignores incidental background History BufEnter events", function()
        local foreground_tab = vim.api.nvim_get_current_tabpage()
        local foreground = assert(Sessions.get_or_create({ layout = "buffer" }))

        vim.cmd("tabnew")
        local background_tab = vim.api.nvim_get_current_tabpage()
        local background = assert(Sessions.get_or_create({ layout = "buffer" }))
        vim.api.nvim_set_current_tabpage(foreground_tab)
        local foreground_win = vim.api.nvim_get_current_win()
        local foreground_buf = vim.api.nvim_get_current_buf()

        vim.api.nvim_buf_call(background.history_buf, function()
            vim.api.nvim_exec_autocmds("BufEnter", { buffer = background.history_buf, modeline = false })
        end)
        vim.wait(20)

        assert.are.equal(foreground_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(foreground_win, vim.api.nvim_get_current_win())
        assert.are.equal(foreground_buf, vim.api.nvim_get_current_buf())
        assert.are.equal(foreground, Sessions.get_for_tab(foreground_tab))
        assert.are.equal(background, Sessions.get_for_tab(background_tab))
        local foreground_history_win = assert(foreground.chat._layout:history_win())
        local background_history_win = assert(background.chat._layout:history_win())
        assert.are.equal(foreground.history_buf, vim.api.nvim_win_get_buf(foreground_history_win))
        assert.are.equal(background.history_buf, vim.api.nvim_win_get_buf(background_history_win))
        vim.api.nvim_set_current_tabpage(background_tab)
        vim.cmd("tabclose!")
        vim.api.nvim_set_current_tabpage(foreground_tab)
    end)

    it("keeps detached background sessions passive until explicitly activated", function()
        WorkspaceBuffers.setup()
        local foreground_tab = vim.api.nvim_get_current_tabpage()
        local foreground = assert(Sessions.get_or_create({ layout = "buffer" }))

        vim.cmd("tabnew")
        local closed_tab = vim.api.nvim_get_current_tabpage()
        local background = assert(Sessions.get_or_create({ layout = "buffer" }))
        vim.cmd("tabclose!")
        vim.api.nvim_set_current_tabpage(foreground_tab)
        vim.wait(20)
        assert.is_false(vim.api.nvim_tabpage_is_valid(closed_tab))
        local foreground_win = vim.api.nvim_get_current_win()
        local foreground_buf = vim.api.nvim_get_current_buf()

        vim.api.nvim_buf_call(background.history_buf, function()
            vim.api.nvim_exec_autocmds("BufEnter", { buffer = background.history_buf, modeline = false })
        end)
        vim.wait(20)

        assert.are.equal(foreground_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(foreground_win, vim.api.nvim_get_current_win())
        assert.are.equal(foreground_buf, vim.api.nvim_get_current_buf())
        assert.are.equal(foreground, Sessions.get_for_tab(foreground_tab))
        assert.is_false(background.chat:is_visible())

        Sessions.activate(background)
        vim.wait(20)

        assert.are.equal(foreground_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(foreground_tab, background.workspace_tab)
        assert.are.equal(background, Sessions.get_for_tab(foreground_tab))
        assert.is_true(background.chat:is_visible())
        assert.is_false(foreground.chat:is_visible())
        assert.is_true(WorkspaceBuffers._contains(background.history_buf, foreground_tab))
    end)

    it("never enters background History windows while foreground focus is elsewhere", function()
        local foreground_tab = vim.api.nvim_get_current_tabpage()
        local foreground = assert(Sessions.get_or_create({ layout = "buffer" }))

        vim.cmd("tabnew")
        local background_tab = vim.api.nvim_get_current_tabpage()
        local background = assert(Sessions.get_or_create({ layout = "buffer" }))
        vim.api.nvim_set_current_tabpage(foreground_tab)
        local foreground_prompt_win = assert(foreground.chat:prompt_win())
        vim.api.nvim_set_current_win(foreground_prompt_win)

        local real_win_call = vim.api.nvim_win_call
        local cross_tab_calls = {}
        vim.api.nvim_win_call = function(win, callback)
            if
                vim.api.nvim_win_is_valid(win)
                and vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage()
            then
                cross_tab_calls[#cross_tab_calls + 1] = win
            end
            return real_win_call(win, callback)
        end

        local ok, err = pcall(function()
            Sessions.handle_event(background, { type = "agent_start" })
            Sessions.handle_event(background, {
                type = "message_start",
                message = { role = "assistant", content = {}, timestamp = os.time() * 1000 },
            })
            Sessions.handle_event(background, {
                type = "message_update",
                assistantMessageEvent = { type = "text_delta", delta = "background output" },
            })
            vim.wait(200)
        end)
        vim.api.nvim_win_call = real_win_call
        if not ok then
            error(err)
        end

        assert.are.same({}, cross_tab_calls)
        local background_text = table.concat(vim.api.nvim_buf_get_lines(background.history_buf, 0, -1, false), "\n")
        assert.is_truthy(background_text:find("background output", 1, true))
        assert.are.equal(foreground_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(foreground.chat:prompt_buf(), vim.api.nvim_get_current_buf())
        vim.api.nvim_set_current_tabpage(background_tab)
        vim.cmd("tabclose!")
        vim.api.nvim_set_current_tabpage(foreground_tab)
    end)

    it("replaces an idle session in the same view", function()
        local first = assert(Sessions.get_or_create({ layout = "buffer" }))
        local old_history_buf = first.history_buf
        local history_win = assert(first.chat._layout:history_win())
        local prompt_win = assert(first.chat:prompt_win())
        local window_count = #vim.api.nvim_tabpage_list_wins(0)

        Sessions.replace_session()
        vim.wait(20)

        local second = assert(Sessions.get())
        assert.is_not.equal(first, second)
        assert.are.same({ second }, Sessions.list())
        assert.is_false(first.rpc:is_running())
        assert.is_true(second.rpc:is_running())
        assert.is_false(vim.api.nvim_buf_is_valid(old_history_buf))
        assert.are.equal(window_count, #vim.api.nvim_tabpage_list_wins(0))
        assert.are.equal(history_win, second.chat._layout:history_win())
        assert.are.equal(second.history_buf, vim.api.nvim_win_get_buf(history_win))
        assert.are.equal(prompt_win, second.chat:prompt_win())
    end)

    it("keeps /new separate and replaces only the current session with /replace", function()
        local first = assert(Sessions.get_or_create({ layout = "buffer" }))
        first.chat._prompt:set_text("/new")
        first.chat:submit()

        local second = assert(Sessions.get())
        assert.is_not.equal(first, second)
        assert.are.same({ first, second }, Sessions.list())
        assert.is_true(first.rpc:is_running())
        assert.is_true(second.rpc:is_running())

        second.chat._prompt:set_text("/replace")
        second.chat:submit()

        local third = assert(Sessions.get())
        assert.are.same({ first, third }, Sessions.list())
        assert.is_true(first.rpc:is_running())
        assert.is_false(second.rpc:is_running())
        assert.is_true(third.rpc:is_running())
        assert.is_false(vim.api.nvim_buf_is_valid(second.history_buf))
    end)

    it("creates a session when replace has no current session", function()
        assert.is_nil(Sessions.get())

        Sessions.replace_session()

        local session = assert(Sessions.get())
        assert.are.same({ session }, Sessions.list())
        assert.is_true(session.rpc:is_running())
        assert.is_true(session.chat:is_visible())
    end)

    it("refuses to replace a busy session", function()
        local session = assert(Sessions.get_or_create({ layout = "buffer" }))
        session.chat._streaming = true

        Sessions.replace_session()

        assert.are.equal(session, Sessions.get())
        assert.are.same({ session }, Sessions.list())
        assert.is_true(session.rpc:is_running())
        assert.is_true(vim.api.nvim_buf_is_valid(session.history_buf))
        session.chat._streaming = false
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

    it("restores cursor and fold state when switching between History buffers", function()
        local function add_transcript(session, label)
            local history = session.chat:history()
            history:add_user_message(label .. " question\nsecond line", 1786438920000)
            history:on_agent_start(1786438920001, "output")
            history:on_text_delta(label .. " answer\nsecond line\nthird line")
            history:on_agent_end(nil, { force_completion = true })
            assert.is_true(vim.wait(200, function()
                return #history._message_blocks == 2
            end))
            return history:_extmark_row(history._message_blocks[2].anchor) + 1
        end

        local first = assert(Sessions.get_or_create({ layout = "buffer" }))
        local first_row = add_transcript(first, "first")
        local first_win = assert(first.chat._layout:history_win())
        vim.api.nvim_set_current_win(first_win)
        local first_cursor = { first_row, 2 }
        vim.api.nvim_win_set_cursor(first_win, first_cursor)
        vim.cmd("silent! foldclose")
        assert.are.equal(first_row, vim.fn.foldclosed(first_row))

        local second = assert(Sessions.get_or_create({ new = true, layout = "buffer" }))
        local second_row = add_transcript(second, "second")
        local second_win = assert(second.chat._layout:history_win())
        vim.api.nvim_set_current_win(second_win)
        vim.api.nvim_win_set_cursor(second_win, { second_row, 0 })
        vim.cmd("silent! foldopen")
        local second_cursor = { second_row, 1 }
        vim.api.nvim_win_set_cursor(second_win, second_cursor)
        assert.are.equal(-1, vim.fn.foldclosed(second_row))

        vim.cmd("buffer " .. first.history_buf)
        assert.is_true(vim.wait(200, function()
            local win = first.chat._layout:history_win()
            return win
                and vim.api.nvim_get_current_win() == win
                and vim.api.nvim_win_get_cursor(win)[1] == first_cursor[1]
                and vim.fn.foldclosed(first_row) == first_row
        end))
        local restored_first_win = first.chat._layout:history_win()
        assert.is_not_nil(restored_first_win)
        assert.same(first_cursor, vim.api.nvim_win_get_cursor(restored_first_win))

        vim.cmd("buffer " .. second.history_buf)
        assert.is_true(vim.wait(200, function()
            local win = second.chat._layout:history_win()
            return win
                and vim.api.nvim_get_current_win() == win
                and vim.api.nvim_win_get_cursor(win)[1] == second_cursor[1]
                and vim.fn.foldclosed(second_row) == -1
        end))
        local restored_second_win = second.chat._layout:history_win()
        assert.is_not_nil(restored_second_win)
        assert.same(second_cursor, vim.api.nvim_win_get_cursor(restored_second_win))
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

    it("keeps loading visible while backend messages replay in bounded slices", function()
        local pending = install_pending_rpc()
        local path = vim.fn.tempname() .. ".jsonl"
        local uri = Workspace.uri(Workspace.cwd(), path, 1)
        local payload = { messages = {} }
        for index = 1, 40 do
            payload.messages[index] = { role = "user", content = "persisted message " .. index }
        end
        SessionHistory.list = function()
            return { { id = vim.fs.basename(path):gsub("%.jsonl$", ""), path = path } }
        end
        SessionHistory.load_messages = function()
            error("resume must not read a local preview")
        end

        assert.is_true(Sessions.open_uri(uri))
        local session = assert(Sessions.get_for_tab())
        assert.is_true(session._switching_session)
        assert.are.equal("loading", session.chat._history._placeholder_mode)
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
        assert.are.equal("loading", session.chat._history._placeholder_mode)

        local real_defer = vim.defer_fn
        local deferred = {}
        vim.defer_fn = function(fn)
            deferred[#deferred + 1] = fn
        end
        messages.callback({ success = true, data = payload })
        local history_win
        local staged_ok, staged_err = pcall(function()
            assert.are.equal("loading", session.chat._history._placeholder_mode)
            -- Let the first scheduled replay slice run while defer_fn is
            -- captured; it must queue a continuation instead of completing.
            vim.wait(50)
            assert.is_true(#deferred > 0)

            history_win = assert(session.chat._layout:history_win())
            local loading_buf = assert(session.chat._replay_loading_buf)
            assert.are.equal(loading_buf, vim.api.nvim_win_get_buf(history_win))
            assert.is_not_nil(
                table
                    .concat(vim.api.nvim_buf_get_lines(loading_buf, 0, -1, false), "\n")
                    :find("Loading session", 1, true)
            )
            local partial = table.concat(vim.api.nvim_buf_get_lines(session.history_buf, 0, -1, false), "\n")
            assert.is_not_nil(partial:find("persisted message 1", 1, true))
            assert.is_nil(partial:find("persisted message 40", 1, true))
            assert.is_true(session._switching_session)
        end)
        vim.defer_fn = real_defer
        assert.is_true(staged_ok, staged_err)
        deferred[1]()
        assert.is_true(vim.wait(500, function()
            return not session._switching_session
        end))
        vim.wait(20)

        local history_text = table.concat(vim.api.nvim_buf_get_lines(session.history_buf, 0, -1, false), "\n")
        assert.is_not_nil(history_text:find("persisted message 40", 1, true))
        assert.is_nil(session.chat._history._placeholder_mode)
        assert.are.equal(session.history_buf, vim.api.nvim_win_get_buf(history_win))
        local prompt_win = assert(session.chat:prompt_win())
        assert.are.equal(prompt_win, vim.api.nvim_get_current_win())
        assert.are.equal(session.chat:prompt_buf(), vim.api.nvim_win_get_buf(prompt_win))
        assert.is_not.equal("i", vim.api.nvim_get_mode().mode)
        session.chat:submit()
        assert.are.equal("prompt", take_pending(pending, session.rpc, "prompt").msg.type)
    end)

    it("drops a queued replay slice when its History buffer is deleted", function()
        local pending = install_pending_rpc()
        local path = vim.fn.tempname() .. ".jsonl"
        local uri = Workspace.uri(Workspace.cwd(), path, 1)
        local payload = { messages = {} }
        for index = 1, 40 do
            payload.messages[index] = { role = "user", content = "persisted message " .. index }
        end
        SessionHistory.list = function()
            return { { id = vim.fs.basename(path):gsub("%.jsonl$", ""), path = path } }
        end

        assert.is_true(Sessions.open_uri(uri))
        local session = assert(Sessions.get_for_tab())
        local switch = take_pending(pending, session.rpc, "switch_session")
        clear_pending(pending)
        switch.callback({ success = true, data = { cancelled = false } })
        local messages = take_pending(pending, session.rpc, "get_messages")
        clear_pending(pending)

        local real_defer = vim.defer_fn
        local deferred = {}
        vim.defer_fn = function(fn)
            deferred[#deferred + 1] = fn
        end
        messages.callback({ success = true, data = payload })
        assert.is_true(vim.wait(200, function()
            return #deferred > 0 and session.chat._replay_loading_buf ~= nil
        end))
        local loading_buf = assert(session.chat._replay_loading_buf)
        vim.defer_fn = real_defer

        local deleted, delete_err = pcall(vim.api.nvim_buf_delete, session.history_buf, { force = true })
        assert.is_true(deleted, delete_err)
        assert.is_nil(Sessions.get_by_id(session.id))
        assert.is_false(vim.api.nvim_buf_is_valid(loading_buf))
        local resumed, resume_err = pcall(deferred[1])
        assert.is_true(resumed, resume_err)
        vim.wait(20)
    end)

    it("cleans up staged replay when History rendering fails", function()
        local pending = install_pending_rpc()
        local path = vim.fn.tempname() .. ".jsonl"
        local uri = Workspace.uri(Workspace.cwd(), path, 1)
        SessionHistory.list = function()
            return { { id = vim.fs.basename(path):gsub("%.jsonl$", ""), path = path } }
        end

        assert.is_true(Sessions.open_uri(uri))
        local session = assert(Sessions.get_for_tab())
        session.chat.add_user_message = function()
            error("render exploded")
        end
        local switch = take_pending(pending, session.rpc, "switch_session")
        clear_pending(pending)
        switch.callback({ success = true, data = { cancelled = false } })
        local messages = take_pending(pending, session.rpc, "get_messages")
        clear_pending(pending)
        local real_notify = vim.notify
        vim.notify = function() end
        messages.callback({ success = true, data = { messages = { { role = "user", content = "broken" } } } })

        local failed_cleanly = vim.wait(500, function()
            local text = table.concat(vim.api.nvim_buf_get_lines(session.history_buf, 0, -1, false), "\n")
            return not session._switching_session
                and session.chat._replay_loading_buf == nil
                and text:find("Failed to render session messages", 1, true) ~= nil
        end)
        vim.notify = real_notify
        assert.is_true(failed_cleanly)
        local history_win = assert(session.chat._layout:history_win())
        assert.are.equal(session.history_buf, vim.api.nvim_win_get_buf(history_win))
        vim.wait(20)
    end)

    it("leaves loading state when backend session switching is cancelled", function()
        local pending = install_pending_rpc()
        local path = vim.fn.tempname() .. ".jsonl"
        local uri = Workspace.uri(Workspace.cwd(), path, 1)
        SessionHistory.list = function()
            return { { id = vim.fs.basename(path):gsub("%.jsonl$", ""), path = path } }
        end

        assert.is_true(Sessions.open_uri(uri))
        local session = assert(Sessions.get_for_tab())
        local switch = take_pending(pending, session.rpc, "switch_session")
        clear_pending(pending)
        switch.callback({ success = true, data = { cancelled = true } })

        assert.is_true(vim.wait(200, function()
            return not session._switching_session and session.chat._history._placeholder_mode == nil
        end))
        for _, entry in ipairs(pending) do
            assert.are_not.equal("get_messages", entry.msg.type)
        end
    end)

    it("replaces loading state with backend message errors", function()
        local pending = install_pending_rpc()
        local path = vim.fn.tempname() .. ".jsonl"
        local uri = Workspace.uri(Workspace.cwd(), path, 1)
        SessionHistory.list = function()
            return { { id = vim.fs.basename(path):gsub("%.jsonl$", ""), path = path } }
        end

        assert.is_true(Sessions.open_uri(uri))
        local session = assert(Sessions.get_for_tab())
        local switch = take_pending(pending, session.rpc, "switch_session")
        clear_pending(pending)
        switch.callback({ success = true, data = { cancelled = false } })
        local messages = take_pending(pending, session.rpc, "get_messages")
        clear_pending(pending)
        messages.callback({ success = false, error = "session replay failed" })

        assert.is_true(vim.wait(300, function()
            local text = table.concat(vim.api.nvim_buf_get_lines(session.history_buf, 0, -1, false), "\n")
            return not session._switching_session
                and session.chat._history._placeholder_mode == nil
                and text:find("session replay failed", 1, true) ~= nil
        end))
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
        local History = require("agent-workbench.ui.chat.history")
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
