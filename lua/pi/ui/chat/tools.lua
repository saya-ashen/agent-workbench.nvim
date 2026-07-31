--- Tool call rendering for chat history.

local Render = require("pi.ui.render")

local M = {}

M.GLYPHS = {
    FOLD_OPEN = "▾ ",
    FOLD_CLOSE = "▸ ",
    INDENT = "  ",
    -- Legacy aliases for code that references old glyph names
    TOP = "▾ ",
    MID = "  ",
    SEP = "  ",
    BOT = "  ",
}

--- Per-tool nerd font icons (by codepoint so PUA glyphs never get lost in edits).
--- Falls back to config.labels.tool when a tool is not listed.
local nf = function(cp)
    return vim.fn.nr2char(cp, 1)
end
---@type table<string, string>
local TOOL_ICONS = {
    bash = nf(0xE795), -- nf-dev-terminal
    read = nf(0xF0219), -- nf-md-file-document
    edit = nf(0xF03EB), -- nf-md-pencil
    write = nf(0xF0193), -- nf-md-content-save
    grep = nf(0xF0349), -- nf-md-magnify
    glob = nf(0xF024B), -- nf-md-folder
    web_fetch = nf(0xF0593), -- nf-md-web
    web_search = nf(0xF0349), -- nf-md-magnify
}

--- Get the nerd font icon for a tool name.
---@param tool_name string
---@return string
function M.get_tool_icon(tool_name)
    return TOOL_ICONS[tool_name] or require("pi.config").options.labels.tool
end

---@param text string?
---@return string
function M.sanitize_text(text)
    local sanitized = (text or ""):gsub("%z", "␀")
    return sanitized
end

---@param result? table
---@return string?
local function extract_result_text_raw(result)
    if not result or not result.content then
        return nil
    end
    -- Live events: result.content = [{type: "text", text: "..."}]
    -- Replay toolResult: msg.content may be a string or array of strings
    local content = result.content
    if type(content) == "string" then
        local trimmed = vim.trim(M.sanitize_text(content))
        return trimmed ~= "" and trimmed or nil
    end
    if type(content) ~= "table" then
        return nil
    end
    local parts = {}
    for _, block in ipairs(content) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
            parts[#parts + 1] = M.sanitize_text(block.text)
        elseif type(block) == "string" then
            parts[#parts + 1] = M.sanitize_text(block)
        end
    end
    if #parts > 0 then
        return vim.trim(table.concat(parts, "\n"))
    end
    return nil
end

--- Status prefixes that extensions can embed in blocked-tool result text.
--- When a tool_call handler returns { block: true, reason: "[prefix] ..." },
--- the prefix determines the display status and is stripped from output.
---
--- Convention:
---   [accepted] — tool was blocked but the action was applied (e.g. edit approved by user)
---   [rejected] — tool was intentionally refused (by user or by policy)
---   [aborted]  — tool was in-flight when the turn was aborted
---   (no prefix) — fall back to isError boolean
---@type table<string, "completed"|"rejected"|"aborted">
local STATUS_PREFIXES = {
    ["[accepted]"] = "completed",
    ["[rejected]"] = "rejected",
    ["[aborted]"] = "aborted",
}

--- Strip a recognized status prefix from text.
---@param text string?
---@return string?
local function strip_status_prefix(text)
    if not text then
        return nil
    end
    for prefix, _ in pairs(STATUS_PREFIXES) do
        if text:sub(1, #prefix) == prefix then
            local rest = vim.trim(text:sub(#prefix + 1))
            return rest ~= "" and rest or nil
        end
    end
    return text
end

--- Extract display-ready text from a tool result (status prefix stripped).
---@param result? table
---@return string?
local function extract_result_text(result)
    return strip_status_prefix(extract_result_text_raw(result))
end

--- Resolve display status from a tool result.
--- Extensions can embed [accepted] or [rejected] prefixes in blocked-tool
--- reason text to communicate richer status than the binary isError flag.
---@param result? table
---@param is_error? boolean
---@return "completed"|"error"|"rejected"|"aborted"
function M.resolve_status(result, is_error)
    if not is_error then
        return "completed"
    end
    local text = extract_result_text_raw(result)
    if text then
        for prefix, status in pairs(STATUS_PREFIXES) do
            if text:sub(1, #prefix) == prefix then
                return status
            end
        end
    end
    return "error"
end

---@param history pi.ChatHistory
---@param row integer 0-indexed
---@param glyph string indent prefix ("  ")
function M.set_border(history, row, glyph)
    vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), row, 0, {
        virt_text = { { glyph } },
        virt_text_pos = "inline",
        hl_mode = "combine",
        line_hl_group = "PiToolBody",
    })
end

--- Paint a line with the tool-container background (no indent glyph).
---
--- Body lines get their background from set_border(); the header and footer
--- lines carry no indent glyph but must share the same background so a block
--- reads as one continuous container from header top to footer bottom.
---@param history pi.ChatHistory
---@param row integer 0-indexed
function M.set_line_bg(history, row)
    vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), row, 0, {
        line_hl_group = "PiToolBody",
    })
end

---@param history pi.ChatHistory
---@param text string
---@param hl_group? string
---@param insert_at? integer  when set, insert at this row instead of appending
---@return integer? next_insert_at  advanced insertion cursor (nil when appending)
local function render_body_line(history, text, hl_group, insert_at)
    text = M.sanitize_text(text)
    local start
    if insert_at then
        start, insert_at = history:_insert_lines(insert_at, { text })
    else
        start = history:_append_lines({ text })
    end
    M.set_border(history, start, M.GLYPHS.INDENT)
    if #text > 0 then
        vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), start, 0, {
            end_col = #text,
            hl_group = hl_group or "PiToolCall",
        })
    end
    return insert_at
