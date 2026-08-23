--- Compile one isolated Markdown document into buffer-local decorations.

local M = {}

local scratch_buf ---@type integer?
local SCRATCH_FILETYPE = "agent-workbench-markdown-scratch"

---@class agent_workbench.MarkdownRevealRange
---@field key string
---@field row integer
---@field col integer
---@field end_row integer
---@field end_col integer

---@class agent_workbench.MarkdownDecoration
---@field row integer
---@field col integer
---@field end_row? integer
---@field end_col? integer
---@field hl_group? string
---@field hl_mode? "replace"|"combine"|"blend"
---@field conceal? string
---@field virt_text? table
---@field virt_text_pos? string
---@field virt_lines? table
---@field virt_lines_above? boolean
---@field line_hl_group? string
---@field priority? integer
---@field reveal? agent_workbench.MarkdownRevealRange Semantic source range that owns this decoration
---@field hide_when_revealed? boolean Hide this conceal/replacement while its owner is under the cursor

---@class agent_workbench.MarkdownPlan
---@field decorations agent_workbench.MarkdownDecoration[]
---@field width_dependent boolean

---@param value any
---@param fallback integer
---@return integer
local function number_or(value, fallback)
    local number = tonumber(value)
    return number and math.floor(number) or fallback
end

---@return integer
local function ensure_scratch()
    if scratch_buf and vim.api.nvim_buf_is_valid(scratch_buf) then
        return scratch_buf
    end
    pcall(vim.treesitter.language.register, "markdown", SCRATCH_FILETYPE)
    scratch_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch_buf].buftype = "nofile"
    vim.bo[scratch_buf].bufhidden = "hide"
    vim.bo[scratch_buf].swapfile = false
    vim.bo[scratch_buf].filetype = SCRATCH_FILETYPE
    return scratch_buf
end

