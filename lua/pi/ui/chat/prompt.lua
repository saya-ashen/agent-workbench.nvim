--- Prompt buffer management.

---@class pi.ChatPrompt
---@field _buf integer
---@field _win integer?
---@field _layout pi.LayoutMode
---@field _statusline pi.StatusLine
---@field _attachments pi.ChatAttachments
---@field _cwd string
---@field _tab pi.TabId
---@field _zen boolean
---@field _command_mode pi.PromptCommandMode
---@field _on_command_mode_change fun(mode: pi.PromptCommandMode)?
---@field _on_mode_change fun(mode: pi.PromptMode, kind?: pi.PromptRequestKind)?
---@field _on_terminal_resize fun(win: integer, buf: integer)?
---@field _mode pi.PromptMode
---@field _display_mode pi.PromptDisplayMode
---@field _request_return_mode pi.PromptDisplayMode
---@field _request pi.PromptRequest?
---@field _compose_lines string[]?
---@field _compose_cursor integer[]?
---@field _compose_undolevels integer?
---@field _compose_undo_path string?
---@field _use_shell_blink boolean
---@field _request_timer integer?
---@field _resume_insert? "eol"|"bol"|"mid"
local Prompt = {}
Prompt.__index = Prompt

---@alias pi.PromptMode "compose"|"request"
---@alias pi.PromptDisplayMode "compose"|"terminal"|"request"
---@alias pi.PromptCommandMode "compose"|"bash"|"terminal"
---@alias pi.PromptRequestKind "select"|"confirm"

---@class pi.PromptRequest
---@field id string
---@field kind pi.PromptRequestKind
---@field title string
---@field message? string
---@field options string[]
---@field selected integer
---@field timeout? integer
---@field callback fun(value: string?, expired?: boolean)

local Ft = require("pi.filetypes")
local Config = require("pi.config")
local Keys = require("pi.keys")
local Decorators = require("pi.ui.chat.decorators")
local Draft = require("pi.draft")
local Notify = require("pi.notify")

local blink_auto_insert_wrapped = false
local blink_prompt_sources_wrapped = false
local Paste = require("pi.paste")
local StatusLine = require("pi.ui.chat.statusline")

local request_ns = vim.api.nvim_create_namespace("pi-prompt-request")

Prompt.HEIGHT = 8
Prompt.MAX_HEIGHT = 15

---@param name string
local function wipe_stale_buf(name)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 then
        vim.api.nvim_buf_delete(existing, { force = true })
    end
end

---@param win integer
---@return integer
local function window_text_rows(win)
    local info = vim.fn.getwininfo(win)
    if info and info[1] then
        return info[1].height
    end
    local height = vim.api.nvim_win_get_height(win)
    return math.max(height, 1)
end

---@param mode string?
---@return boolean
local function is_visual_mode(mode)
    local first = mode and mode:sub(1, 1) or ""
    return first == "v" or first == "V" or first == "\22"
end

