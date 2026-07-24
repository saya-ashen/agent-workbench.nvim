--- Prompt input history with readline-style recall.
--
-- Stores previously submitted prompts (multi-line safe; persisted as JSON) and
-- exposes emacs/readline-style navigation: `prev` walks toward older entries
-- while stashing the in-progress draft, `next` walks back toward the present
-- and finally restores that draft.
--
-- The Store is a plain object so it can be unit-tested without any UI: pass
-- `path = false` for an in-memory store, or a path string to persist to disk.

local M = {}

---@class pi.PromptHistoryStore
---@field _entries string[] oldest first, newest last
---@field _max integer
---@field _path string? nil => in-memory
---@field _nav_index integer? nil => not navigating (at present/draft)
---@field _draft string? stashed in-progress text while navigating
local Store = {}
Store.__index = Store

---@class pi.PromptHistoryOpts
---@field path string|false|nil string => persist here; false/nil => in-memory
---@field max integer?

--- Create a new store.
---@param opts? pi.PromptHistoryOpts
---@return pi.PromptHistoryStore
function Store.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Store)
    self._entries = {}
    self._max = (opts.max and opts.max > 0) and opts.max or 500
    self._path = (type(opts.path) == "string") and opts.path or nil
    self._nav_index = nil
    self._draft = nil
    if self._path then
        self:load()
    end
    return self
end

---@return string[] copy of entries, oldest first
function Store:entries()
    return vim.deepcopy(self._entries)
end

---@return integer
function Store:size()
    return #self._entries
end

--- Add a submitted prompt. Ignores empty/whitespace-only entries and skips an
--- entry identical to the most recent one (readline consecutive-dedupe).
--- Enforces the cap by dropping the oldest. Persists when file-backed.
---@param entry string
function Store:add(entry)
    if type(entry) ~= "string" or vim.trim(entry) == "" then
        return
    end
    if self._entries[#self._entries] == entry then
        -- Consecutive duplicate: don't store again, but a fresh recall should
        -- still start from the newest entry.
        self:_reset_nav()
        return
    end
    table.insert(self._entries, entry)
    while #self._entries > self._max do
        table.remove(self._entries, 1)
    end
    self:_reset_nav()
    self:save()
end

--- Step toward older entries. On the first call, stashes `draft` (the text the
--- user is currently typing) so it can be restored by walking back down.
---@param draft string? current prompt text, stashed on the first call
---@return string? entry to display, or nil if there is nothing older to show
function Store:prev(draft)
    local n = #self._entries
    if n == 0 then
        return nil
    end
    if self._nav_index == nil then
        self._draft = draft or ""
        self._nav_index = n
        return self._entries[n]
    end
    if self._nav_index > 1 then
        self._nav_index = self._nav_index - 1
        return self._entries[self._nav_index]
    end
    return nil -- already at oldest: no change
end

--- Step toward newer entries. When already at the newest entry, leaves
--- navigation mode and restores the stashed draft.
---@return string? entry (or the stashed draft) to display, or nil if no change
function Store:next()
    if self._nav_index == nil then
        return nil
    end
    local n = #self._entries
    if self._nav_index < n then
        self._nav_index = self._nav_index + 1
        return self._entries[self._nav_index]
    end
    local draft = self._draft or ""
    self:_reset_nav()
    return draft
end

---@return boolean whether the user is currently browsing history
function Store:navigating()
    return self._nav_index ~= nil
end

--- Leave navigation mode (e.g. after a send, or when the user edits by hand).
function Store:reset_nav()
    self:_reset_nav()
end

function Store:_reset_nav()
    self._nav_index = nil
    self._draft = nil
end

--- Persist entries to disk (no-op for in-memory stores). Writes atomically via
--- a temp file + rename so a crash mid-write can't corrupt the history.
function Store:save()
    if not self._path then
        return
    end
    local dir = vim.fn.fnamemodify(self._path, ":h")
    vim.fn.mkdir(dir, "p")
    local ok, encoded = pcall(vim.json.encode, self._entries)
    if not ok then
        return
    end
    local tmp = self._path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        return
    end
    f:write(encoded)
    f:close()
    os.rename(tmp, self._path)
end

--- Load entries from disk (no-op for in-memory stores or missing files).
--- Silently ignores corrupt/unreadable files.
function Store:load()
    if not self._path then
        return
    end
    local f = io.open(self._path, "r")
    if not f then
        return
    end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then
        return
    end
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
        return
    end
    local list = {}
    for _, v in ipairs(decoded) do
        if type(v) == "string" and vim.trim(v) ~= "" then
            table.insert(list, v)
        end
    end
    while #list > self._max do
        table.remove(list, 1)
    end
    self._entries = list
end

--- Clear all entries and persist the empty state.
function Store:clear()
    self._entries = {}
    self:_reset_nav()
    self:save()
end

-- ---------------------------------------------------------------------------
-- Process-wide default store
-- ---------------------------------------------------------------------------

local default_store = nil

--- Default history file location.
---@return string
function M.default_path()
    return vim.fn.stdpath("data") .. "/pi/prompt_history.json"
end

--- Get (or lazily create) the process-wide history store.
---@param opts? pi.PromptHistoryOpts
---@return pi.PromptHistoryStore
function M.get(opts)
    if default_store then
        return default_store
    end
    opts = opts or {}
    local path = opts.path
    if path == nil then
        path = M.default_path()
    end
    default_store = Store.new({ path = path, max = opts.max })
    return default_store
end

--- Drop the cached singleton (used by tests and config reloads).
function M._reset()
    default_store = nil
end

M.Store = Store
return M
