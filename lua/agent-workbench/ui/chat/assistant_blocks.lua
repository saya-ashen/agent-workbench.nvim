--- Visual boundaries for assistant Markdown text segments.

local M = {}

local Config = require("agent-workbench.config")

local ns = vim.api.nvim_create_namespace("agent-workbench/assistant-blocks")

---@class agent_workbench.AssistantTextBlock
---@field buffer integer
---@field anchor integer
---@field line_count integer
---@field border string
---@field rail_extmarks integer[]
---@field complete boolean

---@return boolean enabled
---@return string border
local function options()
    local render = Config.options.render or {}
    local config = render.assistant_blocks or {}
    if config.enabled == false then
        return false, ""
    end
    local border = type(config.border) == "string" and config.border or "│"
    return border ~= "", border
end

---@param block agent_workbench.AssistantTextBlock
---@param first_line integer 1-indexed source line
---@param last_line integer 1-indexed source line
local function add_rails(block, first_line, last_line)
    if first_line > last_line then
        return
    end
    local anchor = vim.api.nvim_buf_get_extmark_by_id(block.buffer, ns, block.anchor, {})
    local start_row = anchor[1]
    if start_row == nil then
        return
    end
    for line = first_line, last_line do
        local id = vim.api.nvim_buf_set_extmark(block.buffer, ns, start_row + line - 1, 0, {
            right_gravity = false,
            strict = false,
            virt_text = { { block.border .. " ", "PiAssistantBlockBorder" } },
            virt_text_pos = "inline",
            hl_mode = "combine",
            priority = 110,
        })
        block.rail_extmarks[#block.rail_extmarks + 1] = id
    end
end

---@param text string
---@return integer
local function line_count(text)
    local _, newlines = text:gsub("\n", "")
    return newlines + 1
end

---@param buf integer
---@param row integer
---@param source string
---@return agent_workbench.AssistantTextBlock?
function M.start(buf, row, source)
    local enabled, border = options()
    if not enabled or source == "" or not vim.api.nvim_buf_is_valid(buf) then
        return nil
    end
    local block = {
        buffer = buf,
        anchor = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
            right_gravity = false,
            strict = false,
        }),
        line_count = line_count(source),
        border = border,
        rail_extmarks = {},
        complete = false,
    }
    add_rails(block, 1, block.line_count)
    return block
end

---@param block agent_workbench.AssistantTextBlock?
---@param chunk string
function M.append(block, chunk)
    if not block or block.complete or chunk == "" then
        return
    end
    local _, added_lines = chunk:gsub("\n", "")
    if added_lines == 0 then
        return
    end
    local previous = block.line_count
    block.line_count = previous + added_lines
    add_rails(block, previous + 1, block.line_count)
end

---@param block agent_workbench.AssistantTextBlock?
function M.finish(block)
    if block then
        block.complete = true
    end
end

---@param buf integer
function M.reset(buf)
    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
end

M._namespace = ns

return M
