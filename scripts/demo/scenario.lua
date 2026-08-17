local M = {}

local fake_rpc_installed = false

local session_names = {
    [1] = "Workspace review",
    [2] = "Test coverage",
    [3] = "Workspace beta",
}

local session_replies = {
    [1] = "Buffer chat keeps this conversation in the current editor buffer.",
    [2] = "Test coverage is still working in the background.",
    [3] = "Workspace beta has its own session and working directory.",
}

---@class DemoRpc
---@field id integer
---@field cwd string
---@field _handler fun(message: table)?
---@field _running boolean
local DemoRpc = {}
DemoRpc.__index = DemoRpc

---@param id integer
---@param cwd string
---@return DemoRpc
function DemoRpc.new(id, cwd)
    return setmetatable({ id = id, cwd = cwd, _running = false }, DemoRpc)
end

---@return boolean
function DemoRpc:start()
    self._running = true
    return true
end

---@return boolean
function DemoRpc:is_running()
    return self._running
end

---@param handler fun(message: table)
function DemoRpc:set_handler(handler)
    self._handler = handler
end

function DemoRpc:stop()
    self._running = false
end

---@param message table
---@param delay integer
function DemoRpc:_emit(message, delay)
    vim.defer_fn(function()
        if self._running and self._handler then
            self._handler(message)
        end
    end, delay)
end

---@return table
function DemoRpc:_state()
    return {
        sessionName = session_names[self.id] or ("Session " .. self.id),
        model = { provider = "demo", id = "demo-model" },
        thinkingLevel = "medium",
        autoCompactionEnabled = true,
    }
end

---@param callback fun(response: table)?
function DemoRpc:_reply(callback, response)
    if not callback then
        return
    end
    vim.schedule(function()
        callback(response)
    end)
end

---@param message string
function DemoRpc:_prompt(message)
    local delay = self.id == 2 and 4500 or 700
    local reply = session_replies[self.id] or ("Received: " .. message)
    self:_emit({ type = "agent_start" }, 0)
    self:_emit({
        type = "message_start",
        message = { role = "assistant", timestamp = os.time() * 1000 },
    }, delay)
    self:_emit({
        type = "message_update",
        assistantMessageEvent = { type = "text_delta", delta = reply },
    }, delay + 40)
    self:_emit({
        type = "message_end",
        message = { role = "assistant", stopReason = "stop" },
    }, delay + 80)
    self:_emit({ type = "agent_end" }, delay + 100)
    self:_emit({ type = "agent_settled" }, delay + 120)
end

---@param command table
---@param callback fun(response: table)?
---@return boolean
function DemoRpc:send(command, callback)
    if not self._running then
        return false
    end

    if command.type == "get_commands" then
        self:_reply(callback, { success = true, data = { commands = {} } })
    elseif command.type == "get_state" then
        self:_reply(callback, { success = true, data = self:_state() })
    elseif command.type == "set_session_name" then
        session_names[self.id] = command.name
        self:_reply(callback, { success = true, data = {} })
        self:_emit({ type = "session_info_changed", name = command.name }, 0)
    elseif command.type == "prompt" or command.type == "steer" or command.type == "follow_up" then
        self:_prompt(command.message or "")
        self:_reply(callback, { success = true, data = {} })
    else
        self:_reply(callback, { success = true, data = {} })
    end
    return true
end

local function install_fake_rpc()
    if fake_rpc_installed then
        return
    end
    local Rpc = require("agent-workbench.rpc")
    Rpc.new = function(id, cwd)
        return DemoRpc.new(id, cwd)
    end
    fake_rpc_installed = true
end

local function open_beta_session()
    local opened = false
    vim.api.nvim_create_autocmd("DirChanged", {
        once = false,
        callback = function()
            if opened or vim.fs.basename(vim.fn.getcwd()) ~= "workspace-beta" then
                return
            end
            opened = true
            vim.schedule(function()
                vim.cmd("Pi")
            end)
        end,
    })
end

function M.overview()
    install_fake_rpc()
    open_beta_session()
end

function M.shell()
    install_fake_rpc()
end

return M
