local Framing = require("agent-workbench.ui.chat.terminal.shell.framing")

local COMPLETION_OUTPUT_MAX = 256 * 1024
local ALTERNATE_SCREEN_ENTER = { "\27[?1049h", "\27[?1047h", "\27[?47h" }
local ALTERNATE_SCREEN_LEAVE = { "\27[?1049l", "\27[?1047l", "\27[?47l" }
local ALTERNATE_SCREEN_TAIL = 7

---@class agent_workbench.ShellSessionOpts
---@field cwd string
---@field on_output fun(bytes: string)
---@field on_exit fun(code: integer)
---@field on_start? fun()
---@field on_tui_enter? fun()
---@field on_tui_leave? fun()
---@field on_end fun(status: integer, duration_ms: integer, cwd?: string)

---@class agent_workbench.ShellCompletionRequest
---@field commandline string
---@field callback? fun(output: string)
---@field frame? agent_workbench.ShellFrame
---@field output? string

---@class agent_workbench.ShellSession
---@field _opts agent_workbench.ShellSessionOpts
---@field _job integer?
---@field _buf integer?
---@field _frame agent_workbench.ShellFrame?
---@field _completion agent_workbench.ShellCompletionRequest?
---@field _queued_completion agent_workbench.ShellCompletionRequest?
---@field _ready_marker string?
---@field _ready_bytes string
---@field _pending string?
---@field _started_at integer?
---@field _running boolean
---@field _stopping boolean
---@field _tui_active boolean
---@field _tui_tail string
local Session = {}
Session.__index = Session

---@param opts agent_workbench.ShellSessionOpts
---@return agent_workbench.ShellSession
function Session.new(opts)
    return setmetatable({
        _opts = opts,
        _job = nil,
        _buf = nil,
        _frame = nil,
        _completion = nil,
        _queued_completion = nil,
        _ready_marker = nil,
        _ready_bytes = "",
        _pending = nil,
        _started_at = nil,
        _running = false,
        _stopping = false,
        _tui_active = false,
        _tui_tail = "",
    }, Session)
end

---@return boolean
function Session:alive()
    return self._job ~= nil and vim.fn.jobwait({ self._job }, 0)[1] == -1
end

---@return boolean, string?
function Session:start()
    if self:alive() then
        return true
    end
    local fish = vim.fn.exepath("fish")
    if fish == "" then
        return false, "fish executable not found"
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    self._stopping = false
    local started, job = pcall(vim.api.nvim_buf_call, buf, function()
        return vim.fn.termopen({ fish, "--interactive", "--private" }, {
            cwd = self._opts.cwd,
            on_stdout = function(_, data)
                vim.schedule(function()
                    if not self._stopping then
                        self:_receive(table.concat(data, "\n"))
                    end
                end)
            end,
            on_exit = function(_, code)
                vim.schedule(function()
                    local stopping = self._stopping
                    self._job = nil
                    self._frame = nil
                    self._running = false
                    self:_cancel_completions()
                    self._completion = nil
                    if not stopping then
                        self._opts.on_exit(code)
                    end
                end)
            end,
        })
    end)
    if not started or job <= 0 then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        return false, started and "could not start fish" or tostring(job)
    end
    self._buf = buf
    self._job = job
    self._ready_bytes = ""
    self._ready_marker = "\27]1337;pi;"
        .. vim.fn.sha256(("%s:%s"):format(vim.uv.hrtime(), math.random())):sub(1, 32)
        .. ";R\7"
    -- Private interactive fish reads user config; these functions affect this session only.
    local ready_marker = assert(self._ready_marker)
    vim.api.nvim_chan_send(
        job,
        "function fish_prompt; end; function fish_right_prompt; end; builtin printf '%b' "
            .. Framing.quote_fish(Framing.escape_bytes(ready_marker))
            .. "\n"
    )
    return true
end

---@return integer?
function Session:terminal_buffer()
    if self._buf and vim.api.nvim_buf_is_valid(self._buf) then
        return self._buf
    end
    return nil
end

---@param command string
---@return boolean, string?
function Session:run(command)
    if self._running then
        return false, "shell command is already running"
    end
    local ok, err = self:start()
    if not ok then
        return false, err
    end
    self:_cancel_completions()
    self._frame = Framing.new()
    self._pending = command
    self._started_at = vim.uv.now()
    self._running = true
    self._tui_active = false
    self._tui_tail = ""
    if self._opts.on_start then
        self._opts.on_start()
    end
    if self._ready_marker == nil then
        return self:_send_pending()
    end
    return true
end

---@return boolean, string?
function Session:_send_pending()
    local command = self._pending
    self._pending = nil
    if not command or not self._frame or not self._job then
        return false, "shell command is missing"
    end
    if not pcall(vim.api.nvim_chan_send, self._job, self._frame:wrap(command)) then
        self._running = false
        return false, "could not write command to fish"
    end
    return true
end

---@param request agent_workbench.ShellCompletionRequest?
local function cancel_completion(request)
    if request and request.callback then
        local callback = assert(request.callback)
        request.callback = nil
        callback("")
    end
end

function Session:_cancel_completions()
    cancel_completion(self._completion)
    cancel_completion(self._queued_completion)
    self._queued_completion = nil
end

