---@class agent_workbench.ShellAnsiStyle
---@field fg? integer|string ANSI palette index or `#rrggbb`
---@field bg? integer|string ANSI palette index or `#rrggbb`
---@field bold? boolean
---@field faint? boolean
---@field italic? boolean
---@field underline? boolean
---@field reverse? boolean
---@field strikethrough? boolean
---@field link? string

---@class agent_workbench.ShellAnsiSpan
---@field row integer 0-based
---@field start_col integer 0-based byte column
---@field end_col integer exclusive byte column
---@field style agent_workbench.ShellAnsiStyle

---@class agent_workbench.ShellAnsiResult
---@field lines string[]
---@field spans agent_workbench.ShellAnsiSpan[]
---@field valid boolean false when unsupported terminal controls may have changed screen text

local M = {}

local STYLE_FIELDS = {
    "fg",
    "bg",
    "bold",
    "faint",
    "italic",
    "underline",
    "reverse",
    "strikethrough",
    "link",
}

---@param style agent_workbench.ShellAnsiStyle
---@return agent_workbench.ShellAnsiStyle
local function copy_style(style)
    local copy = {}
    for _, field in ipairs(STYLE_FIELDS) do
        copy[field] = style[field]
    end
    return copy
end

---@param style agent_workbench.ShellAnsiStyle
---@return string
local function style_key(style)
    local parts = {}
    for _, field in ipairs(STYLE_FIELDS) do
        local value = style[field]
        if value ~= nil and value ~= false then
            parts[#parts + 1] = field .. "=" .. tostring(value)
        end
    end
    return table.concat(parts, ";")
end

---@param params string
---@return integer[]?, boolean
local function sgr_params(params)
    if params:find(":", 1, true) then
        return nil, false
    end
    if params == "" then
        return { 0 }, true
    end
    local values = {}
    for value in (params .. ";"):gmatch("(.-);") do
        if value == "" then
            values[#values + 1] = 0
        else
            local number = tonumber(value)
            if not number then
                return nil, false
            end
            values[#values + 1] = number
        end
    end
    return values, true
end

---@param style agent_workbench.ShellAnsiStyle
---@param params string
---@return boolean
local function apply_sgr(style, params)
    local values, valid = sgr_params(params)
    if not valid or not values then
        return false
    end
    local index = 1
    while index <= #values do
        local value = values[index]
        if value == 0 then
            local link = style.link
            for key in pairs(style) do
                style[key] = nil
            end
            style.link = link
        elseif value == 1 then
            style.bold = true
        elseif value == 2 then
            style.faint = true
        elseif value == 3 then
            style.italic = true
        elseif value == 4 then
            style.underline = true
        elseif value == 7 then
            style.reverse = true
        elseif value == 9 then
            style.strikethrough = true
        elseif value == 22 then
            style.bold = nil
            style.faint = nil
        elseif value == 23 then
            style.italic = nil
        elseif value == 24 then
            style.underline = nil
        elseif value == 27 then
            style.reverse = nil
        elseif value == 29 then
            style.strikethrough = nil
        elseif value >= 30 and value <= 37 then
            style.fg = value - 30
        elseif value == 38 or value == 48 then
            local field = value == 38 and "fg" or "bg"
            local mode = values[index + 1]
            if mode == 5 and values[index + 2] and values[index + 2] >= 0 and values[index + 2] <= 255 then
                style[field] = values[index + 2]
                index = index + 2
            elseif
                mode == 2
                and values[index + 2]
                and values[index + 3]
                and values[index + 4]
                and values[index + 2] >= 0
                and values[index + 2] <= 255
                and values[index + 3] >= 0
                and values[index + 3] <= 255
                and values[index + 4] >= 0
                and values[index + 4] <= 255
            then
                style[field] = ("#%02x%02x%02x"):format(values[index + 2], values[index + 3], values[index + 4])
                index = index + 4
            else
                return false
            end
        elseif value == 39 then
            style.fg = nil
        elseif value >= 40 and value <= 47 then
            style.bg = value - 40
        elseif value == 49 then
            style.bg = nil
        elseif value >= 90 and value <= 97 then
            style.fg = value - 90 + 8
        elseif value >= 100 and value <= 107 then
            style.bg = value - 100 + 8
        elseif value ~= 5 and value ~= 6 and value ~= 25 then
            return false
        end
        index = index + 1
    end
    return true
end

---@param bytes string
---@param max_spans? integer
---@return agent_workbench.ShellAnsiResult
function M.parse(bytes, max_spans)
    local lines = { "" }
    local spans = {}
    local style = {}
    local valid = true
    local row = 1
    local run_key
    local run_start = 0
    local run_style
    local trailing_newlines = 0

    local function flush_run()
        if run_key and run_key ~= "" and #lines[row] > run_start and (not max_spans or #spans < max_spans) then
            spans[#spans + 1] = {
                row = row - 1,
                start_col = run_start,
                end_col = #lines[row],
                style = assert(run_style),
            }
        end
        run_key = nil
        run_style = nil
    end

    ---@param text string
    local function append(text)
        if text == "" then
            return
        end
        trailing_newlines = 0
        local key = style_key(style)
        if run_key ~= key then
            flush_run()
            run_key = key
            run_start = #lines[row]
            run_style = copy_style(style)
        end
        lines[row] = lines[row] .. text
    end

    local function newline()
        flush_run()
        row = row + 1
        lines[row] = ""
        trailing_newlines = trailing_newlines + 1
    end

    local index = 1
    while index <= #bytes do
        local byte = bytes:byte(index)
        if byte == 27 then
            local kind = bytes:sub(index + 1, index + 1)
            if kind == "[" then
                local finish = bytes:find("[@-~]", index + 2)
                if not finish then
                    valid = false
                    break
                end
                local command = bytes:sub(finish, finish)
                local params = bytes:sub(index + 2, finish - 1)
                if command == "m" then
                    valid = apply_sgr(style, params) and valid
                else
                    valid = false
                end
                index = finish + 1
            elseif kind == "]" then
                local content_start = index + 2
                local bell = bytes:find("\7", content_start, true)
                local string_end = bytes:find("\27\\", content_start, true)
                local finish
                local width
                if bell and (not string_end or bell < string_end) then
                    finish = bell
                    width = 1
                elseif string_end then
                    finish = string_end
                    width = 2
                end
                if not finish then
                    valid = false
                    break
                end
                local content = bytes:sub(content_start, finish - 1)
                local link = content:match("^8;[^;]*;(.*)$")
                if link ~= nil then
                    style.link = link ~= "" and link or nil
                end
                index = finish + assert(width)
            else
                valid = false
                index = math.min(#bytes + 1, index + 2)
            end
        elseif byte == 10 then
            newline()
            index = index + 1
        elseif byte == 13 and bytes:byte(index + 1) == 10 then
            newline()
            index = index + 2
        elseif byte == 9 then
            valid = false
            append("\t")
            index = index + 1
        elseif byte < 32 or byte == 127 then
            valid = false
            trailing_newlines = 0
            index = index + 1
        else
            local finish = index + 1
            while finish <= #bytes do
                local next_byte = bytes:byte(finish)
                if next_byte < 32 or next_byte == 127 then
                    break
                end
                finish = finish + 1
            end
            append(bytes:sub(index, finish - 1))
            index = finish
        end
    end
    flush_run()

    while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
    end
    local blanks = trailing_newlines - (#lines > 0 and 1 or 0)
    for _ = 1, math.max(0, blanks) do
        lines[#lines + 1] = ""
    end

    return { lines = lines, spans = spans, valid = valid }
end

return M
