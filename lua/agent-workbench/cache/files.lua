--- Shared file listing with cache for completion and mention validation.
---
--- Refresh is asynchronous (stale-while-revalidate): once a cache exists for
--- the current cwd, readers never block — an expired cache is returned
--- immediately while a single background refresh repopulates it. Only the
--- first (cold) call per cwd fetches synchronously.

---@class agent_workbench.FileCache
---@field files string[]
---@field map table<string, true>
---@field cwd string
---@field timestamp number

local M = {}

---@type agent_workbench.FileCache?
local cache = nil

--- Single-flight guard for the async refresh.
local refreshing = false

--- Number of async refreshes initiated (test observability).
local refresh_spawns = 0

local CACHE_TTL_NS = 5e9 -- 5 seconds

local GIT_LS_FILES_ARGS = { "git", "ls-files", "--cached", "--others", "--exclude-standard" }

--- Check if a buffer is a pi prompt buffer.
---@param buf? integer
---@return boolean
function M.is_pi_prompt_buf(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local ft = require("agent-workbench.filetypes")
    return vim.bo[buf].filetype == ft.prompt
end

--- Build and store the cache.
---@param files string[]
---@param cwd string
local function store(files, cwd)
    local map = {}
    for _, f in ipairs(files) do
        map[f] = true
    end
    cache = { files = files, map = map, cwd = cwd, timestamp = vim.uv.hrtime() }
end

--- Parse `git ls-files` stdout into a file list.
---@param stdout string
---@return string[]
local function parse_ls_files(stdout)
    if stdout == "" then
        return {}
    end
    return vim.split(vim.trim(stdout), "\n", { plain = true, trimempty = true })
end

--- Synchronous listing fallback for non-git directories.
--- Must run on the main loop (uses vim.fn).
---@return string[]
local function glob_files()
    local files = {}
    local raw = vim.fn.glob("**/*", false, true)
    for _, f in ipairs(raw) do
        if vim.fn.isdirectory(f) == 0 then
            files[#files + 1] = f
        end
    end
    return files
end

--- True if the cache is missing, for another cwd, or past its TTL.
---@param cwd string
---@return boolean
local function is_stale(cwd)
    return not cache or cache.cwd ~= cwd or (vim.uv.hrtime() - cache.timestamp) >= CACHE_TTL_NS
end

--- Refresh the cache asynchronously (single-flight).
--- No-op if a refresh is already in flight. The result is dropped if the
--- cwd changes before it lands.
---@param cwd? string defaults to the current cwd
function M.refresh(cwd)
    cwd = cwd or vim.fn.getcwd()
    if refreshing then
        return
    end
    refreshing = true
    refresh_spawns = refresh_spawns + 1

    -- Defer the process spawn to the next event loop turn: uv spawn itself
    -- costs a few ms, and readers on the expired path should pay nothing.
    vim.schedule(function()
        local ok, err = pcall(vim.system, GIT_LS_FILES_ARGS, { text = true, cwd = cwd }, function(result)
            -- uv callback: fast event context. All vim.fn / API work must
            -- be deferred to the main loop.
            vim.schedule(function()
                refreshing = false
                if vim.fn.getcwd() ~= cwd then
                    return -- cwd changed; the next reader will refetch
                end
                if result.code == 0 and result.stdout and result.stdout ~= "" then
                    store(parse_ls_files(result.stdout), cwd)
                else
                    store(glob_files(), cwd)
                end
            end)
        end)
        if not ok then
            refreshing = false
            require("agent-workbench.notify").warn("file cache refresh failed to start: " .. tostring(err))
        end
    end)
end

--- Get project files (relative paths).
--- Returns the cached list immediately when one exists for the current cwd;
--- if it is expired, a background refresh is kicked off and the stale list is
--- returned (stale-while-revalidate). Only the first call per cwd blocks on
--- a synchronous fetch.
---@return string[]
function M.list()
    local cwd = vim.fn.getcwd()
    if cache and cache.cwd == cwd then
        if is_stale(cwd) then
            M.refresh(cwd)
        end
        return cache.files
    end
    return M._fetch_sync(cwd)
end

--- Synchronous cold-start fetch. Blocks the main loop; used only when no
--- cache exists for the cwd.
---@param cwd string
---@return string[]
function M._fetch_sync(cwd)
    local result = vim.system(GIT_LS_FILES_ARGS, { text = true, cwd = cwd }):wait()
    local files
    if result.code == 0 and result.stdout and result.stdout ~= "" then
        files = parse_ls_files(result.stdout)
    else
        files = glob_files()
    end
    store(files, cwd)
    return files
end

--- Check if a relative path exists in the project.
--- Never blocks: on a cold or expired cache it kicks off an async refresh
--- and answers from the (possibly stale) map plus an on-disk fallback.
---@param path string
---@return boolean
function M.exists(path)
    if is_stale(vim.fn.getcwd()) then
        M.refresh()
    end
    if cache and cache.map[path] then
        return true
    end
    local abs = vim.fn.fnamemodify(path, ":p")
    return vim.fn.filereadable(abs) == 1 or vim.fn.isdirectory(abs) == 1
end

--- Invalidate the cache. The next `list()` performs a synchronous cold fetch.
function M.invalidate()
    cache = nil
end

--- Current cache entry, if any (test observability).
---@return agent_workbench.FileCache?
function M._cache()
    return cache
end

--- Force the cache into the expired state (tests only).
function M._expire()
    if cache then
        cache.timestamp = 0
    end
end

--- Number of async refreshes spawned since the last reset (tests only).
---@return integer
function M._refresh_spawns()
    return refresh_spawns
end

--- Reset all state (tests only).
function M._reset()
    cache = nil
    refreshing = false
    refresh_spawns = 0
end

return M
