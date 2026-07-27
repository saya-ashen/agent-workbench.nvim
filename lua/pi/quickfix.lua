--- Populate the quickfix list from grep/find tool results.
---
--- pi's `grep` tool returns ripgrep-style `path:line: text` lines and its
--- `find` tool (named `glob` in older versions) returns one file path per
--- line. After such a tool completes we parse its result text and fill the
--- quickfix list so the user can jump between matches with |:cnext|/|:cprev|.
--- The quickfix window is never opened automatically; use |:copen| to see it.

local Config = require("pi.config")

local M = {}

--- Tools whose results can populate the quickfix list, mapped to the config
--- key that enables them. `glob` is an alias for `find`.
---@type table<string, string>
local TOOL_CONFIG_KEY = {
    grep = "grep",
    find = "find",
    glob = "glob",
}

--- Pending search-tool args by tool call id, used to build a titled list.
--- tool_execution_end does not carry args, so we stash them on start.
---@type table<string, table>
local pending_args = {}

--- Extract concatenated text from a tool result's content blocks.
---@param result? table
---@return string?
local function result_text(result)
    if not result or not result.content then
        return nil
    end
    local content = result.content
    if type(content) == "string" then
        local trimmed = vim.trim(content)
        return trimmed ~= "" and trimmed or nil
    end
    if type(content) ~= "table" then
        return nil
    end
    local parts = {}
    for _, block in ipairs(content) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
            parts[#parts + 1] = block.text
        elseif type(block) == "string" then
            parts[#parts + 1] = block
        end
    end
    if #parts == 0 then
        return nil
    end
    local trimmed = vim.trim(table.concat(parts, "\n"))
    return trimmed ~= "" and trimmed or nil
end

--- Resolve a possibly-relative path against the current working directory,
--- mirroring the convention used by the diff review module.
---@param path string
---@return string
local function abs(path)
    if vim.startswith(path, "/") then
        return path
    end
    return vim.fn.getcwd() .. "/" .. path
end

--- Parse ripgrep-style grep output into quickfix items.
--- Handles `path:line: text`, `path:line:text`, and `path:line:col:text`.
---@param text string
---@return table[] items quickfix entries ({ filename, lnum, col?, text? })
function M.parse_grep(text)
    ---@type table[]
    local items = {}
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        local path, lnum, sep, rest = line:match("^(.-):(%d+):( ?)(.*)$")
        if path and path ~= "" then
            local col ---@type integer?
            if sep == "" then
                -- No space after the line number: either `path:line:col:text`
                -- or plain `path:line:text` whose text happens to follow.
                local c, t = rest:match("^(%d+):(.*)$")
                if c then
                    col = tonumber(c)
                    rest = t
                end
            end
            items[#items + 1] = {
                filename = abs(path),
                lnum = tonumber(lnum) or 1,
                col = col,
                text = vim.trim(rest),
            }
        end
    end
    return items
end

--- Parse find/glob output (one file path per line) into quickfix items.
---@param text string
---@return table[] items quickfix entries ({ filename, lnum })
function M.parse_files(text)
    ---@type table[]
    local items = {}
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        local path = vim.trim(line)
        if path ~= "" then
            items[#items + 1] = { filename = abs(path), lnum = 1 }
        end
    end
    return items
end

--- Build a quickfix list title from the stashed tool args.
---@param tool_name string
---@param args? table
---@return string
local function build_title(tool_name, args)
    local pattern = args and args.pattern
    if type(pattern) == "string" and pattern ~= "" then
        return "pi " .. tool_name .. ": " .. pattern
    end
    return "pi " .. tool_name
end

--- Record search-tool args so the title can include the pattern. Called on
--- tool_execution_start; pure Lua, safe to call off the main loop.
---@param tool_name string?
---@param tool_call_id string?
---@param args any
function M.on_tool_start(tool_name, tool_call_id, args)
    if not tool_name or not TOOL_CONFIG_KEY[tool_name] then
        return
    end
    if type(tool_call_id) ~= "string" or tool_call_id == "" then
        return
    end
    local decoded = type(args) == "table" and args or nil
    if not decoded and type(args) == "string" and args ~= "" then
        local ok, parsed = pcall(vim.json.decode, args)
        if ok and type(parsed) == "table" then
            decoded = parsed
        end
    end
    if decoded then
        pending_args[tool_call_id] = decoded
    end
end

--- Fill the quickfix list from a completed search-tool result. Reads config at
--- call time (never cached). Must be called on the main loop (uses setqflist).
---@param tool_name string?
---@param tool_call_id string?
---@param result? table
---@param is_error? boolean
function M.on_tool_end(tool_name, tool_call_id, result, is_error)
    if not tool_name or is_error then
        return
    end
    local key = TOOL_CONFIG_KEY[tool_name]
    if not key then
        return
    end

    local args = tool_call_id and pending_args[tool_call_id] or nil
    if tool_call_id then
        pending_args[tool_call_id] = nil
    end

    local quickfix = Config.options.quickfix
    if not quickfix or not quickfix[key] then
        return
    end

    local text = result_text(result)
    if not text then
        return
    end

    local items = tool_name == "grep" and M.parse_grep(text) or M.parse_files(text)
    if #items == 0 then
        return
    end

    vim.fn.setqflist({}, " ", { title = build_title(tool_name, args), items = items })
end

--- Test hook: clear module state.
function M._reset()
    pending_args = {}
end

return M
