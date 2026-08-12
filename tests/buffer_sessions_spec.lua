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
        assert.are.equal(first.chat:prompt_buf(), vim.api.nvim_win_get_buf(prompt_win))
        assert.is_true(first.rpc:is_running())
        assert.is_true(second.rpc:is_running())
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
        vim.wait(20)

        assert.is_false(vim.bo[session.history_buf].buflisted)
        assert.is_true(session.rpc:is_running())
        assert.are.equal(1, #Sessions.list())

        vim.api.nvim_buf_delete(session.history_buf, { force = true })
        vim.wait(20)
        assert.is_false(session.rpc:is_running())
    end)
end)