---@param request agent_workbench.ShellCompletionRequest
---@return boolean, string?
function Session:_send_completion(request)
    local job = self._job
    if not job then
        cancel_completion(request)
        return false, "fish session is not running"
    end
    request.frame = Framing.new()
    request.output = ""
    self._completion = request
    local command = "builtin complete --escape --color=never -C " .. Framing.quote_fish(request.commandline)
    if not pcall(vim.api.nvim_chan_send, job, request.frame:wrap(command)) then
        self._completion = nil
        cancel_completion(request)
        return false, "could not request fish completions"
    end
    return true
end

---@param commandline string
---@param callback fun(output: string)
---@return boolean, string?
function Session:complete(commandline, callback)
    if self._running then
        callback("")
        return false, "shell command is already running"
    end
    local ok, err = self:start()
    if not ok then
        callback("")
        return false, err
    end
    local request = { commandline = commandline, callback = callback }
    if self._completion or self._ready_marker then
        cancel_completion(self._completion)
        cancel_completion(self._queued_completion)
        self._queued_completion = request
        return true
    end
    return self:_send_completion(request)
end

---@param input string
---@return boolean, string?
function Session:send_input(input)
    local frame = self._frame
    if not self._job or not self._running then
        return false, "shell command is not running"
    end
    if self._pending or not frame or not frame:active() then
        return false, "shell command is starting"
    end
    if not pcall(vim.api.nvim_chan_send, self._job, input .. "\n") then
        return false, "could not write input to shell command"
    end
    return true
end

function Session:interrupt()
    if not self._job or not self._running then
        return
    end
    if self._pending then
        self._pending = nil
        self._frame = nil
        self._running = false
        self._opts.on_end(130, math.max(0, vim.uv.now() - (self._started_at or vim.uv.now())))
        return
    end
    pcall(vim.api.nvim_chan_send, self._job, "\003")
end

---@param bytes string
---@param sequences string[]
---@return integer?, integer?
local function find_sequence(bytes, sequences)
    local earliest, length
    for _, sequence in ipairs(sequences) do
        local start = bytes:find(sequence, 1, true)
        if start and (not earliest or start < earliest) then
            earliest = start
            length = #sequence
        end
    end
    return earliest, length
end

---@param bytes string
function Session:_detect_tui(bytes)
    local sample = self._tui_tail .. bytes
    while sample ~= "" do
        local sequences = self._tui_active and ALTERNATE_SCREEN_LEAVE or ALTERNATE_SCREEN_ENTER
        local start, length = find_sequence(sample, sequences)
        if not start or not length then
            self._tui_tail = sample:sub(-ALTERNATE_SCREEN_TAIL)
            return
        end
        sample = sample:sub(start + length)
        self._tui_active = not self._tui_active
        local callback = self._tui_active and self._opts.on_tui_enter or self._opts.on_tui_leave
        if callback then
            callback()
        end
    end
    self._tui_tail = ""
end

---@param bytes string
function Session:_receive(bytes)
    if self._ready_marker then
        self._ready_bytes = (self._ready_bytes .. bytes):sub(-512)
        local marker = assert(self._ready_marker)
        if self._ready_bytes:find(marker, 1, true) then
            self._ready_marker = nil
            self._ready_bytes = ""
            if self._pending then
                self:_send_pending()
            elseif self._queued_completion then
                local request = assert(self._queued_completion)
                self._queued_completion = nil
                self:_send_completion(request)
            end
        end
        return
    end

    local completion = self._completion
    if completion and completion.frame then
        for _, event in ipairs(completion.frame:feed(bytes)) do
            if event.type == "output" then
                local output = completion.output or ""
                local room = COMPLETION_OUTPUT_MAX - #output
                if room > 0 then
                    completion.output = output .. event.bytes:sub(1, room)
                end
            else
                self._completion = nil
                local callback = completion.callback
                completion.callback = nil
                if callback then
                    callback(completion.output or "")
                end
                if not self._running and self._queued_completion then
                    local request = assert(self._queued_completion)
                    self._queued_completion = nil
                    self:_send_completion(request)
                end
            end
        end
    end

    local frame = self._frame
    if frame then
        for _, event in ipairs(frame:feed(bytes)) do
            if event.type == "output" then
                self:_detect_tui(event.bytes)
                self._opts.on_output(event.bytes)
            else
                self._running = false
                self._frame = nil
                self._tui_tail = ""
                self._opts.on_end(
                    event.status,
                    math.max(0, vim.uv.now() - (self._started_at or vim.uv.now())),
                    event.cwd
                )
            end
        end
    end
end

function Session:stop()
    self._stopping = true
    local job = self._job
    if job and self:alive() then
        pcall(vim.fn.jobstop, job)
        pcall(vim.fn.jobwait, { job }, 1000)
    end
    self._job = nil
    self._frame = nil
    self._running = false
    self._pending = nil
    self:_cancel_completions()
    self._completion = nil
    self._ready_marker = nil
    self._ready_bytes = ""
    self._tui_active = false
    self._tui_tail = ""
    if self._buf and vim.api.nvim_buf_is_valid(self._buf) then
        pcall(vim.api.nvim_buf_delete, self._buf, { force = true })
    end
    self._buf = nil
end

return Session