---@param key integer
---@param attachments pi.ChatAttachments
---@param cwd? string
---@return pi.ChatPrompt
function Prompt.new(key, attachments, cwd)
    local self = setmetatable({}, Prompt)
    self._win = nil
    self._attachments = attachments
    self._cwd = cwd or vim.uv.cwd()
    self._tab = vim.api.nvim_get_current_tabpage()
    self._zen = false
    self._command_mode = "compose"
    self._on_command_mode_change = nil
    self._on_mode_change = nil
    self._on_terminal_resize = nil
    self._mode = "compose"
    self._display_mode = "compose"
    self._request_return_mode = "compose"
    self._request = nil
    self._compose_lines = nil
    self._compose_cursor = nil
    self._compose_undolevels = nil
    self._compose_undo_path = nil
    self._use_shell_blink = false
    self._request_timer = nil

    local panel = Config.options.panels.prompt
    local name = panel.name and panel.name(key) or ("π-prompt | " .. key)
    wipe_stale_buf(name)
    self._buf = vim.api.nvim_create_buf(false, true)
    vim.bo[self._buf].buftype = "nofile"
    vim.bo[self._buf].filetype = Ft.prompt
    vim.bo[self._buf].swapfile = false
    vim.bo[self._buf].bufhidden = "hide"
    vim.api.nvim_buf_set_name(self._buf, name)
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = self._buf,
        once = true,
        callback = function()
            self:_discard_compose_undo()
        end,
    })
    -- Let the single global paste handler (pi.paste) route dropped image file
    -- paths to this prompt's attachments. It only acts inside a π prompt buffer.
    Paste.register(self._buf, self._attachments)

    -- Unsent-draft persistence: restore a stale draft for this workspace and
    -- keep saving this process's current text (debounced) thereafter.
    local draft_cfg = Config.options.prompt and Config.options.prompt.draft
    if draft_cfg and draft_cfg.enabled ~= false then
        local draft = Draft.restore_once(self._cwd)
        if draft and draft ~= "" then
            vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, vim.split(draft, "\n", { plain = true }))
        end

        local save_timer = assert(vim.uv.new_timer())
        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
            buffer = self._buf,
            callback = function()
                if self._mode ~= "compose" or self._display_mode ~= "compose" then
                    return
                end
                save_timer:stop()
                save_timer:start(
                    300,
                    0,
                    vim.schedule_wrap(function()
                        self:_save_draft()
                    end)
                )
            end,
        })
        vim.api.nvim_create_autocmd("BufWipeout", {
            buffer = self._buf,
            once = true,
            callback = function()
                save_timer:stop()
                save_timer:close()
            end,
        })
    end

    vim.bo[self._buf].completefunc = "v:lua.require'pi.completion.omnifunc'.completefunc"
    vim.bo[self._buf].omnifunc = "v:lua.require'pi.completion.omnifunc'.completefunc"
    vim.api.nvim_set_option_value("completeopt", "menuone,noselect", { buf = self._buf })
    vim.b[self._buf].pi_prompt_completion = true
    local blink_ok, blink = pcall(require, "blink.cmp")
    local use_blink = blink_ok and type(blink.add_source_provider) == "function" and type(blink.show) == "function"
    if use_blink then
        local config_ok, blink_config = pcall(require, "blink.cmp.config")
        local selection = config_ok
            and blink_config.completion
            and blink_config.completion.list
            and blink_config.completion.list.selection
        if selection and not blink_auto_insert_wrapped then
            local original = selection.auto_insert
            selection.auto_insert = function(context)
                if vim.b[0].pi_prompt_completion then
                    return false
                end
                return type(original) == "function" and original(context) or original
            end
            blink_auto_insert_wrapped = true
        end
        if config_ok and blink_config.sources then
            local source_id = "pi_shell_fish"
            local providers = blink_config.sources.providers
            local provider = providers and providers[source_id] or nil
            if not provider then
                pcall(blink.add_source_provider, source_id, {
                    name = "Fish",
                    module = "pi.completion.shell",
                    async = true,
                    timeout_ms = 500,
                    max_items = 256,
                    min_keyword_length = 0,
                })
                provider = providers and providers[source_id] or nil
            end
            self._use_shell_blink = provider ~= nil and provider.module == "pi.completion.shell"
            if self._use_shell_blink and not blink_prompt_sources_wrapped then
                local original = blink_config.sources.per_filetype[Ft.prompt]
                blink_config.sources.per_filetype[Ft.prompt] = function()
                    if vim.b[0].pi_shell_worksheet then
                        return { source_id }
                    end
                    local configured = type(original) == "function" and original() or original
                    local result = {}
                    if configured then
                        vim.list_extend(result, configured)
                        result.inherit_defaults = configured.inherit_defaults
                    else
                        result.inherit_defaults = true
                    end
                    if not vim.tbl_contains(result, "omni") then
                        result[#result + 1] = "omni"
                    end
                    return result
                end
                blink_prompt_sources_wrapped = true
            end
        end
        vim.b[self._buf].pi_shell_blink_completion = false
        if type(blink.resubscribe) == "function" then
            blink.resubscribe()
        end
    end
    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = self._buf,
        callback = function()
            if self._mode ~= "compose" or self._display_mode ~= "compose" then
                return
            end
            if vim.api.nvim_get_current_buf() ~= self._buf or vim.fn.pumvisible() == 1 then
                return
            end
            local line = vim.api.nvim_get_current_line()
            local cursor = vim.fn.col(".") - 1
            local completefunc = require("pi.completion.omnifunc").completefunc
            local start = completefunc(1, "")
            if start < 0 then
                return
            end
            local base = line:sub(start + 1, cursor)
            local items = completefunc(0, base)
            if #items == 0 then
                return
            end
            if use_blink then
                vim.schedule(function()
                    if vim.api.nvim_get_current_buf() == self._buf and vim.fn.pumvisible() == 0 then
                        blink.show({ providers = { "omni" } })
                    end
                end)
            else
                vim.fn.complete(start + 1, items)
            end
        end,
    })
    Decorators.attach(self._buf)

    Keys.bind_wrapped_line_navigation(self._buf)

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = self._buf,
        callback = function()
            vim.cmd("stopinsert")
        end,
    })

    self._statusline = StatusLine.new(self._buf, self._tab, function()
        return self:win()
    end)

    -- Auto-resize prompt window to fit content while editing.
    -- Order matters: resize first (uses content height minus status padding),
    -- then render status line (uses resulting window height for padding).
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = self._buf,
        callback = function()
            if self._display_mode ~= "compose" then
                return
            end
            self:resize()
            self:_render_statusline()
            if self._mode == "compose" then
                self:_refresh_command_mode()
            end
        end,
    })

    -- Visual-mode delete-all (e.g. ggVGx) can leave the statusline extmark
    -- visually stale until after the mode switch completes. Re-render once
    -- when leaving Visual mode instead of syncing on every line change.
    vim.api.nvim_create_autocmd("ModeChanged", {
        buffer = self._buf,
        callback = function()
            local ev = vim.v.event or {}
            if not is_visual_mode(ev.old_mode) or is_visual_mode(ev.new_mode) then
                return
            end
            vim.schedule(function()
                if self._display_mode == "compose" then
                    self:resize()
                    self:_render_statusline()
                end
            end)
        end,
    })

    -- Re-render status line padding when the window is resized externally
    -- (e.g. <C-w>+, split drag). Without this, padding stays stale until
    -- the next text change.
    vim.api.nvim_create_autocmd("WinResized", {
        callback = function()
            if self._win and vim.api.nvim_win_is_valid(self._win) then
                for _, win in ipairs(vim.v.event.windows) do
                    if win == self._win then
                        if self._display_mode == "terminal" and self._on_terminal_resize then
                            self._on_terminal_resize(self._win, self._buf)
                        else
                            self:_render_statusline()
                        end
                        return
                    end
                end
            end
        end,
    })

    return self
