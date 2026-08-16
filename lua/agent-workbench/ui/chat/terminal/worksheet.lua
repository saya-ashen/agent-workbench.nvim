local Output = require("agent-workbench.ui.chat.terminal.output")
local Completion = require("agent-workbench.ui.chat.terminal.shell.completion")
local Session = require("agent-workbench.ui.chat.terminal.shell.session")

local marks_ns = vim.api.nvim_create_namespace("pi-shell-worksheet-marks")
local prompt_ns = vim.api.nvim_create_namespace("pi-shell-worksheet-prompt")
local PREVIEW_LINES = 8
local INPUT_PREFIX = "  "
local worksheets = {}

---@class agent_workbench.ShellBlock
---@field command_row integer
---@field command_end_row integer
---@field output_start? integer
---@field output_end? integer
---@field status? integer
---@field duration_ms? integer
---@field cwd_before? string
---@field cwd_after? string
---@field folded? boolean
---@field fold_created? boolean
---@field raw_bytes? string
---@field decorations? agent_workbench.ShellOutputDecorations
---@field command_mark? integer
---@field command_end_mark? integer
---@field output_start_mark? integer
---@field output_end_mark? integer
---@field capture_buf? integer
---@field capture_chan? integer
---@field finishing? boolean
---@field preview_pending? boolean

---@class agent_workbench.ShellResult
---@field block agent_workbench.ShellBlock
---@field output string[]
---@field status integer
---@field duration_ms integer
---@field cwd_after? string

---@class agent_workbench.ShellFold
---@field start integer
---@field finish integer
---@field closed boolean

---@class agent_workbench.ShellWorksheet
---@field _cwd string
---@field _buf integer?
---@field _win integer?
---@field _lines string[]
---@field _cursor integer[]?
---@field _current_start integer
---@field _prompt_mark integer?
---@field _active agent_workbench.ShellBlock?
---@field _blocks agent_workbench.ShellBlock[]
---@field _pending_results agent_workbench.ShellResult[]
---@field _user_folds agent_workbench.ShellFold[]
---@field _running boolean
---@field _win_foldmethod string?
---@field _win_foldenable boolean?
---@field _win_foldtext string?
---@field _undo_path string?
---@field _undolevels integer?
---@field _revision integer
---@field _undo_revision integer?
---@field _protection_group integer?
---@field _protected_lines string[]
---@field _repairing boolean
---@field _output_dirty boolean
---@field _completion_generation integer
---@field _completion_cache table<string, string>
---@field _session agent_workbench.ShellSession
---@field completion_context fun(self: agent_workbench.ShellWorksheet, cursor: integer[]): agent_workbench.ShellCompletionContext?
---@field request_completion fun(self: agent_workbench.ShellWorksheet, commandline: string, current: string, callback: fun(output: string, parent_output?: string)): boolean, string?
local Worksheet = {}
Worksheet.__index = Worksheet

