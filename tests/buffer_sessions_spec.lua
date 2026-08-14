local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")
local WorkspaceBuffers = require("pi.workspace_buffers")

Config.setup({})

local real_rpc = { start = Rpc.start, stop = Rpc.stop, send = Rpc.send }

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
        vim.wait(20)

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
