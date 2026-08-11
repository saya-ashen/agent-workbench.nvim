--- https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/modes/rpc/rpc-types.ts
---@alias pi.RpcEventType
---| "agent_start"
---| "agent_end"
---| "message_start"
---| "message_update"
---| "message_end"
---| "turn_start"
---| "turn_end"
---| "tool_execution_start"
---| "tool_execution_update"
---| "tool_execution_end"
---| "compaction_start"
---| "compaction_end"
---| "auto_compaction_start"
---| "auto_compaction_end"
---| "auto_retry_start"
---| "auto_retry_end"
---| "summarization_retry_scheduled"
---| "summarization_retry_attempt_start"
---| "summarization_retry_finished"
---| "agent_settled"
---| "extension_ui_request"
---| "extension_error"
---| "bash_execution_update"
---| "response"
---| "_process_exit"
---| "_stderr"

--- https://github.com/earendil-works/pi/blob/main/packages/ai/src/types.ts
---@alias pi.AssistantMessageEventType
---| "start"
---| "text_start"
---| "text_delta"
---| "text_end"
---| "thinking_start"
---| "thinking_delta"
---| "thinking_end"
---| "toolcall_start"
---| "toolcall_delta"
---| "toolcall_end"
---| "done"
---| "error"

--- https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/modes/rpc/rpc-types.ts
---@alias pi.RpcCommandType
---| "prompt"
---| "steer"
---| "follow_up"
---| "abort"
---| "abort_retry"
---| "bash"
---| "abort_bash"
---| "new_session"
---| "switch_session"
---| "get_messages"
---| "get_commands"
---| "get_state"
---| "set_thinking_level"
---| "cycle_thinking_level"
---| "set_model"
---| "cycle_model"
---| "get_available_models"
---| "get_available_thinking_levels"
---| "set_session_name"
---| "set_auto_compaction"
---| "extension_ui_response"
---| "get_tree"

---@class pi.RpcImageContent
---@field type "image"
---@field data string base64-encoded
---@field mimeType string

---@class pi.RpcCommand
---@field type pi.RpcCommandType
---@field id? string
---@field message? string
---@field images? pi.RpcImageContent[]
---@field sessionPath? string
---@field value? string
---@field confirmed? boolean
---@field cancelled? boolean
---@field [string] any

--- https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md
---@class pi.RpcEvent
---@field type pi.RpcEventType
---@field assistantMessageEvent? { type: pi.AssistantMessageEventType, delta?: string, toolCall?: pi.ToolCall }
---@field toolName? string
---@field toolCallId? string
---@field args? table
---@field result? { content?: table[], details?: table }
---@field isError? boolean
---@field command? string
---@field success? boolean
---@field data? table
---@field code? integer
---@field error? string
---@field errorMessage? string
---@field attempt? integer
---@field maxAttempts? integer
---@field delayMs? integer
---@field source? string summarization_retry_attempt_start: "compaction" | "branchSummary"
---@field reason? string compaction summarization reason: "manual" | "threshold" | "overflow"
---@field id? string
---@field method? string
---@field message? string|{ stopReason?: string, errorMessage?: string, [string]: any }
---@field messages? table[]
---@field notifyType? "info"|"warning"|"error"
---@field options? string[]
---@field timeout? integer
---@field title? string
---@field prefill? string
---@field placeholder? string
---@field [string] any

---@class pi.ToolCall
---@field id string
---@field name string
---@field arguments string|table

---@class pi.Rpc
---@field _job_id integer?
---@field _handler fun(msg: pi.RpcEvent)?
---@field _pending table<string, fun(msg: pi.RpcEvent)>
---@field _tab pi.TabId
---@field _req_id integer
---@field _stdout_parts string[] Chunks of the not-yet-complete trailing stdout line
local Rpc = {}
Rpc.__index = Rpc

local Config = require("pi.config")
local Cli = require("pi.cli")
local Notify = require("pi.notify")
local CommandsCache = require("pi.cache.commands")
local Json = require("pi.json")

local DEBUG_OVERRIDE = nil ---@type boolean?

--- Per-project log state: tracks which log files have been reset this session.
---@type table<string, boolean>
local log_reset_done = {}

local function debug_enabled()
    if DEBUG_OVERRIDE ~= nil then
        return DEBUG_OVERRIDE
    end
    return Config.options.debug
end

--- Cached at module load time (main loop safe).
local log_path ---@type string
do
    local cwd = vim.fn.getcwd()
    local slug = cwd:gsub("^/", ""):gsub("/", "--")
    if slug == "" then
        slug = "root"
    end
    log_path = vim.fn.stdpath("log") .. "/pi/" .. slug .. "/rpc.log"
