local M = {}

local Config = require("agent-workbench.config")

---@class agent_workbench.SessionInfo
---@field id string            session id from header
---@field path string          absolute path to .jsonl file
---@field timestamp string     ISO timestamp from header
---@field modified number      file mtime (for sorting)
---@field first_message string first user message (truncated)
---@field name? string         display name from session_info entry

--- Resolve the pi agent directory.
---@return string
local function get_agent_dir()
    if Config.options.agent_dir then
        return Config.options.agent_dir
    end
    local env = vim.env.PI_CODING_AGENT_DIR
    if env and env ~= "" then
        return env
    end
    return vim.fn.expand("~/.pi/agent")
end

---@param ... string
---@return string
local function join_path(...)
    local parts = { ... }
    local path = parts[1] or ""
    local sep = package.config:sub(1, 1)
    for i = 2, #parts do
        local part = parts[i] or ""
        if part ~= "" then
            path = path:gsub("[\\/]+$", "") .. sep .. part:gsub("^[\\/]+", "")
        end
    end
    return path
end

--- Encode a cwd path into the directory name format pi uses.
--- e.g. "/Users/Alex/Dev/project" → "--Users-Alex-Dev-project--"
--- e.g. "C:\\Users\\Alex\\Dev\\project" → "--C--Users-Alex-Dev-project--"
---@param cwd string
---@return string
local function encode_cwd(cwd)
    local encoded = cwd:gsub("^[\\/]", ""):gsub("[\\/:]", "-")
    return "--" .. encoded .. "--"
end

--- Get the sessions directory for a cwd (current cwd by default).
---@param cwd? string
---@return string
function M.get_sessions_dir(cwd)
    local agent_dir = get_agent_dir()
    cwd = cwd or vim.fn.getcwd()
    return join_path(agent_dir, "sessions", encode_cwd(cwd))
end

--- Decode a line if it is a `session_info` entry carrying a non-empty name.
---@param line string
---@return string? name trimmed display name, or nil
local function session_info_name(line)
    if not line:find('"session_info"', 1, true) then
        return nil
    end
    local lok, entry = pcall(vim.json.decode, line)
    if lok and entry and entry.type == "session_info" and type(entry.name) == "string" and entry.name ~= "" then
        return entry.name:match("^%s*(.-)%s*$") -- trim
    end
    return nil
end