end

--- Render input lines, wrapping in a fenced code block when render-markdown
--- is active so that shell comments (#) and other markdown-significant syntax
--- in tool input are not misparsed as headings, lists, etc.
---@param history pi.ChatHistory
---@param lines string[]  raw input lines (already split)
---@param lang? string  language hint for the code fence (e.g. "bash")
---@param insert_at? integer  when set, insert at this row instead of appending
---@return integer? next_insert_at  advanced insertion cursor (nil when appending)
local function render_input(history, lines, lang, insert_at)
    local fenced = lines
    if Render.engine() == "render-markdown" then
        local max_run = 0
        for _, line in ipairs(lines) do
            local run = line:match("^(`+)")
            if run and #run > max_run then
                max_run = #run
            end
        end
        local fence = string.rep("`", math.max(max_run + 1, 3))
        fenced = { fence .. (lang or "") }
        vim.list_extend(fenced, lines)
        fenced[#fenced + 1] = fence
    end

    local start
    if insert_at then
        start, insert_at = history:_insert_lines(insert_at, fenced)
    else
        start = history:_append_lines(fenced)
    end
    for i = 0, #fenced - 1 do
        M.set_border(history, start + i, M.GLYPHS.INDENT)
        local line = fenced[i + 1] or ""
        if #line > 0 then
            vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), start + i, 0, {
                end_col = #line,
                hl_group = "PiToolCall",
            })
        end
    end
    return insert_at
end