---@param buf integer
---@return string[]
local function buffer_lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param lines string[]
---@return string[]
local function without_terminal_padding(lines, raw_bytes)
    while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
    end
    local trailing_newlines = 0
    local index = #raw_bytes
    while index > 0 and raw_bytes:byte(index) == 10 do
        trailing_newlines = trailing_newlines + 1
        index = index - 1
        if index > 0 and raw_bytes:byte(index) == 13 then
            index = index - 1
        end
    end
    local blanks = trailing_newlines - (#lines > 0 and 1 or 0)
    for _ = 1, blanks do
        lines[#lines + 1] = ""
    end
    return lines
end

---@param cwd string
---@return agent_workbench.ShellWorksheet
function Worksheet.new(cwd)
    local self = setmetatable({}, Worksheet)
    self._cwd = cwd
    self._buf = nil
    self._win = nil
    self._lines = { INPUT_PREFIX }
    self._cursor = nil
    self._current_start = 1
    self._prompt_mark = nil
    self._active = nil
    self._blocks = {}
    self._pending_results = {}
    self._user_folds = {}
    self._running = false
    self._win_foldmethod = nil
    self._win_foldenable = nil
    self._win_foldtext = nil
    self._undo_path = nil
    self._undolevels = nil
    self._revision = 0
    self._undo_revision = nil
    self._protection_group = nil
    self._protected_lines = {}
    self._repairing = false
    self._output_dirty = true
    self._completion_generation = 0
    self._completion_cache = {}
    self._session = Session.new({
        cwd = cwd,
        on_output = function(bytes)
            self:_append_output(bytes)
        end,
        on_end = function(status, duration_ms, shell_cwd)
            self:_finish(status, duration_ms, shell_cwd)
        end,
        on_exit = function(code)
            if self._running then
                self:_finish(code == 0 and 1 or code, 0)
            end
        end,
    })
    return self
end

---@return boolean
function Worksheet:alive()
    return self._session:alive()
end

---@return boolean
function Worksheet:running()
    return self._running
end

---@param mark integer?
---@return integer?
function Worksheet:_mark_row(mark)
    if not mark or not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return nil
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, marks_ns, mark, {})
    return #pos > 0 and (pos[1] + 1) or nil
end

function Worksheet:_sync()
    local buf = self._buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    for _, block in ipairs(self._blocks) do
        block.command_row = self:_mark_row(block.command_mark) or block.command_row
        block.command_end_row = self:_mark_row(block.command_end_mark) or block.command_end_row
        block.output_start = self:_mark_row(block.output_start_mark) or block.output_start
        block.output_end = self:_mark_row(block.output_end_mark) or block.output_end
    end
    if self._active then
        self._active.command_row = self:_mark_row(self._active.command_mark) or self._active.command_row
        self._active.command_end_row = self:_mark_row(self._active.command_end_mark) or self._active.command_end_row
    end
    self._lines = buffer_lines(buf)
end

---@param block agent_workbench.ShellBlock
---@return string[]
function Worksheet:_capture_lines(block)
    if not block.capture_buf or not vim.api.nvim_buf_is_valid(block.capture_buf) then
        return {}
    end
    return without_terminal_padding(buffer_lines(block.capture_buf), block.raw_bytes or "")
end

---@param block agent_workbench.ShellBlock
function Worksheet:_close_capture(block)
    if block.capture_buf and vim.api.nvim_buf_is_valid(block.capture_buf) then
        pcall(vim.api.nvim_buf_delete, block.capture_buf, { force = true })
    end
    block.capture_buf = nil
    block.capture_chan = nil
end

---@param block agent_workbench.ShellBlock
---@return table[]?
function Worksheet:_preview(block)
    local lines = self:_capture_lines(block)
    if #lines == 0 then
        return nil
    end
    local first = math.max(1, #lines - PREVIEW_LINES + 1)
    local preview = {}
    for index = first, #lines do
        preview[#preview + 1] = { { "  " .. lines[index], "Comment" } }
    end
    return preview
end

function Worksheet:_snapshot_folds()
    local win = self._win
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    local managed = {}
    for _, block in ipairs(self._blocks) do
        if block.output_start and block.output_end then
            managed[("%d:%d"):format(block.output_start, block.output_end)] = true
            block.folded = vim.api.nvim_win_call(win, function()
                return vim.fn.foldclosed(block.output_start) ~= -1
            end)
        end
    end
    local user_folds = {}
    local buf = assert(self._buf)
    vim.api.nvim_win_call(win, function()
        local row = 1
        local line_count = vim.api.nvim_buf_line_count(buf)
        while row <= line_count do
            local start = vim.fn.foldclosed(row)
            local closed = start ~= -1
            if not closed and vim.fn.foldlevel(row) > 0 then
                vim.cmd(("silent! %dfoldclose"):format(row))
                start = vim.fn.foldclosed(row)
            end
            if start == -1 then
                row = row + 1
            else
                local finish = vim.fn.foldclosedend(row)
                if not managed[("%d:%d"):format(start, finish)] then
                    user_folds[#user_folds + 1] = { start = start, finish = finish, closed = closed }
                end
                if not closed then
                    vim.cmd(("silent! %dfoldopen"):format(start))
                end
                row = finish + 1
            end
        end
    end)
    self._user_folds = user_folds
end

function Worksheet:_render_marks()
    local buf = self._buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, marks_ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, prompt_ns, 0, -1)
    local render_output = self._output_dirty
    if render_output then
        Output.clear(buf)
    end
    local line_count = vim.api.nvim_buf_line_count(buf)
    for _, block in ipairs(self._blocks) do
        if block.command_row <= line_count then
            vim.api.nvim_buf_set_extmark(buf, prompt_ns, block.command_row - 1, 0, {
                right_gravity = false,
                virt_text = { { "❯ ", "PiShellPrompt" } },
                virt_text_pos = "inline",
            })
            local group = block.status == 0 and "PiShellSuccess" or "PiShellFailure"
            block.command_mark = vim.api.nvim_buf_set_extmark(buf, marks_ns, block.command_row - 1, 0, {
                right_gravity = false,
                virt_text = { { ("  exit %d · %dms"):format(block.status or 1, block.duration_ms or 0), group } },
                virt_text_pos = "eol",
            })
            block.command_end_mark = vim.api.nvim_buf_set_extmark(buf, marks_ns, block.command_end_row - 1, 0, {
                right_gravity = false,
            })
            if block.output_start and block.output_end and block.output_start <= line_count then
                if render_output and block.decorations then
                    Output.render(buf, block.output_start - 1, block.decorations)
                end
                block.output_start_mark = vim.api.nvim_buf_set_extmark(buf, marks_ns, block.output_start - 1, 0, {
                    right_gravity = true,
                })
                block.output_end_mark = vim.api.nvim_buf_set_extmark(
                    buf,
                    marks_ns,
                    math.min(block.output_end, line_count) - 1,
                    0,
                    { right_gravity = false }
                )
            end
        end
    end
    self._output_dirty = false
    if self._active and self._active.command_row <= line_count then
        vim.api.nvim_buf_set_extmark(buf, prompt_ns, self._active.command_row - 1, 0, {
            right_gravity = false,
            virt_text = { { "❯ ", "PiShellPrompt" } },
            virt_text_pos = "inline",
        })
        self._active.command_mark = vim.api.nvim_buf_set_extmark(buf, marks_ns, self._active.command_row - 1, 0, {
            right_gravity = false,
            virt_text = { { "  running", "PiShellRunning" } },
            virt_text_pos = "eol",
            virt_lines = self:_preview(self._active),
        })
        self._active.command_end_mark = vim.api.nvim_buf_set_extmark(
            buf,
            marks_ns,
            self._active.command_end_row - 1,
            #(self._lines[self._active.command_end_row] or ""),
            { right_gravity = false }
        )
    end
    self._prompt_mark = nil
    if self._current_start <= line_count then
        self._prompt_mark = vim.api.nvim_buf_set_extmark(buf, prompt_ns, self._current_start - 1, 0, {
            right_gravity = true,
            virt_text = { { "❯ ", "PiShellPrompt" } },
            virt_text_pos = "overlay",
        })
    end
end

function Worksheet:_update_modifiable()
    local buf, win = self._buf, self._win
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local editable = win
        and vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_cursor(win)[1] >= self._current_start
    vim.bo[buf].modifiable = editable == true
end

function Worksheet:_update_protected()
    self._protected_lines = {}
    for index = 1, self._current_start - 1 do
        self._protected_lines[index] = self._lines[index]
    end
end

function Worksheet:_repair_protected()
    local buf = self._buf
    if self._repairing or not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local input_row = self._current_start
    if self._prompt_mark then
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, prompt_ns, self._prompt_mark, {})
        if #pos > 0 then
            input_row = pos[1] + 1
        end
    end
    local lines = buffer_lines(buf)
    local input_line = lines[input_row] or ""
    local input_prefixed = input_line:sub(1, #INPUT_PREFIX) == INPUT_PREFIX
    local unchanged = input_prefixed and input_row - 1 == #self._protected_lines
    if unchanged then
        for index, line in ipairs(self._protected_lines) do
            if lines[index] ~= line then
                unchanged = false
                break
            end
        end
    end
    if unchanged then
        return
    end

    local suffix = {}
    for index = input_row, #lines do
        suffix[#suffix + 1] = lines[index]
    end
    local prefix_delta = 0
    if #suffix == 0 then
        suffix = { INPUT_PREFIX }
        prefix_delta = #INPUT_PREFIX
    elseif not input_prefixed then
        local content = suffix[1]:gsub("^ *", "")
        prefix_delta = #INPUT_PREFIX - (#suffix[1] - #content)
        suffix[1] = INPUT_PREFIX .. content
    end
    local repaired = vim.deepcopy(self._protected_lines)
    vim.list_extend(repaired, suffix)
    local win = self._win
    local cursor = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_cursor(win) or nil
    local row_delta = #self._protected_lines - (input_row - 1)
    self._repairing = true
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, repaired)
    self._current_start = #self._protected_lines + 1
    self._lines = repaired
    self._output_dirty = true
    self:_render_marks()
    if cursor and win and vim.api.nvim_win_is_valid(win) then
        if cursor[1] >= input_row then
            cursor[1] = math.max(self._current_start, math.min(#repaired, cursor[1] + row_delta))
            if cursor[1] == self._current_start then
                cursor[2] = cursor[2] + prefix_delta
            end
            cursor[2] = math.min(cursor[2], #(repaired[cursor[1]] or ""))
        else
            cursor = { self._current_start, #INPUT_PREFIX }
        end
        pcall(vim.api.nvim_win_set_cursor, win, cursor)
    end
    self._repairing = false
    self:_update_modifiable()
end

function Worksheet:_install_protection()
    if self._protection_group then
        pcall(vim.api.nvim_del_augroup_by_id, self._protection_group)
    end
    local buf = assert(self._buf)
    self._protection_group = vim.api.nvim_create_augroup("pi-shell-worksheet-" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter", "WinEnter" }, {
        group = self._protection_group,
        buffer = buf,
        callback = function()
            if self._buf == buf then
                self:_update_modifiable()
            end
        end,
    })
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = self._protection_group,
        buffer = buf,
        callback = function(event)
            if self._buf == buf then
                self:_repair_protected()
                if event.event == "TextChangedI" then
                    self:_schedule_completion()
                end
            end
        end,
    })
end

---@param rebuild boolean?
function Worksheet:_apply_folds(rebuild)
    local win = self._win
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    vim.api.nvim_win_call(win, function()
        vim.wo[win].foldmethod = "manual"
        vim.wo[win].foldenable = true
        vim.wo[win].foldtext = "v:lua.require'agent-workbench.ui.chat.terminal.worksheet'.foldtext()"
        if rebuild then
            vim.cmd("silent! normal! zE")
            for _, fold in ipairs(self._user_folds) do
                vim.cmd(("silent! %d,%dfold"):format(fold.start, fold.finish))
                if not fold.closed then
                    vim.cmd(("silent! %dfoldopen"):format(fold.start))
                end
            end
        end
        for _, block in ipairs(self._blocks) do
            if
                (rebuild or not block.fold_created)
                and block.output_start
                and block.output_end
                and block.output_end > block.output_start
            then
                vim.cmd(("silent! %d,%dfold"):format(block.output_start, block.output_end))
                if block.folded then
                    vim.cmd(("silent! %dfoldclose"):format(block.output_start))
                else
                    vim.cmd(("silent! %dfoldopen"):format(block.output_start))
                end
                block.fold_created = true
            end
        end
        pcall(vim.fn.winrestview, view)
    end)
end

---@param force_lines? boolean
---@param rebuild_folds? boolean
function Worksheet:_render(force_lines, rebuild_folds)
    local buf = self._buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local win = self._win
    local view = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_call(win, vim.fn.winsaveview) or nil
    vim.bo[buf].modifiable = true
    if force_lines or not vim.deep_equal(buffer_lines(buf), self._lines) then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, self._lines)
        self._output_dirty = true
    end
    self:_render_marks()
    self:_apply_folds(rebuild_folds)
    if view and win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_call(win, function()
            pcall(vim.fn.winrestview, view)
        end)
    end
    self:_update_modifiable()
end

function Worksheet:_save_undo()
    local buf = self._buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    if self._undo_path then
        vim.fn.delete(self._undo_path)
    end
    self._undolevels = vim.bo[buf].undolevels
    local path = vim.fn.tempname()
    local ok = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("silent wundo! " .. vim.fn.fnameescape(path))
    end)
    if ok and vim.fn.filereadable(path) == 1 then
        self._undo_path = path
        self._undo_revision = self._revision
    else
        vim.fn.delete(path)
        self._undo_path = nil
        self._undo_revision = nil
    end
end

function Worksheet:_restore_undo()
    local buf = self._buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local levels = self._undolevels or vim.bo[buf].undolevels
    local path = self._undo_path
    vim.bo[buf].modifiable = true
    vim.bo[buf].undolevels = -1
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, self._lines)
    vim.bo[buf].undolevels = levels
    self._undo_path = nil
    if path and self._undo_revision == self._revision then
        pcall(vim.api.nvim_buf_call, buf, function()
            vim.cmd("silent rundo " .. vim.fn.fnameescape(path))
        end)
    end
    self._undo_revision = nil
    if path then
        vim.fn.delete(path)
    end
end

---@param buf integer
---@param win integer?
function Worksheet:show(buf, win)
    if self._buf == buf and vim.api.nvim_buf_is_valid(buf) and vim.b[buf].pi_shell_worksheet then
        self._win = win
        self:_update_modifiable()
        return
    end
    self._buf = buf
    self._win = win
    worksheets[buf] = self
    vim.b[buf].pi_shell_worksheet = true
    if win and vim.api.nvim_win_is_valid(win) then
        self._win_foldmethod = vim.wo[win].foldmethod
        self._win_foldenable = vim.wo[win].foldenable
        self._win_foldtext = vim.wo[win].foldtext
    end
    self:_restore_undo()
    self:_render(nil, true)
    if win and vim.api.nvim_win_is_valid(win) then
        if self._cursor then
            local row = math.min(self._cursor[1], #self._lines)
            pcall(vim.api.nvim_win_set_cursor, win, { row, math.min(self._cursor[2], #(self._lines[row] or "")) })
        else
            pcall(vim.api.nvim_win_set_cursor, win, { self._current_start, #INPUT_PREFIX })
        end
    end
    local pending = self._pending_results
    self._pending_results = {}
    for _, result in ipairs(pending) do
        self:_apply_result(result.block, result.output, result.status, result.duration_ms, result.cwd_after)
    end
    self:_install_protection()
    self:_update_modifiable()
end

function Worksheet:hide()
    self._completion_generation = self._completion_generation + 1
    local buf, win = self._buf, self._win
    if self._protection_group then
        pcall(vim.api.nvim_del_augroup_by_id, self._protection_group)
        self._protection_group = nil
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modifiable = true
        self:_snapshot_folds()
        self:_sync()
        self:_save_undo()
        for _, block in ipairs(self._blocks) do
            block.fold_created = false
        end
        vim.api.nvim_buf_clear_namespace(buf, marks_ns, 0, -1)
        vim.api.nvim_buf_clear_namespace(buf, prompt_ns, 0, -1)
        Output.clear(buf)
        self._output_dirty = true
        vim.b[buf].pi_shell_worksheet = false
        worksheets[buf] = nil
    end
    if win and vim.api.nvim_win_is_valid(win) then
        self._cursor = vim.api.nvim_win_get_cursor(win)
        if self._win_foldmethod then
            vim.wo[win].foldmethod = self._win_foldmethod
            vim.wo[win].foldenable = self._win_foldenable
            vim.wo[win].foldtext = self._win_foldtext
        end
    end
    self._buf = nil
    self._win = nil
end

---@param bytes string
function Worksheet:_append_output(bytes)
    local active = self._active
    if not active or not active.capture_chan then
        return
    end
    active.raw_bytes = (active.raw_bytes or "") .. bytes
    pcall(vim.api.nvim_chan_send, active.capture_chan, bytes)
    if self._buf and not active.preview_pending then
        active.preview_pending = true
        vim.defer_fn(function()
            active.preview_pending = false
            if self._active == active and self._buf then
                self:_render_marks()
            end
        end, 16)
    end
end

---@param status integer
---@param duration_ms integer
---@param cwd_after? string
function Worksheet:_finish(status, duration_ms, cwd_after)
    local active = self._active
    if not active or active.finishing then
        return
    end
    active.finishing = true
    vim.defer_fn(function()
        if self._active == active then
            self:_finalize(active, status, duration_ms, cwd_after)
        end
    end, 10)
end

---@param active agent_workbench.ShellBlock
---@param status integer
---@param duration_ms integer
---@param cwd_after? string
function Worksheet:_finalize(active, status, duration_ms, cwd_after)
    active.finishing = nil
    active.preview_pending = nil
    self:_sync()
    local output = self:_capture_lines(active)
    self:_close_capture(active)
    self._running = false
    self._active = nil
    if not self._buf then
        self._pending_results[#self._pending_results + 1] = {
            block = active,
            output = output,
            status = status,
            duration_ms = duration_ms,
            cwd_after = cwd_after,
        }
        return
    end
    self:_apply_result(active, output, status, duration_ms, cwd_after)
end

---@param active agent_workbench.ShellBlock
---@param output string[]
---@param status integer
---@param duration_ms integer
---@param cwd_after? string
function Worksheet:_apply_result(active, output, status, duration_ms, cwd_after)
    self:_sync()
    local buf = assert(self._buf)
    local win = self._win
    local cursor = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_cursor(win) or nil
    local cursor_in_input = cursor ~= nil and cursor[1] >= self._current_start
    local follow = self:_at_bottom()
    local insert_after = math.min(active.command_end_row, #self._lines)
    local inserted = vim.deepcopy(output)
    inserted[#inserted + 1] = ""
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, insert_after, insert_after, false, inserted)
    self._lines = buffer_lines(buf)
    if #output > 0 then
        active.output_start = insert_after + 1
        active.output_end = insert_after + #output
    end
    if self._current_start > insert_after then
        self._current_start = self._current_start + #inserted
    end
    active.status = status
    active.duration_ms = duration_ms
    active.cwd_after = cwd_after or active.cwd_before or self._cwd
    -- ponytail: try command-end then command-start cwd; add per-output cwd frames only if mid-command cd becomes common.
    local cwd_candidates = { active.cwd_after }
    if active.cwd_before and active.cwd_before ~= active.cwd_after then
        cwd_candidates[#cwd_candidates + 1] = active.cwd_before
    end
    active.decorations = Output.analyze(output, active.raw_bytes or "", cwd_candidates)
    self._cwd = active.cwd_after
    self._output_dirty = true
    active.folded = false
    active.fold_created = false
    self._blocks[#self._blocks + 1] = active
    self._revision = self._revision + 1
    self:_update_protected()
    self:_render_marks()
    self:_apply_folds()
    if follow then
        self:_scroll_bottom()
    elseif cursor_in_input and cursor and win and vim.api.nvim_win_is_valid(win) then
        cursor[1] = math.min(cursor[1] + #inserted, #self._lines)
        pcall(vim.api.nvim_win_set_cursor, win, cursor)
    end
    self:_update_modifiable()
end

---@return boolean
function Worksheet:_at_bottom()
    local win = self._win
    if not win or not vim.api.nvim_win_is_valid(win) then
        return false
    end
    return vim.api.nvim_win_call(win, function()
        return vim.fn.line("w$") >= vim.api.nvim_buf_line_count(0) - 1
    end)
end

function Worksheet:_scroll_bottom()
    local win = self._win
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_call(win, function()
            vim.cmd("normal! G$zb")
            pcall(vim.api.nvim_win_set_cursor, win, { self._current_start, #INPUT_PREFIX })
        end)
    end
end

---@param command string
function Worksheet:set_input(command)
    self:_sync()
    local buf = assert(self._buf)
    local lines = vim.split(command, "\n", { plain = true })
    lines[1] = INPUT_PREFIX .. (lines[1] or "")
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, self._current_start - 1, -1, false, lines)
    self._lines = buffer_lines(buf)
    self:_render_marks()
    self:_update_modifiable()
end

---@return boolean
function Worksheet:cursor_in_input()
    local win = self._win
    return win ~= nil and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_cursor(win)[1] >= self._current_start
end

---@return boolean
function Worksheet:input_empty()
    local buf = self._buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return true
    end
    local lines = vim.api.nvim_buf_get_lines(buf, self._current_start - 1, -1, false)
    if (lines[1] or ""):sub(1, #INPUT_PREFIX) == INPUT_PREFIX then
        lines[1] = lines[1]:sub(#INPUT_PREFIX + 1)
    end
    return vim.trim(table.concat(lines, "\n")) == ""
end

function Worksheet:focus_input()
    local buf, win = self._buf, self._win
    if not buf or not vim.api.nvim_buf_is_valid(buf) or not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    local row = vim.api.nvim_buf_line_count(buf)
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
    vim.bo[buf].modifiable = true
    pcall(vim.api.nvim_win_set_cursor, win, { row, #line })
    vim.cmd("startinsert!")
end

---@param cursor integer[]
---@return agent_workbench.ShellCompletionContext?
function Worksheet:completion_context(cursor)
    local buf = self._buf
    if self._running or not buf or not vim.api.nvim_buf_is_valid(buf) then
        return nil
    end
    return Completion.context(buffer_lines(buf), self._current_start, cursor)
end

---@param commandline string
---@param current string
---@param callback fun(output: string, parent_output?: string)
---@return boolean, string?
function Worksheet:request_completion(commandline, current, callback)
    local function send_current(parent_output)
        local cached = self._completion_cache[commandline]
        if cached then
            callback(cached, parent_output)
            return true
        end
        return self._session:complete(commandline, function(output)
            self._completion_cache[commandline] = output
            callback(output, parent_output)
        end)
    end

    if not current or #current <= 1 or current:sub(1, 1) ~= "-" then
        return send_current(nil)
    end
    local parent_commandline = commandline:sub(1, -2)
    local cached_parent = self._completion_cache[parent_commandline]
    if cached_parent then
        return send_current(cached_parent)
    end
    return self._session:complete(parent_commandline, function(output)
        self._completion_cache[parent_commandline] = output
        send_current(output)
    end)
end

---@param force boolean?
---@param generation integer?
---@return boolean
function Worksheet:_request_completion(force, generation)
    local buf, win = self._buf, self._win
    if
        self._running
        or not buf
        or not vim.api.nvim_buf_is_valid(buf)
        or not win
        or not vim.api.nvim_win_is_valid(win)
        or vim.api.nvim_get_current_buf() ~= buf
        or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i"
    then
        return false
    end
    local context = Completion.context(buffer_lines(buf), self._current_start, vim.api.nvim_win_get_cursor(win))
    if not context or (not force and context.base == "" and vim.trim(context.commandline) == "") then
        return false
    end
    generation = generation or (self._completion_generation + 1)
    self._completion_generation = generation
    local requested_line = context.commandline
    local requested_col = context.start_col
    local ok = self:request_completion(requested_line, context.base, function(output, parent_output)
        if generation ~= self._completion_generation then
            return
        end
        local current_buf, current_win = self._buf, self._win
        if
            current_buf ~= buf
            or current_win ~= win
            or vim.api.nvim_get_current_buf() ~= buf
            or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i"
        then
            return
        end
        local current = Completion.context(buffer_lines(buf), self._current_start, vim.api.nvim_win_get_cursor(win))
        if not current or current.commandline ~= requested_line or current.start_col ~= requested_col then
            return
        end
        local items = Completion.parse_with_parent(output, current.base, parent_output)
        if #items == 0 then
            if vim.fn.pumvisible() == 1 then
                vim.api.nvim_feedkeys(vim.keycode("<C-e>"), "n", false)
            end
            return
        end
        vim.fn.complete(current.start_col, items)
    end)
    return ok == true
end

function Worksheet:_schedule_completion()
    self._completion_generation = self._completion_generation + 1
    local buf, win = self._buf, self._win
    if buf and win and vim.b[buf].pi_shell_blink_completion then
        local context = Completion.context(buffer_lines(buf), self._current_start, vim.api.nvim_win_get_cursor(win))
        if context and context.commandline:match("%s$") and vim.trim(context.commandline) ~= "" then
            local ok, blink = pcall(require, "blink.cmp")
            if ok and type(blink.show) == "function" then
                blink.show({ providers = { "pi_shell_fish" } })
            end
        end
        return
    end
    local generation = self._completion_generation
    vim.defer_fn(function()
        if generation ~= self._completion_generation then
            return
        end
        local buf = self._buf
        if not buf or vim.api.nvim_get_current_buf() ~= buf or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
            return
        end
        self:_request_completion(false, generation)
    end, 80)
end

---@return boolean
function Worksheet:complete()
    self._completion_generation = self._completion_generation + 1
    return self:_request_completion(true, self._completion_generation)
end

---@return boolean, string?
function Worksheet:execute_current()
    self._completion_generation = self._completion_generation + 1
    self._completion_cache = {}
    if self._running then
        return false, "shell command is already running"
    end
    local buf = self._buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return false, "shell worksheet is not visible"
    end
    self:_snapshot_folds()
    self:_sync()
    local lines = vim.list_slice(self._lines, self._current_start, #self._lines)
    while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
        table.remove(self._lines)
    end
    if (lines[1] or ""):sub(1, #INPUT_PREFIX) == INPUT_PREFIX then
        lines[1] = lines[1]:sub(#INPUT_PREFIX + 1)
    end
    local command = table.concat(lines, "\n")
    if vim.trim(command) == "" then
        return false, "shell command is empty"
    end

    self._lines[self._current_start] = lines[1]
    for index = 2, #lines do
        self._lines[self._current_start + index - 1] = lines[index]
    end

    local capture_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[capture_buf].bufhidden = "wipe"
    vim.bo[capture_buf].swapfile = false
    local capture_chan = vim.api.nvim_open_term(capture_buf, {})
    local command_end = #self._lines
    self._active = {
        command_row = self._current_start,
        command_end_row = command_end,
        capture_buf = capture_buf,
        capture_chan = capture_chan,
        raw_bytes = "",
        cwd_before = self._cwd,
    }
    self._running = true
    self._lines[#self._lines + 1] = INPUT_PREFIX
    self._current_start = #self._lines
    self:_update_protected()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(
        buf,
        self._active.command_row - 1,
        -1,
        false,
        vim.list_slice(self._lines, self._active.command_row, #self._lines)
    )
    self:_render_marks()
    if self._win and vim.api.nvim_win_is_valid(self._win) then
        pcall(vim.api.nvim_win_set_cursor, self._win, { self._current_start, #INPUT_PREFIX })
    end
    self:_update_modifiable()
    local ok, err = self._session:run(command)
    if not ok then
        local active = self._active
        self._running = false
        self._active = nil
        if active then
            self:_close_capture(active)
        end
        self:_render_marks()
        return false, err
    end
    return true
end

function Worksheet:interrupt()
    self._session:interrupt()
end

function Worksheet:stop()
    self._completion_generation = self._completion_generation + 1
    if self._active then
        self:_close_capture(self._active)
    end
    self._session:stop()
    if self._undo_path then
        vim.fn.delete(self._undo_path)
        self._undo_path = nil
    end
end

---@param buf integer
---@return agent_workbench.ShellWorksheet?
function Worksheet.for_buffer(buf)
    return worksheets[buf]
end

---@return string
function Worksheet.foldtext()
    local worksheet = worksheets[vim.api.nvim_get_current_buf()]
    if not worksheet then
        return vim.fn.foldtext()
    end
    for _, block in ipairs(worksheet._blocks) do
        if block.output_start == vim.v.foldstart then
            local count = (block.output_end or block.output_start) - block.output_start + 1
            return ("π shell · exit %d · %dms · %d lines"):format(block.status or 1, block.duration_ms or 0, count)
        end
    end
    return vim.fn.foldtext()
end

return Worksheet
