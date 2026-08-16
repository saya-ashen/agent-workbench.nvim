---@class pi.ShellFrame
---@field token string
---@field _bytes string
---@field _active boolean
local Framing = {}
Framing.__index = Framing

local OSC = "\27]1337;pi;"
local BEL = "\7"

---@param text string
---@return string
function Framing.quote_fish(text)
    -- Fish double quotes preserve a literal multi-line command for eval.
    return '"' .. text:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("%$", "\\$"):gsub("`", "\\`") .. '"'
end

---@param token? string
---@return pi.ShellFrame
function Framing.new(token)
    token = token or vim.fn.sha256(("%s:%s:%s"):format(vim.uv.hrtime(), vim.fn.getpid(), math.random())):sub(1, 32)
    return setmetatable({ token = token, _bytes = "", _active = false }, Framing)
end

---@return string
function Framing:start_marker()
    return OSC .. self.token .. ";S" .. BEL
end

---@return string
function Framing:end_prefix()
    return OSC .. self.token .. ";E:"
end

---@param bytes string
---@return string
function Framing.escape_bytes(bytes)
    local escaped = bytes:gsub("\27", "\\e"):gsub("\7", "\\a")
    return escaped
end

---@param command string
---@return string
function Framing:wrap(command)
    local start = Framing.escape_bytes(self:start_marker())
    local ending = Framing.escape_bytes(self:end_prefix())
    return ('builtin printf \'%%b\' %s; builtin eval %s; set -l __pi_shell_status $status; set -l __pi_shell_cwd (builtin string escape --style=url -- "$PWD"); builtin printf \'%%b%%s:%%s%%b\' %s "$__pi_shell_status" "$__pi_shell_cwd" %s\n'):format(
        Framing.quote_fish(start),
        Framing.quote_fish(command),
        Framing.quote_fish(ending),
        Framing.quote_fish("\\a")
    )
end

---@param value string
---@return string?
local function unescape_url(value)
    if value:gsub("%%[%x][%x]", ""):find("%", 1, true) then
        return nil
    end
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

---@param bytes string
---@return table[] events `{ type = "output", bytes = string }` or `{ type = "end", status = integer, cwd? = string }`
function Framing:feed(bytes)
    self._bytes = self._bytes .. bytes
    local events = {}
    local start_marker = self:start_marker()
    local end_prefix = self:end_prefix()
    while true do
        if not self._active then
            local start = self._bytes:find(start_marker, 1, true)
            if not start then
                self._bytes = self._bytes:sub(math.max(1, #self._bytes - #start_marker + 1))
                break
            end
            self._bytes = self._bytes:sub(start + #start_marker)
            self._active = true
        end
        local finish = self._bytes:find(end_prefix, 1, true)
        if not finish then
            local keep = #end_prefix + 16
            if #self._bytes > keep then
                events[#events + 1] = { type = "output", bytes = self._bytes:sub(1, #self._bytes - keep) }
                self._bytes = self._bytes:sub(#self._bytes - keep + 1)
            end
            break
        end
        if finish > 1 then
            events[#events + 1] = { type = "output", bytes = self._bytes:sub(1, finish - 1) }
        end
        local status_start = finish + #end_prefix
        local stop = self._bytes:find(BEL, status_start, true)
        if not stop then
            self._bytes = self._bytes:sub(finish)
            break
        end
        local payload = self._bytes:sub(status_start, stop - 1)
        local status_text, escaped_cwd = payload:match("^(%-?%d+):(.*)$")
        local event = { type = "end", status = tonumber(status_text or payload) or 1 }
        if escaped_cwd then
            event.cwd = unescape_url(escaped_cwd)
        end
        events[#events + 1] = event
        self._bytes = self._bytes:sub(stop + 1)
        self._active = false
    end
    return events
end

return Framing