---@param history pi.ChatHistory
---@param text string
---@param insert_at? integer  when set, insert at this row instead of appending
---@param lang? string  language hint for the code fence (e.g. "bash")
---@return integer? next_insert_at  advanced insertion cursor (nil when appending)
local function render_output(history, text, insert_at, lang)
    text = M.sanitize_text(text)
    local sep_row
    if insert_at then
        sep_row, insert_at = history:_insert_lines(insert_at, { "" })
    else
        sep_row = history:_append_lines({ "" })
    end
    M.set_border(history, sep_row, M.GLYPHS.INDENT)
    local output_lines = vim.split(text, "\n", { plain = true })

    local auto_closed = false

    if Render.engine() == "render-markdown" then
        -- Wrap output in a fenced code block so render-markdown.nvim treats
        -- it as literal code (prevents "# comment" → heading, etc.).
        -- Fence nesting: pick a fence one backtick longer than the longest
        -- backtick run at the start of any output line (minimum 3).
        local max_run = 0
        for _, line in ipairs(output_lines) do
            local run = line:match("^(`+)")
            if run and #run > max_run then
                max_run = #run
            end
        end
        local fence = string.rep("`", math.max(max_run + 1, 3))
        table.insert(output_lines, 1, fence .. (lang or ""))
        output_lines[#output_lines + 1] = fence
    else
        -- Builtin engine: treesitter PARSES ``` as fence delimiters regardless
        -- of conceallevel.  To prevent an unclosed fence from leaking
        -- code-block styling into the content below, count fence lines and
        -- auto-close if odd — same approach used for user messages in
        -- history.lua.
        local fences = 0
        for _, line in ipairs(output_lines) do
            if line:match("^```") then
                fences = fences + 1
            end
        end
        if fences % 2 == 1 then
            output_lines[#output_lines + 1] = "```"
            auto_closed = true
        end
    end
    local start
    if insert_at then
        start, insert_at = history:_insert_lines(insert_at, output_lines)
    else
        start = history:_append_lines(output_lines)
    end
    for i = 0, #output_lines - 1 do
        M.set_border(history, start + i, M.GLYPHS.INDENT)
        local line = output_lines[i + 1] or ""
        if #line > 0 then
            vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), start + i, 0, {
                end_col = #line,
                hl_group = "PiToolOutput",
                priority = 200,
            })
        end
    end
    if auto_closed then
        local close_row = start + #output_lines - 1
        vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), close_row, 3, {
            virt_text = { { " ← auto-closed", "PiWarning" } },
            virt_text_pos = "inline",
        })
    end
    return insert_at
end