end

---@param tab pi.TabId
function Prompt:set_tab(tab)
    self._tab = tab
    self._statusline:set_tab(tab)
end

---@return integer
function Prompt:buf()
    return self._buf
end

---@return pi.StatusLine
function Prompt:statusline()
    return self._statusline
end

---@param cb fun(state: pi.StatusLineState)?
function Prompt:set_on_status_change(cb)
    self._statusline:set_on_change(cb)
end

---@param cb fun(mode: pi.PromptCommandMode)
function Prompt:set_on_command_mode_change(cb)
    self._on_command_mode_change = cb
    local previous = self._command_mode
    self._command_mode = self:_compute_command_mode()
    if self._command_mode ~= previous or self._command_mode ~= "compose" then
        cb(self._command_mode)
    end
end

---@param cb fun(mode: pi.PromptMode, kind?: pi.PromptRequestKind)
function Prompt:set_on_mode_change(cb)
    self._on_mode_change = cb
end

---@param cb fun(win: integer, buf: integer)
function Prompt:set_on_terminal_resize(cb)
    self._on_terminal_resize = cb
end

---@return pi.PromptMode
function Prompt:mode()
    return self._mode
end

---@return pi.PromptDisplayMode
function Prompt:display_mode()
    return self._display_mode
end

---@return boolean
function Prompt:is_terminal_display()
    return self._display_mode == "terminal"
