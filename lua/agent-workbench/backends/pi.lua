---@class agent_workbench.BackendCapabilities
---@field raw_rpc? boolean
---@field follow_up? boolean
---@field attachments? boolean
---@field commands? boolean
---@field thinking? boolean
---@field models? boolean
---@field history? boolean
---@field tree? boolean
---@field compaction? boolean
---@field direct_bash? boolean
---@field changed_files? boolean

---@class agent_workbench.BackendHistoryItem
---@field id string Backend conversation identifier.
---@field task_id string Backend task identifier pinned by resume.
---@field title? string
---@field preview? string
---@field timestamp? string|number
---@field work_dir? string
---@field failed? boolean
---@field is_running? boolean

---@class agent_workbench.BackendHistoryResult
---@field messages table[] Normalized user/assistant messages accepted by Workbench replay.
---@field chat_id? string
---@field task_id? string

---@class agent_workbench.BackendEvent
---@field type string
---@field raw? agent_workbench.RpcEvent
---@field delta? string
---@field tool_name? string
---@field tool_call_id? string
---@field args? any
---@field result? any
---@field is_error? boolean
---@field message? any
---@field timestamp? number
---@field replayed? boolean
---@field usage? table
---@field connection? "starting"|"connected"|"disconnected"|"error"
---@field reason? "completed"|"stopped"|"interrupted"|"error"
---@field text? string

---@class agent_workbench.BackendSession
---@field rpc? agent_workbench.Rpc Temporary compatibility access for backends exposing Pi RPC features.
---@field list_history? fun(self:agent_workbench.BackendSession, callback:fun(items:agent_workbench.BackendHistoryItem[]|nil,error:string|nil)):(boolean,string?)
---@field load_history? fun(self:agent_workbench.BackendSession, item:agent_workbench.BackendHistoryItem, callback:fun(result:agent_workbench.BackendHistoryResult|nil,error:string|nil)):(boolean,string?)
local PiBackend = {}
PiBackend.__index = PiBackend

local Rpc = require("agent-workbench.rpc")

---@param msg agent_workbench.RpcEvent
---@return agent_workbench.BackendEvent
function PiBackend.normalize_event(msg)
    local event = msg.assistantMessageEvent
    if msg.type == "agent_start" then
        return { type = "run_started", raw = msg }
    elseif msg.type == "agent_end" then
        return { type = "run_turn_finished", raw = msg }
    elseif msg.type == "agent_settled" then
        return { type = "run_settled", raw = msg }
    elseif msg.type == "message_start" then
        return { type = "message_started", message = msg.message, raw = msg }
    elseif msg.type == "message_end" then
        return { type = "message_finished", message = msg.message, raw = msg }
    elseif msg.type == "message_update" and type(event) == "table" then
        if event.type == "thinking_start" then
            return { type = "thinking_started", raw = msg }
        elseif event.type == "thinking_delta" then
            return { type = "thinking_delta", delta = event.delta or "", raw = msg }
        elseif event.type == "thinking_end" then
            return { type = "thinking_finished", raw = msg }
        elseif event.type == "text_delta" then
            return { type = "text_delta", delta = event.delta or "", raw = msg }
        elseif event.type == "toolcall_end" then
            local tool_call = event.toolCall
            return {
                type = "tool_call_finished",
                tool_name = type(tool_call) == "table" and tool_call.name or nil,
                tool_call_id = type(tool_call) == "table" and tool_call.id or nil,
                args = type(tool_call) == "table" and tool_call.arguments or nil,
                raw = msg,
            }
        end
    elseif msg.type == "tool_execution_start" then
        return {
            type = "tool_started",
            tool_name = msg.toolName,
            tool_call_id = msg.toolCallId,
            args = msg.args,
            raw = msg,
        }
    elseif msg.type == "tool_execution_update" then
        return {
            type = "tool_updated",
            tool_name = msg.toolName,
            tool_call_id = msg.toolCallId,
            raw = msg,
        }
    elseif msg.type == "tool_execution_end" then
        return {
            type = "tool_finished",
            tool_name = msg.toolName,
            tool_call_id = msg.toolCallId,
            result = msg.result,
            is_error = msg.isError,
            raw = msg,
        }
    end
    return { type = "backend_event", raw = msg }
end

---@param options { id: integer, cwd: string }
---@return agent_workbench.BackendSession
function PiBackend.new(options)
    assert(type(options) == "table", "backend options required")
    local self = setmetatable({}, PiBackend)
    self.rpc = Rpc.new(options.id, options.cwd)
    return self
end

---@return agent_workbench.BackendCapabilities
function PiBackend:capabilities()
    return {
        attachments = true,
        changed_files = true,
        commands = true,
        compaction = true,
        direct_bash = true,
        follow_up = true,
        history = true,
        models = true,
        raw_rpc = true,
        thinking = true,
        tree = true,
    }
end

---@param sink fun(event: agent_workbench.BackendEvent)
---@return boolean
function PiBackend:start(sink)
    self.rpc:set_handler(function(msg)
        sink(PiBackend.normalize_event(msg))
    end)
    return self.rpc:start()
end

function PiBackend:close()
    self.rpc:stop()
end

---@param text string
---@param opts? { images?: agent_workbench.RpcImageContent[] }
---@return boolean
function PiBackend:prompt(text, opts)
    return self:_send_message("prompt", text, opts)
end

---@param text string
---@param opts? { images?: agent_workbench.RpcImageContent[] }
---@return boolean
function PiBackend:steer(text, opts)
    return self:_send_message("steer", text, opts)
end

---@param text string
---@param opts? { images?: agent_workbench.RpcImageContent[] }
---@return boolean
function PiBackend:follow_up(text, opts)
    return self:_send_message("follow_up", text, opts)
end

---@param command_type "prompt"|"steer"|"follow_up"
---@param text string
---@param opts? { images?: agent_workbench.RpcImageContent[] }
---@return boolean
function PiBackend:_send_message(command_type, text, opts)
    ---@type agent_workbench.RpcCommand
    local command = { type = command_type, message = text }
    if opts and opts.images and #opts.images > 0 then
        command.images = opts.images
    end
    return self.rpc:send(command)
end

---@return boolean
function PiBackend:stop()
    return self.rpc:send({ type = "abort" })
end

---@return boolean
function PiBackend:is_running()
    return self.rpc:is_running()
end

return PiBackend
