local Ansi = require("agent-workbench.ui.chat.terminal.ansi")

local M = {}

local ns = vim.api.nvim_create_namespace("pi-shell-output")
local MAX_ANSI_BYTES = 128 * 1024
local MAX_DECORATIONS = 4000
local MAX_PATH_PROBES = 256
local MAX_SEMANTIC_BYTES = 256 * 1024
local MAX_STYLE_GROUPS = 512
local style_groups = {}
local style_group_count = 0

local ANSI_16 = {
    "#000000",
    "#cd0000",
    "#00cd00",
    "#cdcd00",
    "#0000ee",
    "#cd00cd",
    "#00cdcd",
    "#e5e5e5",
    "#7f7f7f",
    "#ff0000",
    "#00ff00",
    "#ffff00",
    "#5c5cff",
    "#ff00ff",
    "#00ffff",
    "#ffffff",
}

---@class agent_workbench.ShellOutputSpan
---@field row integer 0-based within command output
---@field start_col integer 0-based byte column
---@field end_col integer exclusive byte column
---@field hl_group? string
---@field style? agent_workbench.ShellAnsiStyle
---@field priority integer
---@field hl_eol? boolean

---@class agent_workbench.ShellOutputIcon
---@field row integer 0-based within command output
---@field col integer 0-based byte column
---@field text string
---@field hl_group string

---@class agent_workbench.ShellOutputDecorations
---@field kind "text"|"json"|"diff"
---@field spans agent_workbench.ShellOutputSpan[]
---@field icons agent_workbench.ShellOutputIcon[]