end

---@return boolean
function Prompt:is_request_mode()
    return self._mode == "request" and self._request ~= nil
end

---@return pi.PromptCommandMode
function Prompt:command_mode()
    return self._command_mode
end

--- Resolve compose, backend bash, or local terminal mode from prompt prefix.
--- Leading whitespace stays compatible with existing direct-bash behavior.
---@return pi.PromptCommandMode
function Prompt:_compute_command_mode()
    if self._display_mode == "terminal" then
        return "terminal"
    end
    if self._mode ~= "compose" or not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return "compose"
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(self._buf, 0, -1, false), "\n")
    local trimmed = text:match("^%s*(.*)$") or text
    if trimmed:sub(1, 2) == "!!" then
        return "terminal"
    end
    if trimmed:sub(1, 1) == "!" then
        return "bash"
    end
    return "compose"
end

--- Recompute command mode after user or programmatic edits.
function Prompt:_refresh_command_mode()
    local mode = self:_compute_command_mode()
    if mode == self._command_mode then
        return
    end
    self._command_mode = mode
    if self._on_command_mode_change then
        self._on_command_mode_change(mode)
    end
end

--- Re-render the prompt statusline and reset wrapped scrolling when the
--- whole prompt fits again. Neovim can leave stale skipcol/topline state
--- after a wrapped line splits before the statusline extmark is moved.
function Prompt:_render_statusline()
    self._statusline:render()
    if self._display_mode == "compose" then
        self:_reset_view_if_content_fits()
    end
end

function Prompt:_reset_view_if_content_fits()
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    if vim.api.nvim_win_text_height(self._win, {}).all > window_text_rows(self._win) then
        return
    end
    vim.api.nvim_win_call(self._win, function()
        vim.fn.winrestview({ topline = 1, skipcol = 0 })
    end)
end

---@param win integer?
function Prompt:set_win(win)
    self._win = win
    self:_render_statusline()
end

---@param mode pi.LayoutMode
function Prompt:set_layout(mode)
    self._layout = mode
    self:_render_statusline()
end

---@param zen boolean
function Prompt:set_zen(zen)
    self._zen = zen
end

function Prompt:resize()
    if self._zen then
        return
    end
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    local target_height
    if self._display_mode == "terminal" then
        target_height = Prompt.MAX_HEIGHT
    else
        local visual_lines = vim.api.nvim_win_text_height(self._win, {}).all
        local status_rows = self._statusline:virt_line_count() > 0 and 1 or 0
        -- Remove virtual padding, but keep one row when the optional statusline is visible.
        local content_lines = visual_lines - self._statusline:virt_line_count() + status_rows
        target_height = math.max(Prompt.HEIGHT, math.min(content_lines, Prompt.MAX_HEIGHT))
    end
    local current_height = vim.api.nvim_win_get_height(self._win)
    if target_height ~= current_height then
        if self._layout == "float" then
            vim.api.nvim_win_set_config(self._win, { height = target_height })
        else
            vim.api.nvim_win_set_height(self._win, target_height)
        end
    end
end

---@return integer?
function Prompt:win()
    if self._win and vim.api.nvim_win_is_valid(self._win) then
        return self._win
    end
    return nil
end

---@alias pi.PromptFocusMode "normal"|"insert"

---@param cb? fun()
---@param mode? pi.PromptFocusMode
function Prompt:focus(cb, mode)
    local win = self._win
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    vim.api.nvim_set_current_win(win)
    vim.schedule(function()
        if
            self._win ~= win
            or not vim.api.nvim_win_is_valid(win)
            or vim.api.nvim_get_current_win() ~= win
            or vim.api.nvim_win_get_buf(win) ~= self._buf
        then
            return
        end
        if self:is_request_mode() then
            vim.cmd("stopinsert")
        elseif self:is_terminal_display() then
            -- Shell worksheet owns normal Vim modes; fish never owns input keys.
            vim.cmd("stopinsert")
        elseif mode == nil or mode == "normal" then
            vim.cmd("stopinsert")
        elseif mode == "insert" then
            vim.cmd("startinsert")
        end
        if cb then
            cb()
        end
    end)