end

--- Recursively create directories (libuv-safe, no vim.fn).
---@param dir string
local function mkdirp(dir)
    local stat = vim.uv.fs_stat(dir)
    if stat then
        return
    end
    local parent = dir:match("(.+)/[^/]+$")
    if parent then
        mkdirp(parent)
    end
    vim.uv.fs_mkdir(dir, 493) -- 0755
end

--- Reset a log file (creates parent directories if needed).
---@param path string
local function reset_log(path)
    local dir = path:match("(.+)/[^/]+$")
    if dir then
        mkdirp(dir)
    end
    local file = io.open(path, "w")
    if file then
        file:close()
    end
    log_reset_done[path] = true
end

---@param tag string
---@param msg table|string
local function log(tag, msg)
    if not debug_enabled() then
        return
    end
    if not log_reset_done[log_path] then
        reset_log(log_path)
    end
    local file = io.open(log_path, "a")
    if not file then
        return
    end
    local ts = os.date("%H:%M:%S")
    local json
    if type(msg) == "string" then
        json = msg
    else
        local ok_encode, encoded = pcall(vim.json.encode, msg)
        -- Deep messages (e.g. a 1000+ level get_tree tree) exceed cjson's
        -- encode nesting cap too; log a depth-bounded inspect instead.
        json = ok_encode and encoded or vim.inspect(msg, { depth = 8 })
    end
    file:write(string.format("[%s] [%s] %s\n\n\n", ts, tag, json))
    file:close()
end

---@return pi.RpcAdapterContext
local function adapter_context()
    return {
        set_commands = function(commands)
            if type(commands) ~= "table" then
                vim.schedule(function()
                    Notify.error("RPC ctx.set_commands expects a command list table")
                end)
                return
            end
            CommandsCache.set(commands)
        end,
    }
end

---@param mapper function
---@param msg table
---@return table?
local function map_event(mapper, msg)
    local ok, mapped = pcall(mapper, vim.deepcopy(msg), adapter_context())
    if not ok then
        vim.schedule(function()
            Notify.error("RPC map_event error: " .. tostring(mapped))
        end)
        return msg
    end
    if mapped == nil then
        return nil
    end
    if type(mapped) ~= "table" then
        vim.schedule(function()
            Notify.error("RPC map_event must return an event table or nil")
        end)
        return msg
    end
    if type(mapped.type) ~= "string" or mapped.type == "" then
        vim.schedule(function()
            Notify.error("RPC map_event returned an event without a string type")
        end)
        return msg
    end
    return mapped
end

---@param mapper function
---@param cmd table
---@return table?
local function map_command(mapper, cmd)
    local ok, mapped = pcall(mapper, cmd, adapter_context())
    if not ok then
        vim.schedule(function()
            Notify.error("RPC map_command error: " .. tostring(mapped))
        end)
        return nil
    end
    if mapped == nil then
        return nil
    end
    if type(mapped) ~= "table" then
        vim.schedule(function()
            Notify.error("RPC map_command must return a command table or nil")
        end)
        return nil
    end
    if type(mapped.id) ~= "string" or mapped.id == "" then
        vim.schedule(function()
            Notify.error("RPC map_command returned a command without a string id")
        end)
        return nil
    end
    return mapped
end

---@type table<string, true>
local warned = {}

---@param tab pi.TabId
---@return pi.Rpc
function Rpc.new(tab)
    local self = setmetatable({}, Rpc)
    self._job_id = nil
    self._handler = nil
    self._pending = {}
    self._tab = tab
    self._req_id = 1
    self._stdout_parts = {}
    return self
end

