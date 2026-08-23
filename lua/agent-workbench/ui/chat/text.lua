--- Pure string helpers for single-line thinking preview truncation.
--- Extracted from history.lua for unit-testability.

local M = {}

--- Collapse thinking lines into a single whitespace-normalized string.
---@param lines string[]
---@return string
function M.thinking_flat(lines)
    local s = table.concat(lines, " ")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

---@class agent_workbench.ThinkingPreviewChunk
---@field text string
---@field style? "strong"|"emphasis"|"strikethrough"|"inline_code"

local inline_patterns = {
    { pattern = "%*%*(.-)%*%*", style = "strong" },
    { pattern = "__(.-)__", style = "strong" },
    { pattern = "~~(.-)~~", style = "strikethrough" },
    { pattern = "`([^`]-)`", style = "inline_code" },
    { pattern = "%*([^*]-)%*", style = "emphasis" },
    { pattern = "_([^_]-)_", style = "emphasis" },
}

---@param chunks agent_workbench.ThinkingPreviewChunk[]
---@param text string
---@param style? "strong"|"emphasis"|"strikethrough"|"inline_code"
local function append_preview_chunk(chunks, text, style)
    if text == "" then
        return
    end
    local previous = chunks[#chunks]
    if previous and previous.style == style then
        previous.text = previous.text .. text
    else
        chunks[#chunks + 1] = { text = text, style = style }
    end
end

--- Parse the small inline-Markdown subset used by model thinking summaries.
--- Thinking stays a structural block and never enters the Markdown parser.
---@param text string
---@return agent_workbench.ThinkingPreviewChunk[]
function M.thinking_inline_chunks(text)
    local chunks = {}
    local cursor = 1
    while cursor <= #text do
        local best_start, best_end, best_inner, best_style
        for _, candidate in ipairs(inline_patterns) do
            local start_col, end_col, inner = text:find(candidate.pattern, cursor)
            if
                start_col
                and inner ~= ""
                and (not best_start or start_col < best_start or (start_col == best_start and end_col > best_end))
            then
                best_start, best_end, best_inner, best_style = start_col, end_col, inner, candidate.style
            end
        end
        if not best_start then
            append_preview_chunk(chunks, text:sub(cursor))
            break
        end
        append_preview_chunk(chunks, text:sub(cursor, best_start - 1))
        append_preview_chunk(chunks, best_inner, best_style)
        cursor = best_end + 1
    end
    return chunks
end

---@param chunks agent_workbench.ThinkingPreviewChunk[]
---@return integer
local function preview_width(chunks)
    local width = 0
    for _, chunk in ipairs(chunks) do
        width = width + vim.fn.strdisplaywidth(chunk.text)
    end
    return width
end

---@param chunks agent_workbench.ThinkingPreviewChunk[]
---@param w integer
---@return agent_workbench.ThinkingPreviewChunk[]
local function preview_head(chunks, w)
    if preview_width(chunks) <= w then
        return chunks
    end
    if w <= 1 then
        return { { text = "…" } }
    end
    local result = {}
    local remaining = w - 1
    for _, chunk in ipairs(chunks) do
        local kept = ""
        local index = 1
        while index <= #chunk.text do
            local length = M.utf8_len(chunk.text:byte(index))
            local char = chunk.text:sub(index, index + length - 1)
            local char_width = vim.fn.strdisplaywidth(char)
            if char_width > remaining then
                break
            end
            kept = kept .. char
            remaining = remaining - char_width
            index = index + length
        end
        append_preview_chunk(result, kept, chunk.style)
        if index <= #chunk.text or remaining <= 0 then
            break
        end
    end
    append_preview_chunk(result, "…")
    return result
end

---@param chunks agent_workbench.ThinkingPreviewChunk[]
---@param w integer
---@return agent_workbench.ThinkingPreviewChunk[]
local function preview_tail(chunks, w)
    if w <= 0 then
        return {}
    end
    if preview_width(chunks) <= w then
        return chunks
    end
    local result = {}
    local remaining = w
    for chunk_index = #chunks, 1, -1 do
        local chunk = chunks[chunk_index]
        local start_byte = #chunk.text + 1
        local index = #chunk.text
        while index >= 1 do
            local char_start = index
            while char_start > 1 and chunk.text:byte(char_start) >= 0x80 and chunk.text:byte(char_start) <= 0xbf do
                char_start = char_start - 1
            end
            local char_width = vim.fn.strdisplaywidth(chunk.text:sub(char_start, index))
            if char_width > remaining then
                break
            end
            remaining = remaining - char_width
            start_byte = char_start
            index = char_start - 1
        end
        if start_byte <= #chunk.text then
            table.insert(result, 1, { text = chunk.text:sub(start_byte), style = chunk.style })
        end
        if index >= 1 or remaining <= 0 then
            break
        end
    end
    return result
end

---@param text string
---@param w integer
---@return agent_workbench.ThinkingPreviewChunk[]
function M.thinking_preview_head(text, w)
    return preview_head(M.thinking_inline_chunks(text), w)
end

---@param text string
---@param w integer
---@return agent_workbench.ThinkingPreviewChunk[]
function M.thinking_preview_tail(text, w)
    return preview_tail(M.thinking_inline_chunks(text), w)
end

--- Length in bytes of the utf-8 char starting at byte index i.
---@param b integer
---@return integer
function M.utf8_len(b)
    if b < 0x80 then
        return 1
    elseif b < 0xe0 then
        return 2
    elseif b < 0xf0 then
        return 3
    else
        return 4
    end
end

--- Keep the leading slice of s that fits in w display columns; append "…" if cut.
---@param s string
---@param w integer
---@return string
function M.thinking_head(s, w)
    local dw = vim.fn.strdisplaywidth
    if dw(s) <= w then
        return s
    end
    if w <= 1 then
        return "…"
    end
    local target = w - 1
    local acc, end_byte, i, n = 0, 0, 1, #s
    while i <= n do
        local len = M.utf8_len(s:byte(i))
        local cw = dw(s:sub(i, i + len - 1))
        if acc + cw > target then
            break
        end
        acc = acc + cw
        end_byte = i + len - 1
        i = i + len
    end
    return s:sub(1, end_byte) .. "…"
end

--- Hard-wrap one line into chunks of at most `w` display columns.
---
--- Error blocks put a rail/indent on every buffer line via extmarks; a soft
--- (window) wrap would leave continuation screen lines at column 0 with no
--- rail, breaking the block apart. Wrapping here makes every screen line a
--- real buffer line. Width uses strdisplaywidth (tab-aware, column-relative);
--- a single char wider than `w` is placed on a line of its own.
---@param s string
---@param w integer
---@return string[]
function M.wrap(s, w)
    local dw = vim.fn.strdisplaywidth
    if w <= 0 or dw(s) <= w then
        return { s }
    end
    local chunks, cur, cur_w = {}, "", 0
    local i, n = 1, #s
    while i <= n do
        local len = M.utf8_len(s:byte(i))
        local ch = s:sub(i, i + len - 1)
        local cw = dw(ch, cur_w)
        if cur_w + cw > w and cur ~= "" then
            chunks[#chunks + 1] = cur
            cur, cur_w = "", 0
            cw = dw(ch, 0)
        end
        cur = cur .. ch
        cur_w = cur_w + cw
        i = i + len
    end
    if cur ~= "" then
        chunks[#chunks + 1] = cur
    end
    return chunks
end

--- Keep the trailing slice of s that fits in w display columns (rolling window).
---@param s string
---@param w integer
---@return string
function M.thinking_tail(s, w)
    local dw = vim.fn.strdisplaywidth
    if w <= 0 then
        return ""
    end
    if dw(s) <= w then
        return s
    end
    local acc, start_byte, i = 0, #s + 1, #s
    while i >= 1 do
        -- walk back to the start byte of the char ending at i
        -- (range check = UTF-8 continuation byte; avoids Lua 5.3 bitwise `&`,
        -- which the LuaJIT bundled with Neovim stable releases cannot parse)
        local cs = i
        while cs > 1 and s:byte(cs) >= 0x80 and s:byte(cs) <= 0xbf do
            cs = cs - 1
        end
        local cw = dw(s:sub(cs, i))
        if acc + cw > w then
            break
        end
        acc = acc + cw
        start_byte = cs
        i = cs - 1
    end
    return s:sub(start_byte)
end

return M