end

---@return string
function Prompt:text()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return ""
    end
    local lines = self._display_mode == "compose" and vim.api.nvim_buf_get_lines(self._buf, 0, -1, false)
        or self._compose_lines
    return vim.fn.trim(table.concat(lines or {}, "\n"))
end

---@param lines string[]
function Prompt:_set_lines(lines)
    vim.bo[self._buf].modifiable = true
    vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, #lines > 0 and lines or { "" })
end

function Prompt:_discard_compose_undo()
    if self._compose_undo_path then
        vim.fn.delete(self._compose_undo_path)
        self._compose_undo_path = nil
    end
end

---@param preserve boolean
function Prompt:_suspend_compose_undo(preserve)
    self._compose_undolevels = vim.bo[self._buf].undolevels
    if preserve then
        local path = vim.fn.tempname()
        local ok, err = pcall(vim.api.nvim_buf_call, self._buf, function()
            vim.cmd("silent wundo! " .. vim.fn.fnameescape(path))
        end)
        if ok and vim.fn.filereadable(path) == 1 then
            self._compose_undo_path = path
        else
            vim.fn.delete(path)
            if not ok then
                Notify.warn("Could not preserve prompt undo history: " .. tostring(err))
            end
        end
    end
    vim.bo[self._buf].undolevels = -1
end

function Prompt:_restore_compose_undo()
    if self._compose_undolevels ~= nil then
        vim.bo[self._buf].undolevels = self._compose_undolevels
        self._compose_undolevels = nil
    end
    local path = self._compose_undo_path
    self._compose_undo_path = nil
    if not path then
        return
    end
    local ok, err = pcall(vim.api.nvim_buf_call, self._buf, function()
        vim.cmd("silent rundo " .. vim.fn.fnameescape(path))
    end)
    vim.fn.delete(path)
    if not ok then
        Notify.warn("Could not restore prompt undo history: " .. tostring(err))
    end
end