---@param decorations agent_workbench.MarkdownDecoration[]
---@param decoration agent_workbench.MarkdownDecoration
local function add(decorations, decoration)
    decorations[#decorations + 1] = decoration
end

local reveal_owner_types = {
    atx_heading = true,
    setext_heading = true,
    strong_emphasis = true,
    emphasis = true,
    strikethrough = true,
    inline_link = true,
    full_reference_link = true,
    collapsed_reference_link = true,
    shortcut_link = true,
    autolink = true,
    image = true,
    code_span = true,
    list_item = true,
    block_quote = true,
    fenced_code_block = true,
    thematic_break = true,
    pipe_table = true,
}

---@param row integer
---@param col integer
---@param end_row integer
---@param end_col integer
---@return agent_workbench.MarkdownRevealRange
local function reveal_range(row, col, end_row, end_col)
    return {
        key = table.concat({ row, col, end_row, end_col }, ":"),
        row = row,
        col = col,
        end_row = end_row,
        end_col = end_col,
    }
end

---@param range table
---@return agent_workbench.MarkdownRevealRange?
local function semantic_reveal_range(range)
    local row = tonumber(range.row_start)
    local col = tonumber(range.col_start)
    local end_row = tonumber(range.row_end)
    local end_col = tonumber(range.col_end)
    if not row or not col or not end_row or not end_col then
        return nil
    end
    return reveal_range(row, col, end_row, end_col)
end

---@param node any
---@return agent_workbench.MarkdownRevealRange?
local function node_reveal_range(node)
    local current = node
    while current do
        if reveal_owner_types[current:type()] then
            local row, col, end_row, end_col = current:range()
            return reveal_range(row, col, end_row, end_col)
        end
        current = current:parent()
    end
    return nil
end

---@param decoration agent_workbench.MarkdownDecoration
---@param reveal agent_workbench.MarkdownRevealRange?
local function make_cursor_revealable(decoration, reveal)
    if not reveal then
        return
    end
    decoration.reveal = reveal
    decoration.hide_when_revealed = true
end

---@param capture string
---@param node any
---@param features table
---@return boolean
local function capture_enabled(capture, node, features)
    local ancestor = node
    while ancestor do
        if ancestor:type() == "fenced_code_block" then
            return features.code_blocks ~= false
        end
        ancestor = ancestor:parent()
    end
    if capture:match("^markup%.heading") then
        return features.headings ~= false
    elseif capture == "markup.strong" then
        return features.emphasis ~= false
    elseif capture == "markup.italic" then
        return features.emphasis ~= false
    elseif capture == "markup.strikethrough" then
        return features.strikethrough ~= false
    elseif capture:match("^markup%.link") or node:type():match("^link_") then
        return features.links ~= false
    elseif capture == "markup.raw" or node:type():match("code_span") then
        return features.inline_code ~= false
    elseif capture == "markup.raw.block" or node:type():match("fenced_code_block") then
        return features.code_blocks ~= false
    elseif capture == "markup.list" then
        return features.lists ~= false
    elseif capture:match("^markup%.list%.") then
        return features.checkboxes ~= false
    elseif capture == "conceal" then
        local parent = node:parent()
        local parent_type = parent and parent:type() or ""
        if parent_type == "strong_emphasis" or parent_type == "emphasis" then
            return features.emphasis ~= false
        elseif parent_type == "strikethrough" then
            return features.strikethrough ~= false
        elseif parent_type:match("link") then
            return features.links ~= false
        elseif node:type():match("code_span") then
            return features.inline_code ~= false
        end
    end
    return true
end

---@param capture string
---@param language string
---@param node_type string
---@return string?
local function capture_highlight(capture, language, node_type)
    if capture == "spell" or capture == "nospell" or capture:sub(1, 1) == "_" or capture == "conceal" then
        return nil
    end
    local heading_level = capture:match("^markup%.heading%.([1-6])$")
    if heading_level then
        return "AgentWorkbenchMarkdownHeading" .. heading_level
    elseif capture == "markup.strong" then
        return "AgentWorkbenchMarkdownStrong"
    elseif capture == "markup.italic" then
        return "AgentWorkbenchMarkdownEmphasis"
    elseif capture == "markup.strikethrough" then
        return "AgentWorkbenchMarkdownStrikethrough"
    elseif capture:match("^markup%.link") then
        return "AgentWorkbenchMarkdownLink"
    elseif capture == "markup.raw" and node_type == "code_span" then
        return "AgentWorkbenchMarkdownInlineCode"
    elseif capture == "markup.list" then
        return "AgentWorkbenchMarkdownListMarker"
    elseif capture == "markup.quote" then
        return "AgentWorkbenchMarkdownBlockQuote"
    elseif capture == "markup.list.checked" then
        return "AgentWorkbenchMarkdownCheckboxChecked"
    elseif capture == "markup.list.unchecked" then
        return "AgentWorkbenchMarkdownCheckboxUnchecked"
    elseif capture == "markup.raw.block" then
        return nil
    end
    local scoped = "@" .. capture .. "." .. language
    if vim.fn.hlexists(scoped) == 1 then
        return scoped
    end
    local generic = "@" .. capture
    return vim.fn.hlexists(generic) == 1 and generic or nil
end

---@param metadata table?
---@param capture_id integer
---@return table
local function capture_metadata(metadata, capture_id)
    if type(metadata) ~= "table" then
        return {}
    end
    if type(metadata[capture_id]) == "table" then
        return vim.tbl_extend("force", metadata, metadata[capture_id])
    end
    return metadata
end

---@param source string
---@return { start_row: integer, end_row: integer }[]
local function fenced_code_ranges(source)
    local lines = vim.split(source, "\n", { plain = true })
    local ranges = {}
    local active ---@type { character: string, length: integer, start_row: integer }?
    for index, line in ipairs(lines) do
        local indent, fence, suffix = line:match("^( *)([`~]+)(.*)$")
        local valid_fence = indent and #indent <= 3 and #fence >= 3
        if valid_fence then
            local character = fence:sub(1, 1)
            valid_fence = fence == string.rep(character, #fence)
            if active then
                if
                    valid_fence
                    and character == active.character
                    and #fence >= active.length
                    and suffix:match("^%s*$")
                then
                    ranges[#ranges + 1] = { start_row = active.start_row, end_row = index - 1 }
                    active = nil
                end
            elseif valid_fence and (character ~= "`" or not suffix:find("`", 1, true)) then
                active = { character = character, length = #fence, start_row = index }
            end
        end
    end
    if active then
        ranges[#ranges + 1] = { start_row = active.start_row, end_row = #lines }
    end
    return ranges
end

---@param row integer
---@param end_row integer
---@param ranges { start_row: integer, end_row: integer }[]
---@return boolean
local function inside_code_block(row, end_row, ranges)
    for _, range in ipairs(ranges) do
        if row >= range.start_row and end_row <= range.end_row then
            return true
        end
    end
    return false
end

---@param parser vim.treesitter.LanguageTree
---@param buffer integer
---@param decorations agent_workbench.MarkdownDecoration[]
---@param features table
---@param code_ranges { start_row: integer, end_row: integer }[]
local function add_tree_sitter_decorations(parser, buffer, decorations, features, code_ranges)
    ---@diagnostic disable-next-line: undefined-field
    parser:for_each_tree(function(tree, language_tree)
        local language = language_tree:lang()
        local ok, query = pcall(vim.treesitter.query.get, language, "highlights")
        if not ok or not query then
            return
        end
        for capture_id, node, metadata in query:iter_captures(tree:root(), buffer, 0, -1) do
            local capture = query.captures[capture_id]
            local row, col, end_row, end_col = node:range()
            if
                not capture_enabled(capture, node, features)
                or (
                    language ~= "markdown"
                    and language ~= "markdown_inline"
                    and (features.code_blocks == false or not inside_code_block(row, end_row, code_ranges))
                )
            then
                goto continue
            end
            local capture_meta = capture_metadata(metadata, capture_id)
            local decoration = {
                row = row,
                col = col,
                end_row = end_row,
                end_col = end_col,
                priority = number_or(capture_meta.priority, 90),
            }
            local hl_group = capture_highlight(capture, language, node:type())
            if hl_group then
                decoration.hl_group = hl_group
            end
            if type(capture_meta.conceal) == "string" then
                decoration.conceal = capture_meta.conceal
            elseif capture_meta.conceal == true then
                decoration.conceal = ""
            elseif type(capture_meta.conceal) == "number" then
                decoration.conceal = vim.fn.nr2char(capture_meta.conceal)
            end
            if decoration.conceal ~= nil then
                make_cursor_revealable(decoration, node_reveal_range(node))
            end
            if decoration.hl_group or decoration.conceal ~= nil then
                add(decorations, decoration)
            end
            ::continue::
        end
    end)
end

---@param line string
---@return string[]
local function table_cells(line)
    line = vim.trim(line)
    line = line:gsub("^|", ""):gsub("|$", "")
    local cells = {}
    for cell in (line .. "|"):gmatch("(.-)|") do
        cells[#cells + 1] = vim.trim(cell)
    end
    return cells
end

---@param text string
---@param width integer
---@param align string?
---@return string
local function align_cell(text, width, align)
    local padding = math.max(0, width - vim.fn.strdisplaywidth(text))
    if align == "right" then
        return string.rep(" ", padding) .. text
    elseif align == "center" then
        local left = math.floor(padding / 2)
        return string.rep(" ", left) .. text .. string.rep(" ", padding - left)
    end
    return text .. string.rep(" ", padding)
end

---@param cells string[]
---@param widths integer[]
---@param aligns string[]
---@return string
local function table_row(cells, widths, aligns)
    local parts = { "│" }
    for index, width in ipairs(widths) do
        parts[#parts + 1] = " " .. align_cell(cells[index] or "", width, aligns[index]) .. " │"
    end
    return table.concat(parts)
end

---@param widths integer[]
---@param left string
---@param middle string
---@param right string
---@return string
local function table_border(widths, left, middle, right)
    local parts = { left }
    for index, width in ipairs(widths) do
        parts[#parts + 1] = string.rep("─", width + 2)
        parts[#parts + 1] = index == #widths and right or middle
    end
    return table.concat(parts)
end

---@param parts table[]?
---@return string[]
local function semantic_table_cells(parts)
    local cells = {}
    for _, part in ipairs(parts or {}) do
        if part.class == "column" then
            cells[#cells + 1] = vim.trim(part.text or "")
        end
    end
    return cells
end

---@param lines string[]
---@param item table
---@param decorations agent_workbench.MarkdownDecoration[]
local function render_table(lines, item, decorations)
    local start_row = item.range.row_start
    local end_row = item.range.row_end - 1
    if end_row - start_row < 2 then
        return
    end
    local header = semantic_table_cells(item.header)
    if #header == 0 then
        header = table_cells(lines[start_row + 1] or "")
    end
    local aligns = item.alignments or {}
    local rows = {}
    if type(item.rows) == "table" and #item.rows > 0 then
        for _, parts in ipairs(item.rows) do
            rows[#rows + 1] = semantic_table_cells(parts)
        end
    else
        for row = start_row + 2, end_row do
            rows[#rows + 1] = table_cells(lines[row + 1] or "")
        end
    end
    local widths = {}
    for index, cell in ipairs(header) do
        widths[index] = math.max(1, vim.fn.strdisplaywidth(cell))
    end
    for _, cells in ipairs(rows) do
        for index = 1, #widths do
            widths[index] = math.max(widths[index], vim.fn.strdisplaywidth(cells[index] or ""))
        end
    end
    local rendered = { table_row(header, widths, aligns), table_border(widths, "├", "┼", "┤") }
    for _, cells in ipairs(rows) do
        rendered[#rendered + 1] = table_row(cells, widths, aligns)
    end
    for index, text in ipairs(rendered) do
        local row = start_row + index - 1
        local source_line = lines[row + 1] or ""
        add(decorations, {
            row = row,
            col = 0,
            end_col = #source_line,
            conceal = "",
            virt_text = {
                {
                    text,
                    index == 1 and "AgentWorkbenchMarkdownTableHeader" or "AgentWorkbenchMarkdownTableBorder",
                },
            },
            virt_text_pos = "overlay",
            priority = 130,
            reveal = reveal_range(row, 0, row, #source_line),
            hide_when_revealed = true,
        })
    end
    add(decorations, {
        row = start_row,
        col = 0,
        virt_lines = { { { table_border(widths, "┌", "┬", "┐"), "AgentWorkbenchMarkdownTableBorder" } } },
        virt_lines_above = true,
        priority = 130,
    })
    add(decorations, {
        row = end_row,
        col = 0,
        virt_lines = { { { table_border(widths, "└", "┴", "┘"), "AgentWorkbenchMarkdownTableBorder" } } },
        priority = 130,
    })
end

---@param lines string[]
---@param item table
---@param decorations agent_workbench.MarkdownDecoration[]
---@param opts table
---@return boolean width_dependent
local function render_markdown_item(lines, item, decorations, opts)
    local features = opts.features or {}
    local symbols = opts.symbols or {}
    local range = item.range or {}
    local class = item.class
    local owner = semantic_reveal_range(range)
    if class == "markdown_atx_heading" and features.headings ~= false then
        local line = lines[range.row_start + 1] or ""
        local marker = item.marker or "#"
        add(decorations, {
            row = range.row_start,
            col = range.col_start or 0,
            end_col = math.min(#line, (range.col_start or 0) + #marker + 1),
            conceal = "",
            priority = 120,
            reveal = owner,
            hide_when_revealed = owner ~= nil,
        })
        add(decorations, {
            row = range.row_start,
            col = range.col_start or 0,
            end_col = #line,
            hl_group = "AgentWorkbenchMarkdownHeading" .. math.min(6, #marker),
            priority = 115,
        })
    elseif class == "markdown_setext_heading" and features.headings ~= false then
        local row = range.row_start
        local line = lines[row + 1] or ""
        local underline_row = math.max(row, (range.row_end or row + 2) - 1)
        local underline = lines[underline_row + 1] or ""
        add(decorations, {
            row = row,
            col = range.col_start or 0,
            end_col = #line,
            hl_group = "AgentWorkbenchMarkdownHeading"
                .. ((type(item.marker) == "string" and item.marker:sub(1, 1) == "=") and 1 or 2),
            priority = 115,
        })
        add(decorations, {
            row = underline_row,
            col = 0,
            end_col = #underline,
            conceal = "",
            priority = 120,
            reveal = owner,
            hide_when_revealed = owner ~= nil,
        })
    elseif class == "markdown_block_quote" and features.block_quotes ~= false then
        for row = range.row_start or 0, (range.row_end or 0) - 1 do
            local line = lines[row + 1] or ""
            local col = line:find(">", 1, true)
            if col then
                add(decorations, {
                    row = row,
                    col = col - 1,
                    end_col = math.min(#line, col + (line:sub(col + 1, col + 1) == " " and 1 or 0)),
                    conceal = "",
                    virt_text = { { symbols.block_quote or "│", "AgentWorkbenchMarkdownBlockQuote" }, { " " } },
                    virt_text_pos = "inline",
                    line_hl_group = "AgentWorkbenchMarkdownBlockQuote",
                    priority = 120,
                    reveal = owner,
                    hide_when_revealed = owner ~= nil,
                })
            end
        end
    elseif class == "markdown_list_item" and features.lists ~= false then
        local line = lines[(range.row_start or 0) + 1] or ""
        local marker = item.marker or "-"
        local col = line:find(marker, 1, true)
        if col then
            if not marker:match("^%d+[.)]$") then
                add(decorations, {
                    row = range.row_start,
                    col = col - 1,
                    end_col = col - 1 + #marker,
                    conceal = "",
                    virt_text = { { symbols.bullet or "•", "AgentWorkbenchMarkdownListMarker" } },
                    virt_text_pos = "inline",
                    priority = 120,
                    reveal = owner,
                    hide_when_revealed = owner ~= nil,
                })
            end
        end
    elseif (class == "markdown_checkbox" or class == "inline_checkbox") and features.checkboxes ~= false then
        local checked = item.state == "x" or item.state == "X"
        add(decorations, {
            row = range.row_start,
            col = range.col_start,
            end_row = range.row_end,
            end_col = range.col_end,
            conceal = "",
            virt_text = {
                {
                    checked and (symbols.checked or "󰄲") or (symbols.unchecked or "󰄱"),
                    checked and "AgentWorkbenchMarkdownCheckboxChecked" or "AgentWorkbenchMarkdownCheckboxUnchecked",
                },
            },
            virt_text_pos = "inline",
            priority = 125,
            reveal = owner,
            hide_when_revealed = owner ~= nil,
        })
    elseif class == "markdown_code_block" and features.code_blocks ~= false then
        local start_row = range.row_start
        local end_row = math.max(start_row, (range.row_end or start_row + 1) - 1)
        for row = start_row, end_row do
            add(decorations, {
                row = row,
                col = 0,
                line_hl_group = "AgentWorkbenchMarkdownCodeBlock",
                priority = 105,
            })
        end
        local language = item.language or item.info_string
        if language and language ~= "" then
            add(decorations, {
                row = start_row,
                col = range.start_delim and range.start_delim[2] or 0,
                virt_text = { { " " .. language .. " ", "AgentWorkbenchMarkdownCodeInfo" } },
                virt_text_pos = "inline",
                priority = 125,
                reveal = owner,
                hide_when_revealed = owner ~= nil,
            })
        end
    elseif class == "markdown_table" and features.tables ~= false then
        render_table(lines, item, decorations)
    elseif class == "markdown_hr" and features.horizontal_rules ~= false then
        local row = range.row_start
        local line = lines[row + 1] or ""
        local width = math.max(1, opts.width or 80)
        add(decorations, {
            row = row,
            col = 0,
            end_col = #line,
            conceal = "",
            virt_text = {
                {
                    string.rep(symbols.horizontal_rule or "─", width),
                    "AgentWorkbenchMarkdownHorizontalRule",
                },
            },
            virt_text_pos = "overlay",
            priority = 130,
            reveal = owner,
            hide_when_revealed = owner ~= nil,
        })
        return true
    end
    return false
end

---@param item table
---@param decorations agent_workbench.MarkdownDecoration[]
---@param opts table
local function render_inline_item(item, decorations, opts)
    local features = opts.features or {}
    local symbols = opts.symbols or {}
    local range = item.range or {}
    local owner = semantic_reveal_range(range)
    if item.class and item.class:match("^inline_link_") and features.links ~= false then
        add(decorations, {
            row = range.row_start,
            col = range.col_start,
            virt_text = { { symbols.link or "󰌹 ", "AgentWorkbenchMarkdownLink" } },
            virt_text_pos = "inline",
            priority = 120,
            reveal = owner,
            hide_when_revealed = owner ~= nil,
        })
    end
end

---@param source string
---@param opts { width: integer, features: table, symbols: table }
---@return agent_workbench.MarkdownPlan?, string?
function M.compile(source, opts)
    opts = opts or {}
    if source == "" then
        return { decorations = {}, width_dependent = false }
    end
    local ok_parser, markview_parser = pcall(require, "markview.parser")
    if not ok_parser or type(markview_parser.init) ~= "function" then
        return nil, "Markview parser is unavailable; install a compatible markview.nvim"
    end

    local buffer = ensure_scratch()
    local lines = vim.split(source, "\n", { plain = true })
    vim.bo[buffer].modifiable = true
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false

    local ok_tree, parser = pcall(vim.treesitter.get_parser, buffer, "markdown")
    if not ok_tree or not parser then
        return nil, "Markdown Tree-sitter parser is unavailable"
    end
    local ok_parse, parse_error = pcall(parser.parse, parser, true)
    if not ok_parse then
        return nil, "Markdown Tree-sitter parse failed: " .. tostring(parse_error)
    end

    local ok_markview, data, sorted = pcall(markview_parser.init, buffer, 0, -1, false)
    if not ok_markview then
        return nil, "Markview parser failed: " .. tostring(data)
    end
    if type(data) ~= "table" or type(sorted) ~= "table" then
        return nil, "Markview parser returned an incompatible result"
    end

    -- Injection containment is derived from raw CommonMark fences instead of
    -- Markview node ranges. That keeps language captures stable across Markview
    -- range-shape changes while still excluding HTML/LaTeX-style injections.
    local code_ranges = fenced_code_ranges(source)

    local decorations = {}
    local ok_captures, capture_error =
        pcall(add_tree_sitter_decorations, parser, buffer, decorations, opts.features or {}, code_ranges)
    if not ok_captures then
        return nil, "Markdown highlight query failed: " .. tostring(capture_error)
    end

    local width_dependent = false
    for _, item in ipairs(data.markdown or {}) do
        local ok_item, result = pcall(render_markdown_item, lines, item, decorations, opts)
        if not ok_item then
            return nil, "Markdown node renderer failed for " .. tostring(item.class) .. ": " .. tostring(result)
        end
        width_dependent = width_dependent or result == true
    end
    for _, item in ipairs(data.markdown_inline or {}) do
        local ok_item, item_error = pcall(render_inline_item, item, decorations, opts)
        if not ok_item then
            return nil, "Markdown inline renderer failed for " .. tostring(item.class) .. ": " .. tostring(item_error)
        end
    end

    return {
        decorations = decorations,
        width_dependent = width_dependent,
    }
end

function M.cleanup()
    if scratch_buf and vim.api.nvim_buf_is_valid(scratch_buf) then
        pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
    end
    scratch_buf = nil
end

M._reset = M.cleanup

return M