--- Parse treesitter highlights for a source string.
---@param text string  source code
---@param lang string  treesitter language
---@return table<integer, {sc: integer, ec: integer, hl: string}[]>  0-based line → highlights
local function ts_highlights(text, lang)
    local result = {}
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not ok or not parser then
        return result
    end
    local trees = parser:parse()
    if not trees or #trees == 0 then
        return result
    end
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
        return result
    end
    for id, node in query:iter_captures(trees[1]:root(), text) do
        local hl = "@" .. query.captures[id] .. "." .. lang
        local sr, sc, er, ec = node:range()
        for row = sr, er do
            result[row] = result[row] or {}
            local s = (row == sr) and sc or 0
            local e = (row == er) and ec or nil
            result[row][#result[row] + 1] = { sc = s, ec = e, hl = hl }
        end
    end
    return result
end

--- Apply treesitter syntax highlights to rendered diff lines.
---@param buf integer
---@param ns integer
---@param rendered table[]
---@param start_row integer  0-indexed row of first code fence
---@param old_hl table  highlights from ts_highlights(old_text)
---@param new_hl table  highlights from ts_highlights(new_text)
local function apply_diff_syntax(buf, ns, rendered, start_row, old_hl, new_hl)
    for i, r in ipairs(rendered) do
        local src_hl = r.src_kind == "new" and new_hl or old_hl
        local line_hls = src_hl[r.src_line] or {}
        local row = start_row + i - 1
        for _, h in ipairs(line_hls) do
            local sc = r.prefix_len + h.sc
            local ec = h.ec and (r.prefix_len + h.ec) or nil
            vim.api.nvim_buf_set_extmark(buf, ns, row, sc, {
                end_col = ec,
                hl_group = h.hl,
                priority = 300, -- above diff background
            })
        end
    end
end

---@param history pi.ChatHistory
---@param old_text string
---@param new_text string
---@param line_offset? integer  added to line numbers (0-based file offset)
---@param path? string  file path for syntax highlighting
---@param insert_at? integer  when set, insert at this row instead of appending
---@return integer? next_insert_at  advanced insertion cursor (nil when appending)
local function render_diff(history, old_text, new_text, line_offset, path, insert_at)
    old_text = M.sanitize_text(old_text)
    new_text = M.sanitize_text(new_text)
    line_offset = line_offset or 0
    -- Ensure trailing newlines for vim.diff
    if not old_text:find("\n$") then
        old_text = old_text .. "\n"
    end
    if not new_text:find("\n$") then
        new_text = new_text .. "\n"
    end
    local diff_text = vim.diff(old_text, new_text)
    if not diff_text or diff_text == "" then
        return insert_at
    end

    -- Parse unified diff: collect content lines with line numbers, highlight type, and source mapping
    ---@type { text: string, hl: string?, sign: ("+"|"-")?, src_kind: "old"|"new", src_line: integer, prefix_len: integer }[]
    local rendered = {}
    local old_ln, new_ln
    local old_idx, new_idx -- 0-based indices into old_text/new_text
    for line in diff_text:gmatch("[^\n]*") do
        local c = line:sub(1, 1)
        if line:match("^@@") then
            local os, ns = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
            old_idx = tonumber(os) - 1
            new_idx = tonumber(ns) - 1
            old_ln = tonumber(os) + line_offset
            new_ln = tonumber(ns) + line_offset
        elseif c == "-" and old_ln then
            local prefix = string.format("%4d - ", old_ln)
            rendered[#rendered + 1] = {
                text = prefix .. line:sub(2),
                hl = "PiDiffDelete",
                sign = "-",
                src_kind = "old",
                src_line = old_idx,
                prefix_len = #prefix,
            }
            old_ln = old_ln + 1
            old_idx = old_idx + 1
        elseif c == "+" and new_ln then
            local prefix = string.format("%4d + ", new_ln)
            rendered[#rendered + 1] = {
                text = prefix .. line:sub(2),
                hl = "PiDiffAdd",
                sign = "+",
                src_kind = "new",
                src_line = new_idx,
                prefix_len = #prefix,
            }
            new_ln = new_ln + 1
            new_idx = new_idx + 1
        elseif c == " " and old_ln then
            local prefix = string.format("%4d   ", old_ln)
            rendered[#rendered + 1] = {
                text = prefix .. line:sub(2),
                src_kind = "old",
                src_line = old_idx,
                prefix_len = #prefix,
            }
            old_ln = old_ln + 1
            new_ln = (new_ln or 0) + 1
            old_idx = (old_idx or 0) + 1
            new_idx = (new_idx or 0) + 1
        end
    end
    if #rendered == 0 then
        return insert_at
    end

    local sep_row
    if insert_at then
        sep_row, insert_at = history:_insert_lines(insert_at, { "" })
    else
        sep_row = history:_append_lines({ "" })
    end
    M.set_border(history, sep_row, M.GLYPHS.INDENT)
    local lines = {}
    for _, r in ipairs(rendered) do
        lines[#lines + 1] = r.text
    end

    local start
    if insert_at then
        start, insert_at = history:_insert_lines(insert_at, lines)
    else
        start = history:_append_lines(lines)
    end
    for i = 0, #lines - 1 do
        M.set_border(history, start + i, M.GLYPHS.INDENT)
    end

    -- Apply full-line background highlights and line number styling
    -- hl_group + hl_eol extends to window edge; end_row = row+1 makes it "multiline" (required for hl_eol)
    -- Border virt_text uses hl_mode="replace" so it ignores the hl_group background
    for i, r in ipairs(rendered) do
        local row = start + i - 1
        -- Diff background
        if r.hl then
            vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), row, 0, {
                end_row = row + 1,
                hl_group = r.hl,
                hl_eol = true,
            })
        end
        -- Line number + sign prefix in comment color
        vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), row, 0, {
            end_col = r.prefix_len,
            hl_group = "PiDiffLineNr",
            priority = 300,
        })
        -- The +/- sign itself carries the diff semantic color so additions and
        -- deletions can be located by hue at a glance. The sign is always the
        -- char two before the prefix end (format "%4d X "), independent of the
        -- line-number width.
        if r.sign then
            local sign_col = r.prefix_len - 2
            vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), row, sign_col, {
                end_col = sign_col + 1,
                hl_group = r.sign == "+" and "PiDiffAddSign" or "PiDiffDeleteSign",
                priority = 310,
            })
        end
    end

    -- Apply treesitter syntax highlights
    if path then
        local ft = vim.filetype.match({ filename = path })
        if ft then
            local lang = vim.treesitter.language.get_lang(ft) or ft
            local lok = pcall(vim.treesitter.language.inspect, lang)
            if lok then
                local old_hl = ts_highlights(old_text, lang)
                local new_hl = ts_highlights(new_text, lang)
                apply_diff_syntax(history:buf(), history:ns(), rendered, start, old_hl, new_hl)
            end
        end
    end
    return insert_at