---@param return_text? string
---@param preserve_compose? boolean
---@return boolean
function Prompt:enter_terminal(return_text, preserve_compose)
    if self._display_mode ~= "compose" or self:is_request_mode() then
        return false
    end
    if preserve_compose then
        self._compose_lines = vim.api.nvim_buf_get_lines(self._buf, 0, -1, false)
        local win = self:win()
        self._compose_cursor = win and vim.api.nvim_win_get_cursor(win) or nil
    else
        self._compose_lines = vim.split(return_text or "", "\n", { plain = true })
        self._compose_cursor = { math.max(1, #self._compose_lines), #(self._compose_lines[#self._compose_lines] or "") }
        local draft_cfg = Config.options.prompt and Config.options.prompt.draft
        if draft_cfg and draft_cfg.enabled ~= false then
            Draft.save("", self._cwd)
        end
    end
    self:_suspend_compose_undo(preserve_compose == true)
    self._display_mode = "terminal"
    vim.b[self._buf].pi_prompt_terminal = true
    vim.b[self._buf].pi_shell_blink_completion = self._use_shell_blink
    self._statusline:set_suspended(true)
    if vim.api.nvim_get_current_buf() == self._buf then
        local blink_ok, blink = pcall(require, "blink.cmp")
        if blink_ok and type(blink.hide) == "function" then
            blink.hide()
        end
        if vim.fn.pumvisible() == 1 then
            vim.api.nvim_feedkeys(vim.keycode("<C-e>"), "n", false)
        end
        if self._use_shell_blink and blink_ok and type(blink.resubscribe) == "function" then
            blink.resubscribe()
        end
    end
    self:_set_lines({ "" })
    -- Restore normal undo recording after clearing compose history from the
    -- worksheet. The compose tree itself stays in `_compose_undo_path`.
    vim.bo[self._buf].undolevels = self._compose_undolevels or vim.bo[self._buf].undolevels
    vim.bo[self._buf].modifiable = true
    Decorators.update(self._buf)
    self:resize()
    self:_refresh_command_mode()
    return true
end

---@return boolean
function Prompt:leave_terminal()
    if self._display_mode ~= "terminal" then
        return false
    end
    self._display_mode = "compose"
    vim.b[self._buf].pi_prompt_terminal = false
    vim.b[self._buf].pi_shell_blink_completion = false
    local blink_ok, blink = pcall(require, "blink.cmp")
    if blink_ok and type(blink.hide) == "function" then
        blink.hide()
    end
    if blink_ok and type(blink.resubscribe) == "function" then
        blink.resubscribe()
    end
    vim.bo[self._buf].undolevels = -1
    self:_set_lines(self._compose_lines or { "" })
    self._compose_lines = nil
    self:_restore_compose_undo()
    vim.bo[self._buf].modifiable = true
    self._statusline:set_suspended(false)
    Decorators.update(self._buf)
    local win = self:win()
    if win and self._compose_cursor then
        pcall(vim.api.nvim_win_set_cursor, win, self._compose_cursor)
    end
    self._compose_cursor = nil
    self:resize()
    self:_render_statusline()
    self:_refresh_command_mode()
    return true
end

---@return boolean
function Prompt:terminal_stopped()
    if self._display_mode == "terminal" then
        return self:leave_terminal()
    end
    if self._display_mode == "request" and self._request_return_mode == "terminal" then
        self._request_return_mode = "compose"
        return true
    end
    return false
end

function Prompt:_render_request()
    local request = self._request
    if not request then
        return
    end
    local lines = vim.split(request.title, "\n", { plain = true })
    if request.message and request.message ~= "" and request.message ~= request.title then
        vim.list_extend(lines, vim.split(request.message, "\n", { plain = true }))
    end
    lines[#lines + 1] = ""
    local option_start = #lines
    for index, option in ipairs(request.options) do
        lines[#lines + 1] = (index == request.selected and "  › " or "    ") .. option
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "j/k or ↑/↓ move   <CR> confirm   <C-c> cancel"
    self:_set_lines(lines)
    vim.bo[self._buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(self._buf, request_ns, 0, -1)
    local selected_row = option_start + request.selected - 1
    vim.api.nvim_buf_set_extmark(self._buf, request_ns, 0, 0, {
        end_col = #(lines[1] or ""),
        hl_group = "PiPromptRequestTitle",
    })
    vim.api.nvim_buf_set_extmark(self._buf, request_ns, selected_row, 2, {
        end_col = #(lines[selected_row + 1] or ""),
        hl_group = "PiPromptRequestSelected",
    })
    vim.api.nvim_buf_set_extmark(self._buf, request_ns, #lines - 1, 0, {
        end_col = #(lines[#lines] or ""),
        hl_group = "Comment",
    })
    local win = self:win()
    if win then
        pcall(vim.api.nvim_win_set_cursor, win, { selected_row + 1, 0 })
    end
    self:resize()
    self:_render_statusline()
end

---@param request pi.PromptRequest
---@return boolean
function Prompt:set_request(request)
    if self:is_request_mode() or #request.options == 0 then
        return false
    end
    self._request_return_mode = self._display_mode
    if self._display_mode == "compose" then
        self._compose_lines = vim.api.nvim_buf_get_lines(self._buf, 0, -1, false)
        local win = self:win()
        self._compose_cursor = win and vim.api.nvim_win_get_cursor(win) or nil
    end
    self._display_mode = "request"
    vim.b[self._buf].pi_prompt_terminal = false
    self._statusline:set_suspended(false)
    self._request = request
    self._request.selected = math.max(1, math.min(request.selected or 1, #request.options))
    self._mode = "request"
    self:_refresh_command_mode()
    vim.cmd("stopinsert")
    self:_render_request()
    if request.timeout and request.timeout > 0 then
        self._request_timer = vim.fn.timer_start(request.timeout, function()
            vim.schedule(function()
                self:_finish_request(nil, true)
            end)
        end)
    end
    if self._on_mode_change then
        self._on_mode_change("request", request.kind)
    end
    return true
end

---@param delta integer
function Prompt:move_request_selection(delta)
    local request = self._request
    if not request then
        return
    end
    request.selected = math.max(1, math.min(#request.options, request.selected + delta))
    self:_render_request()
end

function Prompt:confirm_request()
    local request = self._request
    if request then
        self:_finish_request(request.options[request.selected], false)
    end
end

function Prompt:cancel_request()
    if self._request then
        self:_finish_request(nil, false)
    end
end

---@param value string?
---@param expired boolean
function Prompt:_finish_request(value, expired)
    local request = self._request
    if not request then
        return
    end
    if self._request_timer then
        pcall(vim.fn.timer_stop, self._request_timer)
        pcall(vim.fn.timer_close, self._request_timer)
        self._request_timer = nil
    end
    self._request = nil
    self._mode = "compose"
    vim.api.nvim_buf_clear_namespace(self._buf, request_ns, 0, -1)
    local return_mode = self._request_return_mode
    self._request_return_mode = "compose"
    self._display_mode = return_mode
    if return_mode == "terminal" then
        vim.b[self._buf].pi_prompt_terminal = true
        self:_set_lines({ "" })
        self._statusline:set_suspended(true)
    else
        vim.b[self._buf].pi_prompt_terminal = false
        self:_set_lines(self._compose_lines or { "" })
        self._statusline:set_suspended(false)
        self._compose_lines = nil
        self:_restore_compose_undo()
        local win = self:win()
        if win and self._compose_cursor then
            local line_count = vim.api.nvim_buf_line_count(self._buf)
            self._compose_cursor[1] = math.min(self._compose_cursor[1], line_count)
            pcall(vim.api.nvim_win_set_cursor, win, self._compose_cursor)
        end
        self._compose_cursor = nil
    end
    vim.bo[self._buf].modifiable = true
    Decorators.update(self._buf)
    self:resize()
    self:_render_statusline()
    self:_refresh_command_mode()
    if self._on_mode_change then
        self._on_mode_change("compose")
    end
    request.callback(value, expired)
end

function Prompt:clear_request()
    if not self._request then
        return
    end
    self._request.callback = function() end
    self:_finish_request(nil, true)
end

---@param text string
function Prompt:set_text(text)
    if self._display_mode ~= "compose" then
        self._compose_lines = vim.split(text, "\n", { plain = true })
        self:_discard_compose_undo()
        return
    end
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return
    end
    local lines = vim.split(text, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, #lines > 0 and lines or { "" })
    local win = self:win()
    if win then
        local row = math.max(#lines, 1)
        pcall(vim.api.nvim_win_set_cursor, win, { row, #(lines[row] or "") })
    end
    self:resize()
    self:_render_statusline()
    self:_refresh_command_mode()
end

function Prompt:clear_text()
    self:set_text("")
end

--- Persist the current prompt text as the unsent draft (empty text clears it).
--- Called (debounced) on text changes; exposed as a method so the save logic is
--- testable independent of the TextChanged event.
function Prompt:_save_draft()
    if
        self._mode ~= "compose"
        or self._display_mode ~= "compose"
        or not self._buf
        or not vim.api.nvim_buf_is_valid(self._buf)
    then
        return
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(self._buf, 0, -1, false), "\n")
    Draft.save(vim.trim(text) == "" and "" or text, self._cwd)
end

---@return integer
function Prompt:content_height()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return Prompt.HEIGHT
    end
    if self._display_mode == "terminal" then
        return Prompt.MAX_HEIGHT
    end
    local status_rows = self._statusline:virt_line_count() > 0 and 1 or 0
    local line_count = vim.api.nvim_buf_line_count(self._buf) + status_rows
    return math.max(Prompt.HEIGHT, math.min(line_count, Prompt.MAX_HEIGHT))
end

return Prompt