---@param msg pi.RpcEvent
function Rpc:_dispatch(msg)
    local event_mapper = Config.options.rpc and Config.options.rpc.map_event
    if type(event_mapper) == "function" then
        msg = map_event(event_mapper, msg) --[[@as pi.RpcEvent]]
    end
    if not msg or not msg.type then
        return
    end

    log("incoming", msg)

    if self._handler then
        self._handler(msg)
    end

    -- Only responses consume pending callbacks: streamed events may carry the
    -- same id (e.g. bash_execution_update echoes its bash command's id) and
    -- must not eat the one-shot response callback.
    if msg.type == "response" and msg.id and self._pending[msg.id] then
        local cb = self._pending[msg.id]
        self._pending[msg.id] = nil
        cb(msg)
    end
end

---@return boolean
function Rpc:start()
    if self._job_id then
        return true
    end
    self._stdout_parts = {}
    local cmd = Cli.command()
    self._job_id = vim.fn.jobstart(cmd, {
        on_stdout = function(_, data)
            self:_on_stdout(data)
        end,
        on_stderr = function(_, data)
            self:_on_stderr(data)
        end,
        on_exit = function(_, code)
            self:_on_exit(code)
        end,
        stdout_buffered = false,
        stderr_buffered = false,
    })
    if self._job_id <= 0 then
        Notify.error("Failed to start process. Is 'pi' installed?")
        self._job_id = nil
        return false
    end
    return true
end

---@param cmd pi.RpcCommand
---@param callback? fun(msg: pi.RpcEvent)
---@return boolean
function Rpc:send(cmd, callback)
    if not self._job_id then
        Notify.error("Process not running")
        return false
    end
    if not cmd.id then
        cmd.id = self._tab .. ":" .. self._req_id
        self._req_id = self._req_id + 1
    end

    local command_mapper = Config.options.rpc and Config.options.rpc.map_command
    if type(command_mapper) == "function" then
        cmd = map_command(command_mapper, cmd) --[[@as pi.RpcCommand]]
    end
    if not cmd then
        return false
    end

    if callback then
        self._pending[cmd.id] = callback
    end
    log("outgoing", cmd)
    vim.fn.chansend(self._job_id, vim.json.encode(cmd) .. "\n")
    return true
end

---@param fn fun(msg: pi.RpcEvent)
function Rpc:set_handler(fn)
    self._handler = fn
end

function Rpc:stop()
    if self._job_id then
        vim.fn.jobstop(self._job_id)
        self._job_id = nil
    end
    self._stdout_parts = {}
    self._pending = {}
end

---@return boolean
function Rpc:is_running()
    return self._job_id ~= nil
end

---@param line string
function Rpc:_decode_line(line)
    local ok, msg = pcall(vim.json.decode, line)
    if ok and msg then
        self:_dispatch(msg)
        return
    end

    -- vim.json (lua-cjson) hard-caps nesting at depth 1000, so deep payloads
    -- such as the get_tree response for a session with ~500+ messages fail to
    -- decode. Retry with the depth-tolerant decoder (pi.json) before giving up.
    local cjson_err = tostring(msg)
    local decoded, fallback_err = Json.decode(line)
    if decoded ~= nil then
        self:_dispatch(decoded)
        return
    end

    local err = fallback_err and (cjson_err .. " (fallback: " .. fallback_err .. ")") or cjson_err
    log("ERROR", "Failed to decode: " .. err .. " | " .. line)
    vim.schedule(function()
        Notify.warn("Failed to decode RPC message: " .. err)
    end)
end

---@param data string[]?
function Rpc:_on_stdout(data)
    if not data then
        return
    end
    -- nvim splits job stdout on newlines: data[1] continues the previous
    -- partial line, data[2..#data-1] are complete lines, and data[#data] is the
    -- new trailing partial ("" when the chunk ended on a newline).
    --
    -- A response can be a single very large line (e.g. get_messages for a big
    -- session). Accumulate its chunks in a table and concat only once the line
    -- is complete: growing the partial via repeated string concatenation is
    -- O(n^2) and took seconds for multi-MB responses.
    if #data == 1 then
        -- No newline in this chunk: extend the pending partial line.
        if data[1] ~= "" then
            self._stdout_parts[#self._stdout_parts + 1] = data[1]
        end
        return
    end

    -- data[1] completes the pending partial line.
    self._stdout_parts[#self._stdout_parts + 1] = data[1]
    local line = table.concat(self._stdout_parts)
    if line ~= "" then
        self:_decode_line(line)
    end

    -- Middle elements are already-complete lines.
    for i = 2, #data - 1 do
        if data[i] ~= "" then
            self:_decode_line(data[i])
        end
    end

    -- Last element is the new trailing partial line.
    self._stdout_parts = { data[#data] }
end

---@param data string[]?
function Rpc:_on_stderr(data)
    if not data then
        return
    end
    for _, line in ipairs(data) do
        if line ~= "" then
            self:_dispatch({ type = "_stderr", message = line })
        end
    end
end

---@param code integer
function Rpc:_on_exit(code)
    self._job_id = nil
    self._stdout_parts = {}
    self:_dispatch({ type = "_process_exit", code = code })
end

function Rpc.toggle_debug()
    DEBUG_OVERRIDE = not debug_enabled()
    if debug_enabled() then
        reset_log(log_path)
        Notify.info("Debug ON -> " .. log_path)
    else
        Notify.info("Debug OFF")
    end
end

---@param event_type string
function Rpc.log_unhandled(event_type)
    if warned[event_type] then
        return
    end

    warned[event_type] = true

    log("UNHANDLED", event_type)

    if debug_enabled() then
        vim.schedule(function()
            Notify.warn("Unhandled event: " .. event_type)
        end)
    end
end

return Rpc
