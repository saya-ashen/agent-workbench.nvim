--- Unsent-prompt draft persistence.
--
-- Drafts are scoped by workspace and Neovim process. Live processes never
-- restore or overwrite each other's drafts; a later process can claim a draft
-- left by a process that exited.

local M = {}

---@type table<string, boolean>
local restored = {}

-- Test hook: a string keeps the legacy single-file behavior; a function can
-- isolate workspace/process paths while exercising recovery logic.
---@alias pi.DraftPathOverride string|fun(cwd: string, pid: integer): string
---@type pi.DraftPathOverride?
local path_override = nil

---@param p? pi.DraftPathOverride
function M._set_path(p)
    path_override = p
end

---@param cwd string?
---@return string
local function normalize_cwd(cwd)
    return vim.fs.normalize(cwd or vim.uv.cwd() or "")
end

---@param cwd string
---@param pid integer
---@return string
local function draft_path(cwd, pid)
    if type(path_override) == "function" then
        return path_override(cwd, pid)
    end
    if path_override then
        return path_override
    end
    local workspace = vim.fn.sha256(cwd)
    return ("%s/pi/drafts/%s/%d.txt"):format(vim.fn.stdpath("data"), workspace, pid)
end

---@param path string
---@return string?
local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    if content == nil or content == "" then
        return nil
    end
    return content
end

---@param pid integer
---@return boolean
local function process_alive(pid)
    return vim.uv.kill(pid, 0) == 0
end

---@param cwd string
---@return string[]
local function recovery_candidates(cwd)
    if type(path_override) == "string" then
        return { path_override }
    end
    local current = draft_path(cwd, vim.fn.getpid())
    local paths = vim.fn.globpath(vim.fn.fnamemodify(current, ":h"), "*.txt", false, true)
    table.sort(paths, function(a, b)
        return vim.fn.getftime(a) > vim.fn.getftime(b)
    end)
    return paths
end

--- Persist current draft text. Empty text clears this process's stored draft.
---@param text string
---@param cwd? string
function M.save(text, cwd)
    local p = draft_path(normalize_cwd(cwd), vim.fn.getpid())
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    if text == nil or text == "" then
        os.remove(p)
        return
    end
    local f = io.open(p, "w")
    if not f then
        return
    end
    f:write(text)
    f:close()
end

---@param cwd? string
---@return string? the current process's stored draft, or nil when there is none
function M.load(cwd)
    return read_file(draft_path(normalize_cwd(cwd), vim.fn.getpid()))
end

--- Remove current process's stored draft.
---@param cwd? string
function M.clear(cwd)
    os.remove(draft_path(normalize_cwd(cwd), vim.fn.getpid()))
end

--- Restore at most one draft per workspace in this process. Drafts owned by
--- live Neovim processes are ignored. A stale draft is atomically claimed by
--- renaming it to this process's path before reading it.
---@param cwd? string
---@return string?
function M.restore_once(cwd)
    cwd = normalize_cwd(cwd)
    if restored[cwd] then
        return nil
    end
    restored[cwd] = true

    local current = draft_path(cwd, vim.fn.getpid())
    local content = read_file(current)
    if content then
        return content
    end

    for _, path in ipairs(recovery_candidates(cwd)) do
        local pid = tonumber(vim.fs.basename(path):match("^(%d+)%.txt$"))
        if path ~= current and pid and not process_alive(pid) and os.rename(path, current) then
            content = read_file(current)
            if content then
                return content
            end
            os.remove(current)
        end
    end
    return nil
end

--- Reset module state (used by tests).
function M._reset()
    restored = {}
end

return M
