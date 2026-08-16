local M = {}

local INPUT_PREFIX = "  "
local MAX_ITEMS = 256
local GENERIC_DESCRIPTIONS = {
    ["command"] = true,
    ["command link"] = true,
}

---@class pi.ShellCompletionContext
---@field commandline string
---@field base string
---@field start_col integer 1-based byte column for complete()

---@param lines string[]
---@param input_start integer 1-based row
---@param cursor integer[] `{ row, 0-based byte column }`
---@return pi.ShellCompletionContext?
function M.context(lines, input_start, cursor)
    local cursor_row, cursor_col = cursor[1], cursor[2]
    if cursor_row < input_start or cursor_row > #lines then
        return nil
    end

    local command_lines = {}
    for row = input_start, cursor_row do
        local line = lines[row] or ""
        if row == cursor_row then
            line = line:sub(1, cursor_col)
        end
        if row == input_start and line:sub(1, #INPUT_PREFIX) == INPUT_PREFIX then
            line = line:sub(#INPUT_PREFIX + 1)
        end
        command_lines[#command_lines + 1] = line
    end
    local commandline = table.concat(command_lines, "\n")
    local token_start = 1
    local quote
    local escaped = false
    local row_start = 1
    for index = 1, #commandline do
        local char = commandline:sub(index, index)
        if escaped then
            escaped = false
        elseif quote == "'" then
            if char == "'" then
                quote = nil
            end
        elseif quote == '"' then
            if char == '"' then
                quote = nil
            elseif char == "\\" then
                escaped = true
            end
        elseif char == "\\" then
            escaped = true
        elseif char == "'" or char == '"' then
            quote = char
        elseif char:match("[%s;|&<>()]") then
            token_start = index + 1
        end
        if char == "\n" then
            row_start = index + 1
        end
    end
    if token_start < row_start then
        -- ponytail: native complete() cannot replace a token spanning rows; add extmark insertion if this becomes common.
        return nil
    end

    local prefix = cursor_row == input_start and #INPUT_PREFIX or 0
    return {
        commandline = commandline,
        base = commandline:sub(token_start),
        start_col = token_start - row_start + prefix + 1,
    }
end

---@param output string
---@param current? string
---@return table[] complete()-compatible items
function M.parse(output, current)
    local items = {}
    local found_current = false
    local normalized = output:gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in vim.gsplit(normalized, "\n", { plain = true, trimempty = true }) do
        local word, description = line:match("^(.-)\t(.*)$")
        word = word or line
        if word == current then
            found_current = true
        end
        if description and GENERIC_DESCRIPTIONS[description:lower()] then
            description = nil
        end
        if word ~= "" then
            items[#items + 1] = {
                word = word,
                abbr = word,
                menu = description and description ~= "" and ("[fish] " .. description) or "[fish]",
                dup = 0,
            }
            if #items >= MAX_ITEMS then
                break
            end
        end
    end
    if current and #current > 1 and current:sub(1, 1) == "-" and not found_current then
        local item = { word = current, abbr = current, menu = "[fish]", dup = 0 }
        if current:sub(1, 2) == "--" then
            items[#items + 1] = item
        else
            table.insert(items, 1, item)
        end
    end
    return items
end

---@param output string
---@param current? string
---@param parent_output? string
---@return table[] complete()-compatible items
function M.parse_with_parent(output, current, parent_output)
    local items = M.parse(output, current)
    if not current or not parent_output or current:sub(1, 1) ~= "-" then
        return items
    end
    local parent_item = vim.tbl_filter(function(item)
        return item.word == current and item.menu ~= "[fish]"
    end, M.parse(parent_output))[1]
    if not parent_item then
        return items
    end
    for _, item in ipairs(items) do
        if item.word == current and item.menu == "[fish]" then
            item.menu = parent_item.menu
            break
        end
    end
    return items
end

return M
