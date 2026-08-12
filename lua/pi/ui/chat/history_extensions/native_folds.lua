--- Native fold policy for chat history buffers.

local M = {}

---@param values table<integer, string|integer>
---@param start_row integer 0-indexed
---@param end_row integer 0-indexed, inclusive
---@param level integer
local function add_fold(values, start_row, end_row, level)
    if end_row <= start_row then
        return
    end
    local first = start_row + 1
    local last = end_row + 1
    values[first] = ">" .. level
    for line = first + 1, last - 1 do
        values[line] = math.max(tonumber(values[line]) or 0, level)
    end
    values[last] = "<" .. level
end

---@param history pi.ChatHistory
---@return table<integer, string|integer>
function M.values(history)
    local changedtick = vim.b[history._buf].changedtick
    if history._fold_changedtick == changedtick and history._fold_values then
        return history._fold_values
    end

    local values = {}
    local message_ranges = {}
    local line_count = vim.api.nvim_buf_line_count(history._buf)
    local i = 1
    while i <= #history._message_blocks do
        local block = history._message_blocks[i]
        local row = history:_extmark_row(block.anchor)
        local next_index = i + 1
        if block.role == "assistant" then
            while next_index <= #history._message_blocks and history._message_blocks[next_index].role == "assistant" do
                next_index = next_index + 1
            end
        end
        local next_block = history._message_blocks[next_index]
        local next_row = next_block and history:_extmark_row(next_block.anchor)
        if row then
            local last = next_row and (next_row - 1) or (line_count - 1)
            if last > row then
                message_ranges[#message_ranges + 1] = { row = row, last = last }
                add_fold(values, row, last, 1)
            end
        end
        i = next_index
    end

    local function nested_level(row)
        for _, range in ipairs(message_ranges) do
            if row > range.row and row <= range.last then
                return 2
            end
        end
        return 1
    end

    if history._startup_block_line_count > 1 then
        add_fold(values, 0, history._startup_block_line_count - 1, 1)
    end
    for _, block in ipairs(history._compaction_blocks) do
        local row = history:_extmark_row(block.anchor)
        if row then
            add_fold(values, row, row + block.line_count - 1, nested_level(row))
        end
    end
    for _, block in ipairs(history._thinking_blocks) do
        local row = block.visible and history:_extmark_row(block.anchor) or nil
        if row then
            add_fold(values, row, row + block.line_count - 1, nested_level(row))
        end
    end
    local tool_ranges = {}
    for _, block in pairs(history._tool_blocks) do
        local first = block.foldable and history:_extmark_row(block.icon_extmark) or nil
        local last = block.foldable and history:_extmark_row(block.end_extmark) or nil
        if first and last then
            local anchor = block.preview_anchor_extmark and history:_extmark_row(block.preview_anchor_extmark) or last
            if not block.batch_child and last > first then
                -- Keep ordinary tool footer outside fold as stable cursor/status anchor.
                last = last - 1
            elseif block.preview_lines and anchor and anchor > first then
                last = anchor - 1
            end
            tool_ranges[#tool_ranges + 1] = { first = first, last = last }
        end
    end
    table.sort(tool_ranges, function(a, b)
        return a.first == b.first and a.last > b.last or a.first < b.first
    end)
    for _, range in ipairs(tool_ranges) do
        local level = nested_level(range.first)
        for _, parent in ipairs(tool_ranges) do
            if parent.first < range.first and parent.last >= range.last then
                level = level + 1
            end
        end
        add_fold(values, range.first, range.last, level)
    end

    history._fold_changedtick = changedtick
    history._fold_values = values
    return values
end

---@param history pi.ChatHistory
function M.refresh(history)
    for _, win in ipairs(vim.fn.win_findbuf(history._buf)) do
        vim.api.nvim_win_call(win, function()
            local view = vim.fn.winsaveview()
            for _, block in pairs(history._tool_blocks) do
                if block.foldable and not block._skip_fold_capture then
                    local row = history:_extmark_row(block.icon_extmark)
                    if row and vim.fn.foldlevel(row + 1) > 0 then
                        block.expanded = vim.fn.foldclosed(row + 1) == -1
                    end
                end
            end

            vim.cmd("silent! normal! zx")
            for _, block in pairs(history._tool_blocks) do
                if block.foldable and not block.expanded then
                    local row = history:_extmark_row(block.icon_extmark)
                    if row then
                        vim.cmd("silent! " .. (row + 1) .. "foldclose")
                    end
                end
            end
            history:_open_active_output_folds()
            vim.fn.winrestview(view)
        end)
    end
    for _, block in pairs(history._tool_blocks) do
        block._skip_fold_capture = false
    end
end

local function disable_external_foldtext(filetype)
    local ok, origami_config = pcall(require, "origami.config")
    if not ok or not origami_config.config or not origami_config.config.foldtext then
        return
    end
    local disabled = origami_config.config.foldtext.disableOnFt
    if type(disabled) ~= "table" or vim.list_contains(disabled, filetype) then
        return
    end
    disabled[#disabled + 1] = filetype
end

---@param text string
---@return string
function M.preview(text)
    return vim.trim(text:gsub("%s+", " "))
end

---@param args table
---@return string?
function M.argument_summary(args)
    for _, key in ipairs({ "command", "cmd", "query", "path", "file_path", "url" }) do
        if type(args[key]) == "string" and args[key] ~= "" then
            return M.preview(args[key])
        end
    end
    for _, key in ipairs({ "calls", "tool_uses", "queries" }) do
        if type(args[key]) == "table" and #args[key] > 0 then
            return #args[key] .. " " .. key:gsub("_", " ")
        end
    end
end

---@param text string
---@param width integer
---@return string
function M.truncate(text, width)
    if width <= 0 then
        return ""
    end
    if vim.fn.strdisplaywidth(text) <= width then
        return text
    end
    local chars = vim.fn.strchars(text)
    while chars > 0 do
        local candidate = vim.fn.strcharpart(text, 0, chars) .. "…"
        if vim.fn.strdisplaywidth(candidate) <= width then
            return candidate
        end
        chars = chars - 1
    end
    return ""
end

---@param header string
---@param header_hl string
---@param summary string?
---@param status string?
---@param status_hl string?
---@param line_count integer
---@return table
local function build_fold_text(header, header_hl, summary, status, status_hl, line_count)
    local win = vim.api.nvim_get_current_win()
    local width = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or 80
    local info = vim.fn.getwininfo(win)[1]
    width = math.max(1, width - (info and info.textoff or 0))

    local prefix = " " .. header
    local status_text = status and ("  · " .. status) or ""
    local count_text = ("  [%d lines]"):format(line_count)
    local summary_width = width
        - vim.fn.strdisplaywidth(prefix)
        - vim.fn.strdisplaywidth(status_text)
        - vim.fn.strdisplaywidth(count_text)
        - 2
    local summary_text = summary and M.truncate(summary, summary_width) or ""

    local chunks = { { prefix, header_hl } }
    if summary_text ~= "" then
        chunks[#chunks + 1] = { "  " .. summary_text, "Folded" }
    end
    if status_text ~= "" then
        chunks[#chunks + 1] = { status_text, status_hl or "Comment" }
    end
    chunks[#chunks + 1] = { count_text, "Comment" }
    return chunks
end

---@param history pi.ChatHistory
---@param start_row integer 0-indexed
---@param end_row integer 0-indexed
---@return string|table
function M.foldtext(history, start_row, end_row)
    local header = vim.api.nvim_buf_get_lines(history._buf, start_row, start_row + 1, false)[1] or ""
    local line_count = end_row - start_row + 1

    for _, block in pairs(history._tool_blocks) do
        local first = history:_extmark_row(block.icon_extmark)
        if first == start_row then
            local args = block.tool_input or {}
            local summary = M.argument_summary(args)
            local status = not block.finished and "running"
                or (block.end_hl_group == "PiToolError" and "failed" or "completed")
            return build_fold_text(
                block.fold_header or header,
                block.end_hl_group == "PiToolError" and "PiToolError" or "PiToolHeader",
                summary,
                status,
                status == "failed" and "PiToolError" or "Comment",
                block.output_line_count or line_count
            )
        end
    end

    for _, message in ipairs(history._message_blocks) do
        if history:_extmark_row(message.anchor) == start_row then
            local nested = {}
            local tool_count = 0
            local batch_call_count = 0
            for _, block in pairs(history._tool_blocks) do
                local first = history:_extmark_row(block.icon_extmark)
                local last = history:_extmark_row(block.end_extmark)
                if first and last and first > start_row and last <= end_row then
                    if block.tool_name == "tool_batch" then
                        local calls = block.tool_input and block.tool_input.calls
                        batch_call_count = type(calls) == "table" and #calls or 0
                    else
                        tool_count = tool_count + 1
                    end
                    for row = first, last do
                        nested[row] = true
                    end
                end
            end
            tool_count = math.max(tool_count, batch_call_count)
            for _, block in ipairs(history._thinking_blocks) do
                local first = block.visible and history:_extmark_row(block.anchor) or nil
                if first and first > start_row then
                    for row = first, math.min(end_row, first + block.line_count - 1) do
                        nested[row] = true
                    end
                end
            end

            local preview
            local lines = vim.api.nvim_buf_get_lines(history._buf, start_row + 1, end_row + 1, false)
            for offset, line in ipairs(lines) do
                local row = start_row + offset
                line = vim.trim(line)
                if not nested[row] and line ~= "" and not line:match("^```+") then
                    preview = M.preview(line)
                    break
                end
            end
            if not preview and tool_count > 0 then
                preview = tool_count .. (tool_count == 1 and " tool" or " tools")
            end
            local hl = message.role == "user" and "PiUserMessageLabel" or "PiAgentResponseLabel"
            return build_fold_text(header, hl, preview or "(empty)", nil, nil, line_count)
        end
    end

    local preview
    local lines = vim.api.nvim_buf_get_lines(history._buf, start_row + 1, end_row + 1, false)
    for _, line in ipairs(lines) do
        line = vim.trim(line)
        if line ~= "" and not line:match("^```+") then
            preview = M.preview(line)
            break
        end
    end
    return build_fold_text(header, "Folded", preview, nil, nil, line_count)
end

---@param history pi.ChatHistory
---@param anchor integer
---@param level integer
---@param status_anchor? integer
function M.activate_output(history, anchor, level, status_anchor)
    local previous = history._active_fold_anchors[level]
    if previous and previous ~= anchor then
        local row = history:_extmark_row(previous)
        if row then
            for _, win in ipairs(vim.fn.win_findbuf(history._buf)) do
                vim.api.nvim_win_call(win, function()
                    vim.cmd("silent! " .. (row + 1) .. "foldclose")
                end)
            end
        end
    end
    history._active_fold_anchors[level] = anchor
    if level == 1 then
        local child = history._active_fold_anchors[2]
        if child then
            local row = history:_extmark_row(child)
            if row then
                for _, win in ipairs(vim.fn.win_findbuf(history._buf)) do
                    vim.api.nvim_win_call(win, function()
                        vim.cmd("silent! " .. (row + 1) .. "foldclose")
                    end)
                end
            end
        end
        history._active_fold_anchors[2] = nil
    end
    history._status_anchor_id = status_anchor
    M.open_active(history)
    if history._status_text or #history._pending_queue > 0 then
        history:_update_status_extmark()
    end
end

---@param history pi.ChatHistory
function M.open_active(history)
    for level = 1, 2 do
        local anchor = history._active_fold_anchors[level]
        local row = anchor and history:_extmark_row(anchor) or nil
        if row then
            for _, win in ipairs(vim.fn.win_findbuf(history._buf)) do
                vim.api.nvim_win_call(win, function()
                    if vim.fn.foldclosed(row + 1) ~= -1 then
                        vim.cmd("silent! " .. (row + 1) .. "foldopen")
                    end
                end)
            end
        end
    end
end

---@param history pi.ChatHistory
function M.close_active(history)
    local child = history._active_fold_anchors[2]
    local child_row = child and history:_extmark_row(child) or nil
    local parent = history._active_fold_anchors[1]
    local parent_row = parent and history:_extmark_row(parent) or nil
    for _, win in ipairs(vim.fn.win_findbuf(history._buf)) do
        vim.api.nvim_win_call(win, function()
            if child_row then
                vim.cmd("silent! " .. (child_row + 1) .. "foldclose")
            end
            if parent_row then
                vim.cmd("silent! " .. (parent_row + 1) .. "foldopen")
            end
        end)
    end
    history._active_fold_anchors = {}
    history._status_anchor_id = nil
end

---@param history pi.ChatHistory
---@param win integer
function M.capture_state(history, win)
    if not history._fold_state_initialized or not vim.api.nvim_win_is_valid(win) then
        return
    end
    local states = {}
    vim.api.nvim_win_call(win, function()
        local function capture(anchor)
            local row = history:_extmark_row(anchor)
            if row and vim.fn.foldlevel(row + 1) > 0 then
                states[anchor] = vim.fn.foldclosed(row + 1) == -1
            end
        end
        for _, block in ipairs(history._message_blocks) do
            capture(block.anchor)
        end
        for _, block in ipairs(history._thinking_blocks) do
            if block.visible then
                capture(block.anchor)
            end
        end
        for _, block in ipairs(history._compaction_blocks) do
            capture(block.anchor)
        end
        for _, block in pairs(history._tool_blocks) do
            if block.foldable then
                capture(block.icon_extmark)
            end
        end
    end)
    history._fold_open_state = states
end

---@param history pi.ChatHistory
---@param win integer
function M.restore_state(history, win)
    if not vim.api.nvim_win_is_valid(win) then
        return
    end
    vim.api.nvim_win_call(win, function()
        for anchor, open in pairs(history._fold_open_state) do
            if open then
                local row = history:_extmark_row(anchor)
                if row then
                    vim.cmd("silent! " .. (row + 1) .. "foldopen")
                end
            end
        end
    end)
end

---@param history pi.ChatHistory
---@param win integer
function M.configure_window(history, win)
    if
        not vim.api.nvim_buf_is_valid(history._buf)
        or not vim.api.nvim_win_is_valid(win)
        or vim.api.nvim_win_get_buf(win) ~= history._buf
    then
        return
    end
    disable_external_foldtext(vim.bo[history._buf].filetype)
    vim.wo[win].foldenable = true
    vim.wo[win].foldcolumn = "1"
    vim.wo[win].foldmethod = "expr"
    vim.wo[win].foldexpr = "v:lua.require'pi.ui.chat.history'.nvim_foldexpr(v:lnum)"
    vim.wo[win].foldtext = "v:lua.require'pi.ui.chat.history'.nvim_foldtext()"
end

return M