--- Parse a .jsonl session file: read header + first user message + latest name.
---@param path string
---@return agent_workbench.SessionInfo?
function M.parse(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local header_line = file:read("*l")
    if not header_line or header_line == "" then
        file:close()
        return nil
    end
    local ok, header = pcall(vim.json.decode, header_line)
    if not ok or not header or header.type ~= "session" then
        file:close()
        return nil
    end

    -- Single forward pass over the buffered file. The first user message sits
    -- near the top, so stop decoding message lines once it is found. The latest
    -- session name can appear anywhere (latest wins), so every line is visited,
    -- but only rare, small `session_info` lines are JSON-decoded — huge message
    -- and tool-output lines are skipped via a cheap substring prefilter. This
    -- keeps listing I/O-bound rather than decode-bound for multi-MB sessions
    -- (the previous full JSON-decode of every line made it take many seconds).
    local first_message = ""
    local name = nil
    for line in file:lines() do
        if first_message == "" and line:find('"message"', 1, true) then
            local lok, entry = pcall(vim.json.decode, line)
            if lok and entry and entry.type == "message" then
                local msg = entry.message
                if msg and msg.role == "user" then
                    local content = msg.content
                    if type(content) == "string" then
                        first_message = content
                    elseif type(content) == "table" then
                        for _, part in ipairs(content) do
                            if type(part) == "table" and part.type == "text" then
                                first_message = part.text or ""
                                break
                            end
                        end
                    end
                end
            end
        end
        local entry_name = session_info_name(line)
        if entry_name then
            name = entry_name
        end
    end
    file:close()

    -- Truncate to single line, max 80 chars
    first_message = first_message:gsub("\n", " "):sub(1, 80)

    return {
        path = path,
        id = header.id or "",
        timestamp = header.timestamp or "",
        modified = vim.fn.getftime(path),
        first_message = first_message,
        name = name,
    }
end

---@class agent_workbench.SessionPreview
---@field messages table[] active-branch messages in the same shape as RPC get_messages
---@field leaf_id string

---@param entry table
---@return table[]
local function entry_messages(entry)
    if entry.type == "message" and type(entry.message) == "table" then
        local message = entry.message
        if
            (message.role == "user" or message.role == "assistant" or message.role == "toolResult")
            and message.content == nil
        then
            message = vim.tbl_extend("force", message, { content = {} })
        end
        return { message }
    end
    if entry.type == "custom_message" then
        return {
            {
                role = "custom",
                customType = entry.customType,
                content = entry.content or {},
                display = entry.display,
                details = entry.details,
                timestamp = entry.timestamp,
            },
        }
    end
    if entry.type == "branch_summary" and type(entry.summary) == "string" and entry.summary ~= "" then
        return {
            {
                role = "branchSummary",
                summary = entry.summary,
                fromId = entry.fromId,
                timestamp = entry.timestamp,
            },
        }
    end
    if entry.type == "compaction" then
        return {
            {
                role = "compactionSummary",
                summary = entry.summary or "",
                tokensBefore = entry.tokensBefore or 0,
                timestamp = entry.timestamp,
            },
        }
    end
    return {}
end

--- Read the active conversation directly from a persisted v2/v3 session.
--- This is a read-only preview; RPC remains authoritative after startup.
---@param path string
---@return agent_workbench.SessionPreview?
function M.load_messages(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local header_line = file:read("*l")
    local ok, header = pcall(vim.json.decode, header_line or "")
    if not ok or type(header) ~= "table" or header.type ~= "session" or (tonumber(header.version) or 1) < 2 then
        file:close()
        return nil
    end

    local entries = {}
    local by_id = {}
    local leaf_id
    for line in file:lines() do
        local decoded, entry = pcall(vim.json.decode, line)
        if not decoded or type(entry) ~= "table" or type(entry.id) ~= "string" or entry.id == "" then
            file:close()
            return nil
        end
        entries[#entries + 1] = entry
        by_id[entry.id] = entry
        leaf_id = entry.id
    end
    file:close()

    if not leaf_id then
        return { messages = {}, leaf_id = "" }
    end

    local path_entries = {}
    local seen = {}
    local current_id = leaf_id
    while current_id do
        if seen[current_id] then
            return nil
        end
        seen[current_id] = true
        local entry = by_id[current_id]
        if not entry then
            return nil
        end
        table.insert(path_entries, 1, entry)
        current_id = type(entry.parentId) == "string" and entry.parentId or nil
    end

    local latest_compaction_index
    for i, entry in ipairs(path_entries) do
        if entry.type == "compaction" then
            latest_compaction_index = i
        end
    end

    local selected = path_entries
    local retained_tail
    if latest_compaction_index then
        local compaction = path_entries[latest_compaction_index]
        selected = { compaction }
        if type(compaction.retainedTail) == "table" then
            retained_tail = compaction.retainedTail
        else
            local keep = false
            for i = 1, latest_compaction_index - 1 do
                local entry = path_entries[i]
                if entry.id == compaction.firstKeptEntryId then
                    keep = true
                end
                if keep then
                    selected[#selected + 1] = entry
                end
            end
        end
        for i = latest_compaction_index + 1, #path_entries do
            selected[#selected + 1] = path_entries[i]
        end
    end

    local messages = {}
    for _, entry in ipairs(selected) do
        for _, message in ipairs(entry_messages(entry)) do
            messages[#messages + 1] = message
        end
        if entry.type == "compaction" and retained_tail then
            for _, message in ipairs(retained_tail) do
                if type(message) == "table" then
                    messages[#messages + 1] = message
                end
            end
        end
    end

    return { messages = messages, leaf_id = leaf_id }
end

--- List all sessions for a cwd (current cwd by default), newest first.
---@param cwd? string
---@return agent_workbench.SessionInfo[]
function M.list(cwd)
    local dir = M.get_sessions_dir(cwd)
    ---@type string[]
    local files = vim.fn.glob(join_path(dir, "*.jsonl"), false, true)
    ---@type agent_workbench.SessionInfo[]
    local sessions = {}
    for _, file in ipairs(files) do
        local info = M.parse(file)
        if info then
            sessions[#sessions + 1] = info
        end
    end
    table.sort(sessions, function(a, b)
        return a.modified > b.modified
    end)
    return sessions
end

return M
