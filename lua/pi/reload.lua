--- Buffer reload logic: syncs open Neovim buffers after pi modifies files on disk.

local Notify = require("pi.notify")

local M = {}

---@class pi.ReloadResult
---@field reloaded string[] Paths whose buffers were reloaded silently.
---@field skipped string[] Paths whose buffers were skipped (modified by user).

--- Reload all loaded, unmodified buffers whose file matches any of the given paths.
--- Modified buffers are never touched. Returns a summary of what happened.
---@param paths string[] Absolute or relative file paths that pi just modified.
---@return pi.ReloadResult
function M.reload_buffers(paths)
    ---@type string[]
    local reloaded = {}
    ---@type string[]
    local skipped = {}

    for _, raw_path in ipairs(paths) do
        local abs_path = vim.fn.fnamemodify(raw_path, ":p")
        local found = false
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == abs_path then
                found = true
                if vim.bo[buf].modified then
                    skipped[#skipped + 1] = raw_path
                else
                    vim.api.nvim_buf_call(buf, function()
                        vim.cmd("silent edit!")
                    end)
                    reloaded[#reloaded + 1] = raw_path
                end
                break -- one buffer per path is enough
            end
        end
        -- No loaded buffer for this path: nothing to do.
        if not found then
            -- intentionally not tracked
        end
    end

    return { reloaded = reloaded, skipped = skipped }
end

--- Called after a file-changing tool completes. Reads the reload mode from
--- config (never cached) and acts accordingly.
---@param path string The file path that was just modified (as recorded in changed_files).
function M.on_file_changed(path)
    local mode = require("pi.config").options.reload.mode
    if mode == false then
        return
    end

    local result = M.reload_buffers({ path })

    if mode == "notify" then
        if #result.reloaded > 0 then
            Notify.info("Reloaded: " .. table.concat(result.reloaded, ", "))
        end
        if #result.skipped > 0 then
            Notify.warn("Modified (not reloaded): " .. table.concat(result.skipped, ", "))
        end
    end
    -- "silent": no notifications at all
end

return M