---@param lines string[]
---@return integer
local function byte_count(lines)
    local count = math.max(0, #lines - 1)
    for _, line in ipairs(lines) do
        count = count + #line
    end
    return count
end

---@param left string[]
---@param right string[]
---@return boolean
local function same_lines(left, right)
    if #left ~= #right then
        return false
    end
    for index, line in ipairs(left) do
        if right[index] ~= line then
            return false
        end
    end
    return true
end

---@param decorations agent_workbench.ShellOutputDecorations
---@param span agent_workbench.ShellOutputSpan
local function add_span(decorations, span)
    if #decorations.spans + #decorations.icons >= MAX_DECORATIONS or span.end_col <= span.start_col then
        return
    end
    decorations.spans[#decorations.spans + 1] = span
end

---@param decorations agent_workbench.ShellOutputDecorations
---@param icon agent_workbench.ShellOutputIcon
local function add_icon(decorations, icon)
    if #decorations.spans + #decorations.icons >= MAX_DECORATIONS then
        return
    end
    decorations.icons[#decorations.icons + 1] = icon
end

---@param lines string[]
---@param decorations agent_workbench.ShellOutputDecorations
local function add_diff(lines, decorations)
    local is_diff = false
    local saw_old = false
    for _, line in ipairs(lines) do
        if line:match("^diff %-%-git ") or line:match("^@@ ") then
            is_diff = true
            break
        end
        if line:match("^%-%-%- ") then
            saw_old = true
        elseif saw_old and line:match("^%+%+%+ ") then
            is_diff = true
            break
        end
    end
    if not is_diff then
        return
    end
    decorations.kind = "diff"
    local in_hunk = false
    local old_remaining
    local new_remaining
    for row, line in ipairs(lines) do
        local group
        local eol = false
        if line:match("^diff %-%-git ") then
            in_hunk = false
            old_remaining = nil
            new_remaining = nil
            group = "Comment"
        elseif line:match("^@@ ") then
            in_hunk = true
            local old_count, new_count = line:match("^@@ %-%d+,?(%d*) %+%d+,?(%d*) @@")
            old_remaining = old_count and (tonumber(old_count) or 1) or nil
            new_remaining = new_count and (tonumber(new_count) or 1) or nil
            group = "PiShellDiffHunk"
        elseif in_hunk then
            local prefix = line:sub(1, 1)
            if prefix == "+" then
                group = "PiDiffAdd"
                eol = true
                new_remaining = new_remaining and math.max(0, new_remaining - 1) or nil
            elseif prefix == "-" then
                group = "PiDiffDelete"
                eol = true
                old_remaining = old_remaining and math.max(0, old_remaining - 1) or nil
            elseif prefix == " " then
                old_remaining = old_remaining and math.max(0, old_remaining - 1) or nil
                new_remaining = new_remaining and math.max(0, new_remaining - 1) or nil
            end
            if old_remaining == 0 and new_remaining == 0 then
                in_hunk = false
            end
        elseif line:match("^index ") or line:match("^%-%-%- ") or line:match("^%+%+%+ ") then
            group = "Comment"
        end
        if group then
            add_span(decorations, {
                row = row - 1,
                start_col = 0,
                end_col = #line,
                hl_group = group,
                priority = 130,
                hl_eol = eol,
            })
        end
    end
end

---@param lines string[]
---@param decorations agent_workbench.ShellOutputDecorations
---@return boolean
local function add_json(lines, decorations)
    local text = table.concat(lines, "\n")
    local trimmed = vim.trim(text)
    if not trimmed:match("^[%[{]") then
        return false
    end
    local decoded = pcall(vim.json.decode, text)
    if not decoded then
        return false
    end
    decorations.kind = "json"
    local ok = pcall(function()
        local parser = vim.treesitter.get_string_parser(text, "json")
        local trees = parser:parse()
        local query = vim.treesitter.query.get("json", "highlights")
        if not trees or not trees[1] or not query then
            return
        end
        for id, node in query:iter_captures(trees[1]:root(), text) do
            if #decorations.spans + #decorations.icons >= MAX_DECORATIONS then
                break
            end
            local start_row, start_col, end_row, end_col = node:range()
            local group = "@" .. query.captures[id] .. ".json"
            for row = start_row, end_row do
                add_span(decorations, {
                    row = row,
                    start_col = row == start_row and start_col or 0,
                    end_col = row == end_row and end_col or #(lines[row + 1] or ""),
                    hl_group = group,
                    priority = 120,
                })
            end
        end
    end)
    return ok
end

---@param line string
---@param decorations agent_workbench.ShellOutputDecorations
---@param row integer
local function add_urls(line, decorations, row)
    local offset = 1
    while offset <= #line do
        if #decorations.spans + #decorations.icons >= MAX_DECORATIONS then
            return
        end
        local start_col, end_col = line:find("https?://[^%s%]%)}>,\"']+", offset)
        if not start_col then
            break
        end
        end_col = assert(end_col)
        add_span(decorations, {
            row = row,
            start_col = start_col - 1,
            end_col = end_col,
            hl_group = "PiShellUrl",
            priority = 160,
        })
        offset = end_col + 1
    end
end

local LEADING_PATH_PUNCTUATION = "\"'`([{<"
local TRAILING_PATH_PUNCTUATION = "\"'`,;:)]}>"

---@param token string
---@return string, integer
local function path_from_token(token)
    local first = 1
    while first <= #token and LEADING_PATH_PUNCTUATION:find(token:sub(first, first), 1, true) do
        first = first + 1
    end
    local last = #token
    while last >= first and TRAILING_PATH_PUNCTUATION:find(token:sub(last, last), 1, true) do
        last = last - 1
    end
    local candidate = token:sub(first, last)
    candidate = candidate:match("^(.-):%d+:%d+$") or candidate:match("^(.-):%d+$") or candidate
    return candidate, first - 1
end

---@param cwd string
---@param candidate string
---@return string
local function absolute_path(cwd, candidate)
    if candidate:sub(1, 2) == "~/" then
        return vim.fs.normalize(vim.fn.expand("~") .. candidate:sub(2))
    end
    if vim.startswith(candidate, "/") then
        return vim.fs.normalize(candidate)
    end
    return vim.fs.normalize(cwd .. "/" .. candidate)
end

---@class agent_workbench.ShellPathCandidate
---@field row integer
---@field start_col integer
---@field candidate string
---@field leading integer
---@field priority integer
---@field sequence integer

---@param lines string[]
---@return agent_workbench.ShellPathCandidate[]
local function path_candidates(lines)
    local candidates = {}
    local sequence = 0
    for row, line in ipairs(lines) do
        local offset = 1
        while offset <= #line do
            local start_col, end_col = line:find("%S+", offset)
            if not start_col then
                break
            end
            end_col = assert(end_col)
            local candidate, leading = path_from_token(line:sub(start_col, end_col))
            if
                candidate ~= ""
                and candidate ~= "."
                and candidate ~= ".."
                and #candidate <= 512
                and not candidate:find("://", 1, true)
            then
                sequence = sequence + 1
                local priority = end_col == #line and 100 or 0
                if candidate:find("/", 1, true) then
                    priority = priority + 50
                end
                if candidate:sub(1, 1) == "." or candidate:sub(1, 2) == "~/" then
                    priority = priority + 25
                end
                if candidate:match("%.[%w_%-]+$") then
                    priority = priority + 10
                end
                candidates[#candidates + 1] = {
                    row = row - 1,
                    start_col = start_col - 1,
                    candidate = candidate,
                    leading = leading,
                    priority = priority,
                    sequence = sequence,
                }
            end
            offset = end_col + 1
            -- ponytail: inspect first decoration-budget tokens; add viewport-lazy scanning if later paths matter.
            if #candidates >= MAX_DECORATIONS then
                break
            end
        end
        if #candidates >= MAX_DECORATIONS then
            break
        end
    end
    table.sort(candidates, function(left, right)
        if left.priority == right.priority then
            return left.sequence < right.sequence
        end
        return left.priority > right.priority
    end)
    return candidates
end

---@param lines string[]
---@param cwd string|string[]
---@param decorations agent_workbench.ShellOutputDecorations
local function add_paths(lines, cwd, decorations)
    ---@type string[]
    local cwd_candidates = type(cwd) == "table" and cwd or { cwd }
    local candidates = path_candidates(lines)
    local likely_paths = 0
    for _, item in ipairs(candidates) do
        likely_paths = likely_paths + (item.priority > 0 and 1 or 0)
    end
    if likely_paths > MAX_PATH_PROBES then
        return
    end
    local stat_cache = {}
    local probes = 0
    local probe_limit = MAX_PATH_PROBES * math.max(1, #cwd_candidates)
    local devicons_ok, devicons = pcall(require, "nvim-web-devicons")
    for _, item in ipairs(candidates) do
        if #decorations.spans + #decorations.icons >= MAX_DECORATIONS then
            return
        end
        local path
        local stat
        for _, base in ipairs(cwd_candidates) do
            local resolved = absolute_path(base, item.candidate)
            local cached = stat_cache[resolved]
            if cached == nil and probes < probe_limit then
                probes = probes + 1
                cached = vim.uv.fs_stat(resolved) or false
                stat_cache[resolved] = cached
            end
            if cached then
                path = resolved
                stat = cached
                break
            end
        end
        if path and stat then
            local group = stat.type == "directory" and "Directory" or "PiShellPath"
            local icon
            if devicons_ok then
                if stat.type == "directory" then
                    icon = ""
                else
                    local filename = vim.fs.basename(path)
                    local extension = vim.fn.fnamemodify(filename, ":e")
                    local resolved, icon_group = devicons.get_icon(filename, extension, { default = true })
                    icon = resolved
                    group = icon_group or group
                end
            end
            local path_start = item.start_col + item.leading
            add_span(decorations, {
                row = item.row,
                start_col = path_start,
                end_col = path_start + #item.candidate,
                hl_group = group,
                priority = 150,
            })
            if icon then
                add_icon(decorations, {
                    row = item.row,
                    col = path_start,
                    text = icon .. " ",
                    hl_group = group,
                })
            end
        end
    end
end

---@param lines string[]
---@param raw_bytes string
---@param cwd string|string[]
---@return agent_workbench.ShellOutputDecorations
function M.analyze(lines, raw_bytes, cwd)
    local decorations = { kind = "text", spans = {}, icons = {} }
    -- ponytail: skip ANSI projection above 128 KiB; stream styles if large colored output becomes common.
    if #raw_bytes <= MAX_ANSI_BYTES then
        local parsed = Ansi.parse(raw_bytes, MAX_DECORATIONS)
        if parsed.valid and same_lines(parsed.lines, lines) then
            for _, span in ipairs(parsed.spans) do
                add_span(decorations, {
                    row = span.row,
                    start_col = span.start_col,
                    end_col = span.end_col,
                    style = span.style,
                    priority = 220,
                })
            end
        end
    end

    -- ponytail: bound semantic extmarks; switch to viewport-lazy decoration if huge outputs need full styling.
    if byte_count(lines) > MAX_SEMANTIC_BYTES then
        return decorations
    end
    if not add_json(lines, decorations) then
        add_diff(lines, decorations)
    end
    for row, line in ipairs(lines) do
        add_urls(line, decorations, row - 1)
    end
    add_paths(lines, cwd, decorations)
    return decorations
end

---@param color integer|string?
---@return integer|string?
local function resolve_color(color)
    if type(color) ~= "number" then
        return color
    end
    if color < 16 then
        return vim.g["terminal_color_" .. color] or ANSI_16[color + 1]
    end
    if color < 232 then
        local index = color - 16
        local red = math.floor(index / 36)
        local green = math.floor(index % 36 / 6)
        local blue = index % 6
        local values = { 0, 95, 135, 175, 215, 255 }
        return ("#%02x%02x%02x"):format(values[red + 1], values[green + 1], values[blue + 1])
    end
    local gray = 8 + (color - 232) * 10
    return ("#%02x%02x%02x"):format(gray, gray, gray)
end

---@param color integer|string
---@return integer?
local function color_number(color)
    if type(color) == "number" then
        return color
    end
    local resolved = vim.api.nvim_get_color_by_name(color)
    return resolved >= 0 and resolved or nil
end

---@param foreground integer|string
---@param background integer|string
---@return string
local function faint_color(foreground, background)
    local fg = color_number(foreground) or 0xffffff
    local bg = color_number(background) or 0x000000
    local function channel(value, divisor)
        return math.floor(value / divisor) % 256
    end
    local red = math.floor((channel(fg, 0x10000) + channel(bg, 0x10000)) / 2)
    local green = math.floor((channel(fg, 0x100) + channel(bg, 0x100)) / 2)
    local blue = math.floor((channel(fg, 1) + channel(bg, 1)) / 2)
    return ("#%02x%02x%02x"):format(red, green, blue)
end

---@param name string
---@param style agent_workbench.ShellAnsiStyle
local function define_ansi_group(name, style)
    local foreground = resolve_color(style.fg)
    local background = resolve_color(style.bg)
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    if style.reverse then
        foreground, background = background or normal.bg, foreground or normal.fg
    end
    if style.faint then
        local default_foreground = vim.o.background == "light" and "#000000" or "#ffffff"
        local default_background = vim.o.background == "light" and "#ffffff" or "#000000"
        foreground =
            faint_color(foreground or normal.fg or default_foreground, background or normal.bg or default_background)
    end
    vim.api.nvim_set_hl(0, name, {
        fg = foreground,
        bg = background,
        bold = style.bold,
        italic = style.italic,
        underline = style.underline or style.link ~= nil,
        strikethrough = style.strikethrough,
    })
end

---@param style agent_workbench.ShellAnsiStyle
---@return string?
local function ansi_group(style)
    local key = table.concat({
        tostring(style.fg or ""),
        tostring(style.bg or ""),
        style.bold and "1" or "",
        style.faint and "1" or "",
        style.italic and "1" or "",
        style.underline and "1" or "",
        style.reverse and "1" or "",
        style.strikethrough and "1" or "",
        style.link and "1" or "",
    }, ":")
    local cached = style_groups[key]
    if cached then
        return cached.name
    end
    if style_group_count >= MAX_STYLE_GROUPS then
        return nil
    end
    local name = "PiShellAnsi_" .. vim.fn.sha256(key):sub(1, 12)
    local copy = vim.deepcopy(style)
    define_ansi_group(name, copy)
    style_groups[key] = { name = name, style = copy }
    style_group_count = style_group_count + 1
    return name
end

---@param buf integer
function M.clear(buf)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

---@param buf integer
---@param start_row integer 0-based output start row
---@param decorations agent_workbench.ShellOutputDecorations
function M.render(buf, start_row, decorations)
    local line_count = vim.api.nvim_buf_line_count(buf)
    local lines = {}
    ---@param row integer
    ---@return string
    local function line_at(row)
        if lines[row] == nil then
            lines[row] = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
        end
        return lines[row]
    end

    for _, span in ipairs(decorations.spans) do
        local row = start_row + span.row
        if row >= 0 and row < line_count then
            local line = line_at(row)
            local start_col = math.min(span.start_col, #line)
            local end_col = math.min(span.end_col, #line)
            local hl_group = span.style and ansi_group(span.style) or span.hl_group
            if end_col > start_col and hl_group then
                vim.api.nvim_buf_set_extmark(buf, ns, row, start_col, {
                    end_col = end_col,
                    hl_group = hl_group,
                    hl_eol = span.hl_eol,
                    priority = span.priority,
                })
            end
        end
    end
    for _, icon in ipairs(decorations.icons) do
        local row = start_row + icon.row
        if row >= 0 and row < line_count then
            local line = line_at(row)
            vim.api.nvim_buf_set_extmark(buf, ns, row, math.min(icon.col, #line), {
                virt_text = { { icon.text, icon.hl_group } },
                virt_text_pos = "inline",
                priority = 140,
            })
        end
    end
end

---@return integer
function M.namespace()
    return ns
end

function M._reset()
    for _, spec in pairs(style_groups) do
        vim.api.nvim_set_hl(0, spec.name, {})
    end
    style_groups = {}
    style_group_count = 0
end

local group = vim.api.nvim_create_augroup("PiShellOutputColors", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
        for _, spec in pairs(style_groups) do
            define_ansi_group(spec.name, spec.style)
        end
    end,
})

return M
