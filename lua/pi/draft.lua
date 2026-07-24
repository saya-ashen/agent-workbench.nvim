--- Unsent-prompt draft persistence.
--
-- The prompt buffer already survives layout toggles and tab switches within a
-- session, but an unsent draft is lost when Neovim restarts. This module saves
-- the draft to disk (debounced by the caller) and restores it once per Neovim
-- process, so a restart brings back what you were typing — without re-restoring
-- a stale draft on every in-session `:PiNewSession`.

local M = {}

-- Whether a restore has already been attempted this process.
local restored = false

-- Test hook: override the draft file location (nil => default stdpath).
local path_override = nil

---@param p string?
function M._set_path(p)
    path_override = p
end

---@return string
local function draft_path()
    return path_override or (vim.fn.stdpath("data") .. "/pi/draft.txt")
end

--- Persist the current draft text. An empty string clears the stored draft.
---@param text string
function M.save(text)
    local p = draft_path()
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

---@return string? the stored draft, or nil when there is none
function M.load()
    local f = io.open(draft_path(), "r")
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

--- Remove the stored draft.
function M.clear()
    os.remove(draft_path())
end

--- Return the stored draft at most once per process. The first call consumes
--- the "once" slot; later calls in the same process return nil (so an
--- in-session `:PiNewSession` doesn't re-restore a stale draft). The stored
--- file is left in place — the caller's continuous save keeps it current and
--- clears it when the draft is sent, so an unsent draft survives restarts.
---@return string?
function M.restore_once()
    if restored then
        return nil
    end
    restored = true
    return M.load()
end

--- Reset module state (used by tests).
function M._reset()
    restored = false
end

return M
