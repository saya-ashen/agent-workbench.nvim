--- completefunc fallback for @-mention and /command completion.
--- Triggered via <C-x><C-u> in the pi prompt buffer.

local M = {}

local Matcher = require("pi.completion")
local SlashCommands = require("pi.slash_commands")

---@param findstart integer
---@param base string
---@return integer|table[]
function M.completefunc(findstart, base)
    if findstart == 1 then
        local line = vim.api.nvim_get_current_line()
        local col = vim.fn.col(".") - 1

        -- Check for / at start of line (commands)
        local cursor_row = vim.fn.line(".")
        if cursor_row == 1 and line:byte(1) == 47 then -- /
            return 0
        end

        -- Check for @ (mentions)
        while col > 0 do
            col = col - 1
            local byte = line:byte(col + 1)
            if byte == 64 then -- @
                return col
            end
            if byte == 32 then -- space
                return -3
            end
        end
        return -3
    end

    -- /command completion
    if base:byte(1) == 47 then -- /
        local prefix = base:sub(2)
        return vim.tbl_map(function(cmd)
            return {
                word = "/" .. cmd.name,
                abbr = "/" .. cmd.name,
                menu = "[" .. cmd.source .. "]",
                info = cmd.description or "",
            }
        end, SlashCommands.match(prefix))
    end

    -- @mention completion: dynamic providers first, then project files.
    local prefix = base:sub(2) -- strip @
    local items = Matcher.complete_providers(prefix, function(provider)
        return { word = "@" .. provider.name, kind = "v", menu = "[Pi]", info = provider.description }
    end)
    vim.list_extend(
        items,
        Matcher.complete_files(prefix, function(path)
            return { word = "@" .. path, kind = "f", menu = "[Pi]" }
        end)
    )
    return items
end

return M