end

--- Truncate a line to max_width, appending "…" if truncated.
---@param line string
---@param max_width integer
---@return string
local function truncate_line(line, max_width)
    line = M.sanitize_text(line)
    if max_width <= 0 or vim.fn.strdisplaywidth(line) <= max_width then
        return line
    end
    -- Binary-ish search for the cut point in bytes
    local cut = max_width - 1 -- leave room for …
    while cut > 0 and vim.fn.strdisplaywidth(line:sub(1, cut)) > cut do
        cut = cut - 1
    end
    return line:sub(1, cut) .. "…"
end

--- Build a structured collapsed view for a tool block.
--- Input: ≤ input_visible as-is, otherwise first input_visible line(s) + "+N lines".
--- Separator + output hidden entirely when output_visible = 0.
--- Output: ≤ output_visible as-is, otherwise "…N lines" + last output_visible line(s).
--- Lines longer than max_width are truncated with "…".
---@param input_lines string[]
---@param output_lines string[] actual output (no separator/code fences)
---@param has_output boolean
---@param input_visible integer
---@param output_visible integer
---@param max_width? integer  truncate lines wider than this (0 = no limit)
---@return string[] lines
---@return string[] specs  parallel array: "input"|"summary"|"separator"|"output"
function M.build_collapsed_view(input_lines, output_lines, has_output, input_visible, output_visible, max_width)
    local lines, specs = {}, {}
    max_width = max_width or 0

    local function add(line, spec)
        line = M.sanitize_text(line)
        lines[#lines + 1] = max_width > 0 and truncate_line(line, max_width) or line
        specs[#specs + 1] = spec
    end

    -- Input
    local visible_input = {}
    if #input_lines <= input_visible then
        for _, l in ipairs(input_lines) do
            visible_input[#visible_input + 1] = l
        end
    else
        for i = 1, input_visible do
            visible_input[#visible_input + 1] = input_lines[i]
        end
        lines[#lines + 1] = " +" .. (#input_lines - input_visible) .. " lines"
        specs[#specs + 1] = "summary"
    end

    -- When render-markdown is active, wrap visible input in a code fence
    -- to prevent markdown parsing (e.g. shell comments → headings).
    if Render.engine() == "render-markdown" and #visible_input > 0 then
        local max_run = 0
        for _, line in ipairs(visible_input) do
            local run = line:match("^(`+)")
            if run and #run > max_run then
                max_run = #run
            end
        end
        local fence = string.rep("`", math.max(max_run + 1, 3))
        add(fence, "input")
        for _, l in ipairs(visible_input) do
            add(l, "input")
        end
        add(fence, "input")
    else
        for _, l in ipairs(visible_input) do
            add(l, "input")
        end
    end

    -- Separator + Output (hidden entirely when output_visible = 0)
    if has_output and output_visible > 0 then
        lines[#lines + 1] = ""
        specs[#specs + 1] = "separator"

        -- Collect visible output lines
        local visible_output = {}
        if #output_lines <= output_visible then
            for _, l in ipairs(output_lines) do
                visible_output[#visible_output + 1] = l
            end
        elseif #output_lines > 0 then
            lines[#lines + 1] = "…" .. (#output_lines - output_visible) .. " lines"
            specs[#specs + 1] = "summary"
            for i = #output_lines - output_visible + 1, #output_lines do
                visible_output[#visible_output + 1] = output_lines[i]
            end
        end

        -- When render-markdown is active, wrap visible output in a code fence
        -- to prevent markdown parsing (e.g. setext headings from === lines).
        if Render.engine() == "render-markdown" and #visible_output > 0 then
            local max_run = 0
            for _, line in ipairs(visible_output) do
                local run = line:match("^(`+)")
                if run and #run > max_run then
                    max_run = #run
                end
            end
            local fence = string.rep("`", math.max(max_run + 1, 3))
            add(fence, "output")
            for _, l in ipairs(visible_output) do
                add(l, "output")
            end
            add(fence, "output")
        else
            for _, l in ipairs(visible_output) do
                add(l, "output")
            end
        end
    end

    return lines, specs
end

--- Apply border and highlight extmarks to collapsed lines.
---@param history pi.ChatHistory
---@param base_row integer 0-indexed first row
---@param specs string[] parallel array of line types
---@param lines string[]
function M.apply_collapsed_extmarks(history, base_row, specs, lines)
    local hl_map = { input = "PiToolCall", summary = "PiToolCollapsed", output = "PiToolOutput" }
    for i, spec in ipairs(specs) do
        local row = base_row + i - 1
        M.set_border(history, row, M.GLYPHS.INDENT)
        local hl = hl_map[spec]
        if hl and #lines[i] > 0 then
            vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), row, 0, {
                end_col = #lines[i],
                hl_group = hl,
            })
        end
    end
end

--- Extract input lines and actual output lines from a tool block's inner range.
---@param history pi.ChatHistory
---@param block pi.ToolBlock
---@return string[] input_lines
---@return string[] output_lines  (actual content, no separator/code fences)
---@return boolean has_output
function M.extract_tool_sections(history, block)
    local buf = history:buf()
    local ns_id = history:ns()
    local header_row = vim.api.nvim_buf_get_extmark_by_id(buf, ns_id, block.icon_extmark, {})[1]
    local footer_row = vim.api.nvim_buf_get_extmark_by_id(buf, ns_id, block.end_extmark, {})[1]
    local has_output = block.output_extmark ~= nil

    local input_end = footer_row
    if has_output then
        input_end = vim.api.nvim_buf_get_extmark_by_id(buf, ns_id, block.output_extmark, {})[1]
    end
    local input_lines = vim.api.nvim_buf_get_lines(buf, header_row + 1, input_end, false)

    -- When the render-markdown engine is active, render_input() wraps tool
    -- input in a fenced code block (```lang / ```).  Strip these display-only
    -- fence artifacts so the collapsed view sees the raw input lines.
    if Render.engine() == "render-markdown" and #input_lines >= 2 then
        local first = input_lines[1]
        local last = input_lines[#input_lines]
        if first:match("^`%`%`") and last:match("^`%`%`+$") and not last:match("[^`]") then
            table.remove(input_lines, 1)
            table.remove(input_lines)
        end
    end

    local output_lines = {}
    if has_output then
        local output_row = vim.api.nvim_buf_get_extmark_by_id(buf, ns_id, block.output_extmark, {})[1]
        -- Output section: separator, actual lines...
        local content_start = output_row + 1 -- skip separator
        if content_start < footer_row then
            output_lines = vim.api.nvim_buf_get_lines(buf, content_start, footer_row, false)
        end
    end

    -- When the render-markdown engine is active, render_output() wraps tool
    -- output in a fenced code block (```lang / ```).  These fence lines are
    -- display-only artifacts — they must not be counted as real output when
    -- building the collapsed view, otherwise the closing fence leaks into the
    -- collapsed summary as an orphan ``` that render-markdown misparses as a
    -- new code-block start, bleeding its background colour into surrounding
    -- lines (inline tools, headers, etc.).
    if Render.engine() == "render-markdown" and #output_lines >= 2 then
        local first = output_lines[1]
        local last = output_lines[#output_lines]
        if first:match("^`%`%`") and last:match("^`%`%`+$") and not last:match("[^`]") then
            -- Strip opening fence (```lang) and closing fence (```)
            table.remove(output_lines, 1) -- opening fence
            table.remove(output_lines) -- closing fence (last element)
        end
    end

    return input_lines, output_lines, has_output
end

--- Check whether a tool block should be collapsed based on renderer thresholds
--- or line width exceeding max_width.
---@param input_lines string[]
---@param output_lines string[]
---@param input_visible integer
---@param output_visible integer
---@param max_width? integer
---@return boolean
function M.should_collapse(input_lines, output_lines, input_visible, output_visible, max_width)
    if #input_lines > input_visible or #output_lines > output_visible then
        return true
    end
    if max_width and max_width > 0 then
        for _, line in ipairs(input_lines) do
            if vim.fn.strdisplaywidth(M.sanitize_text(line)) > max_width then
                return true
            end
        end
        for _, line in ipairs(output_lines) do
            if vim.fn.strdisplaywidth(M.sanitize_text(line)) > max_width then
                return true
            end
        end
    end
    return false
end

--- Renderers ---

---@class pi.ToolRenderer
---@field on_start? fun(history: pi.ChatHistory, args: table?)
---@field on_end? fun(history: pi.ChatHistory, args: table?, result: table?, is_error: boolean?, insert_at: integer?): integer?
---@field input_visible? integer  lines to show when collapsed (default: show all)
---@field output_visible? integer lines to show when collapsed (default: show all)
---@field inline? boolean  render as a single line (no header/footer)
---@field inline_text? fun(args: table?): string?  text to show after tool name
---@field inline_status? fun(result: table?, is_error: boolean?): string?  extra text next to status icon

---@type table<string, pi.ToolRenderer>
local renderers = {
    bash = {
        input_visible = 1,
        output_visible = 1,
        on_start = function(history, args)
            if args and (args.command or args.cmd) then
                local cmd = args.command or args.cmd
                local lines = vim.split(cmd, "\n", { plain = true })
                render_input(history, lines, "bash")
            end
        end,
        on_end = function(history, _, result, _, insert_at)
            local text = extract_result_text(result)
            if text and text ~= "" then
                insert_at = render_output(history, text, insert_at)
            end
            return insert_at
        end,
    },
    read = {
        inline = true,
        inline_text = function(args)
            return args and (args.path or args.file_path) or nil
        end,
        inline_status = function(result)
            local text = extract_result_text(result)
            if text then
                local n = select(2, text:gsub("\n", "\n")) + 1
                return "(" .. n .. " lines)"
            end
        end,
    },
    edit = {
        output_visible = 0,
        on_start = function(history, args)
            if args and (args.path or args.file_path) then
                render_body_line(history, args.path or args.file_path)
            end
        end,
        on_end = function(history, args, _, _, insert_at)
            if not args then
                return insert_at
            end

            -- NOTE: This renders the *proposed* diff (oldText→newText). When a
            -- permission extension lets the user accept-with-modifications, the
            -- actual applied content may differ. We can't distinguish accept from
            -- accept-with-modifications here — both arrive as [accepted] with
            -- isError flipped to false, and the modified content lives only in
            -- the extension's free-form reason text. Fixing this would require
            -- structured result metadata (e.g. a details field), not available today.

            local path = args.path or args.file_path
            local edits = args.edits
            if type(edits) ~= "table" or #edits == 0 then
                return insert_at
            end

            local content = nil
            if path then
                local abs = vim.fn.fnamemodify(path, ":p")
                for _, b in ipairs(vim.api.nvim_list_bufs()) do
                    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs then
                        content = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
                        break
                    end
                end
                if not content then
                    local f = io.open(abs, "r")
                    if f then
                        content = f:read("*a")
                        f:close()
                    end
                end
            end

            local replacements = {}
            if content then
                for _, edit in ipairs(edits) do
                    local old_text = edit.oldText
                    if type(old_text) == "string" and old_text ~= "" then
                        local search_from = 1
                        while true do
                            local s, e = content:find(old_text, search_from, true)
                            if not s then
                                break
                            end

                            local overlaps = false
                            for _, existing in ipairs(replacements) do
                                if not (e < existing.start_pos or s > existing.end_pos) then
                                    overlaps = true
                                    break
                                end
                            end

                            if not overlaps then
                                replacements[#replacements + 1] = {
                                    start_pos = s,
                                    end_pos = e,
                                    old_text = old_text,
                                    new_text = edit.newText or "",
                                }
                                break
                            end

                            search_from = s + 1
                        end
                    end
                end

                table.sort(replacements, function(a, b)
                    return a.start_pos < b.start_pos
                end)
            end

            if #replacements > 0 then
                for _, replacement in ipairs(replacements) do
                    local _, count = content:sub(1, replacement.start_pos - 1):gsub("\n", "\n")
                    insert_at = render_diff(history, replacement.old_text, replacement.new_text, count, path, insert_at)
                end
                return insert_at
            end

            for _, edit in ipairs(edits) do
                local old_text = type(edit.oldText) == "string" and edit.oldText or ""
                local new_text = type(edit.newText) == "string" and edit.newText or ""
                insert_at = render_diff(history, old_text, new_text, 0, path, insert_at)
            end

            return insert_at
        end,
    },
    write = {
        output_visible = 0,
        on_start = function(history, args)
            if not args then
                return
            end
            local path = args.path or args.file_path
            if path then
                render_body_line(history, path)
                -- Snapshot original content before the tool writes the file.
                -- Stash on args so on_end can diff against it.
                -- Skip during replay — file state no longer matches the original session.
                if history._replaying then
                    return
                end
                local abs_path = vim.fn.fnamemodify(path, ":p")
                local original
                for _, b in ipairs(vim.api.nvim_list_bufs()) do
                    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs_path then
                        original = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
                        break
                    end
                end
                if not original then
                    local f = io.open(abs_path, "r")
                    if f then
                        original = f:read("*a")
                        f:close()
                    end
                end
                args._original_content = original or ""
            end
        end,
        on_end = function(history, args, _, _, insert_at)
            if not args or not args.content then
                return insert_at
            end
            local original = args._original_content
            if not original then
                return insert_at
            end
            local path = args.path or args.file_path
            return render_diff(history, original, args.content, 0, path, insert_at)
        end,
    },
}

---@type pi.ToolRenderer
local default_renderer = {
    input_visible = 1,
    output_visible = 1,
    on_start = function(history, args)
        if not args then
            return
        end
        -- Show the first short string value as a summary line
        for _, key in ipairs({ "url", "path", "file_path", "query", "command", "cmd" }) do
            local val = args[key]
            if type(val) == "string" and val ~= "" then
                render_body_line(history, val)
                return
            end
        end
        -- Fallback: first string arg that fits on one line
        for _, val in pairs(args) do
            if type(val) == "string" and val ~= "" and not val:find("\n") and #val <= 200 then
                render_body_line(history, val)
                return
            end
        end
    end,
    on_end = function(history, _, result, _, insert_at)
        local text = extract_result_text(result)
        if text and text ~= "" then
            insert_at = render_output(history, text, insert_at)
        end
        return insert_at
    end,
}

---@param tool_name string
---@return pi.ToolRenderer
function M.get_renderer(tool_name)
    return renderers[tool_name] or default_renderer
end

return M
