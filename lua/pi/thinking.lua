--- Thinking controls: visibility toggle and level selection.

local M = {}

local Notify = require("pi.notify")

---@type string[]
local LEVELS = { "off", "minimal", "low", "medium", "high", "xhigh" }

--- Toggle thinking block visibility.
---@param session pi.Session
function M.toggle(session)
    session.chat:toggle_thinking()
end

--- Send set_thinking_level RPC and refresh state on success.
---@param session pi.Session
---@param level string
function M.set(session, level)
    local Sessions = require("pi.sessions.manager")
    session.rpc:send({ type = "set_thinking_level", level = level }, function(res)
        vim.schedule(function()
            if res.success then
                Sessions.refresh_state(session)
            else
                Notify.warn("Current model does not support thinking")
            end
        end)
    end)
end

--- Cycle to the next thinking level.
---@param session pi.Session
function M.cycle(session)
    local Sessions = require("pi.sessions.manager")
    session.rpc:send({ type = "cycle_thinking_level" }, function(res)
        vim.schedule(function()
            if res.success and res.data then
                Sessions.refresh_state(session)
            else
                Notify.warn("Current model does not support thinking")
            end
        end)
    end)
end

--- Fetch available thinking levels from the backend, then call fn with them.
--- Falls back to the built-in level list when the fetch fails, so the
--- picker stays usable even if the backend call errors.
---@param session pi.Session
---@param fn fun(levels: string[])
function M.with_available(session, fn)
    session.rpc:send({ type = "get_available_thinking_levels" }, function(res)
        vim.schedule(function()
            local levels
            if res.success then
                levels = (res.data or {}).levels or {}
            else
                Notify.warn((res.error or "Failed to fetch thinking levels") .. "; using defaults")
                levels = LEVELS
            end
            if #levels == 0 then
                Notify.warn("Current model does not support thinking")
                return
            end
            fn(levels)
        end)
    end)
end

--- Select a thinking level from a picker (rendered through vim.ui.select).
--- The picker lists only the levels the current model actually supports;
--- the built-in list is used as a fallback if the fetch fails.
---@param session pi.Session
function M.select(session)
    local Dialog = require("pi.ui.dialog")
    M.with_available(session, function(levels)
        Dialog.select({ title = "Thinking level", options = levels, kind = "pi-thinking-level" }, function(choice)
            if not choice then
                return
            end
            M.set(session, choice)
        end)
    end)
end

return M
