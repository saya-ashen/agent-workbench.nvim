--- Chat layout — window creation, positioning, and management.

---@class pi.ChatLayout
---@field _mode pi.LayoutMode
---@field _history_win integer?
---@field _prompt_win integer?
---@field _attachments_win integer?
---@field _return_win integer?
---@field _return_buf integer?
---@field _return_opts table<string, any>?
---@field _history pi.ChatHistory
---@field _prompt pi.ChatPrompt
---@field _attachments pi.ChatAttachments
---@field _has_attention boolean
---@field _command_mode pi.PromptCommandMode
---@field _content_buf integer?
---@field _content_title string?
---@field _prompt_mode pi.PromptMode
---@field _prompt_request_kind pi.PromptRequestKind?
---@field _prompt_state pi.StatusLineState?
local Layout = {}
Layout.__index = Layout

local Config = require("pi.config")
local Prompt = require("pi.ui.chat.prompt")
local Highlights = require("pi.ui.highlights")
local Render = require("pi.ui.render")

--- Low z-index so other floats naturally sit on top.
local FLOAT_ZINDEX = 10

-- Capture editor options to inherit in π windows.
local editor_foldcolumn = vim.wo.foldcolumn

local BUFFER_WINDOW_OPTIONS = {
    "wrap",
    "linebreak",
    "signcolumn",
    "foldcolumn",
    "foldenable",
    "foldmethod",
    "foldexpr",
    "foldtext",
    "foldlevel",
    "list",
    "conceallevel",
    "concealcursor",
    "winfixbuf",
    "number",
    "relativenumber",
    "cursorline",
    "winbar",
    "winhighlight",
}

--- Some dashboard plugins wipe their scratch buffer while it is being
--- replaced. A stale cleanup augroup can raise E367 and abort the switch even
--- though the target window and buffer remain usable.
---@param win integer
---@param buf integer
local function set_win_buf(win, buf)
    local ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)
    if ok then
        return
    end
    local message = tostring(err)
    if not message:find("E367", 1, true) or not message:find("No such group", 1, true) then
        error(err)
    end
    vim.api.nvim_win_call(win, function()
        vim.cmd("noautocmd buffer " .. buf)
    end)
end

---@param win integer
---@return table<string, any>
local function capture_win_opts(win)
    local opts = {}
    for _, name in ipairs(BUFFER_WINDOW_OPTIONS) do
        opts[name] = vim.wo[win][name]
    end
    return opts
end

---@param win integer
---@param opts table<string, any>
local function restore_win_opts(win, opts)
    for name, value in pairs(opts) do
        vim.wo[win][name] = value
    end
end

---@param win integer
local function set_terminal_win_opts(win)
    vim.wo[win].wrap = false
    vim.wo[win].linebreak = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].foldenable = false
    vim.wo[win].list = false
    vim.wo[win].conceallevel = 0
    vim.wo[win].winfixbuf = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].cursorline = false
end

local function set_win_opts(win, extra)
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = editor_foldcolumn
    vim.wo[win].foldenable = false
    vim.wo[win].list = false
    vim.wo[win].conceallevel = 2
    vim.wo[win].winfixbuf = false
    -- These options form the fingerprint used by pi.ui.winfix to detect
    -- windows inherited from pi. Keep in sync with has_pi_fingerprint().
    vim.wo[win].concealcursor = "nvic"
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].cursorline = false
    if extra then
        extra(win)
    end
end

---@param win integer
---@param title string
---@param hl_group string
---@param title_hl_group? string
local function set_winbar(win, title, hl_group, title_hl_group)
    title_hl_group = title_hl_group or (hl_group .. "Title")
    vim.wo[win].winbar = "%#" .. hl_group .. "#%=%#" .. title_hl_group .. "# " .. title .. " %#" .. hl_group .. "#%="
end

---@param win integer
local function clear_winbar(win)
    vim.wo[win].winbar = ""
end

---@param value any
---@return string
local function winbar_text(value)
    return (tostring(value or ""):gsub("%%", "%%%%"))
end

---@param count number
---@return string
local function format_tokens(count)
    if count < 1000 then
        return tostring(count)
    elseif count < 1000000 then
        return (("%.1fk"):format(count / 1000):gsub("%.0k$", "k"))
    end
    return (("%.1fM"):format(count / 1000000):gsub("%.0M$", "M"))
end

---@param state pi.StatusLineState
---@return string
local function context_text(state)
    local total = state.model_context_window
    if not total or total <= 0 then
        return "ctx: ?"
    end
    if not state.context_tokens then
        return "ctx: -/" .. format_tokens(total)
    end
    local percent = math.floor((state.context_tokens / total) * 100 + 0.5)
    return ("ctx: %s/%s (%d%%)"):format(format_tokens(state.context_tokens), format_tokens(total), percent)
end

--- Update prompt title styling to reflect pending attention.
---@param has_attention boolean
function Layout:refresh_prompt_attention(has_attention)
    self._has_attention = has_attention
    self:_refresh_prompt_chrome()
end

--- Update prompt styling for compose, backend bash, or shell worksheet mode.
---@param mode pi.PromptCommandMode
function Layout:set_command_mode(mode)
    if self._command_mode == mode then
        return
    end
    self._command_mode = mode
    self:_refresh_prompt_chrome()
end

---@return pi.PromptCommandMode
function Layout:command_mode()
    return self._command_mode
end

--- Re-apply prompt title and colors. Command mode wins over attention styling.
function Layout:_refresh_prompt_chrome()
    local pwin = self:prompt_win()
    if not pwin then
        return
    end

    local prompt_cfg = Config.options.panels.prompt
    local request_title = self._prompt_request_kind == "confirm" and "confirm" or "choose"
    local command_title = self._command_mode == "terminal" and "shell" or (prompt_cfg.bash_title or "bash")
    local title = self._prompt_mode == "request" and request_title
        or (self._command_mode ~= "compose" and command_title)
        or prompt_cfg.title

    if self._mode == "float" then
        local winhighlight = Highlights.CHAT_PROMPT_WINHIGHLIGHT
        if self._prompt_mode == "request" then
            winhighlight = Highlights.CHAT_PROMPT_ATTENTION_WINHIGHLIGHT
        elseif self._command_mode ~= "compose" then
            winhighlight = Highlights.CHAT_PROMPT_BASH_WINHIGHLIGHT
        elseif self._has_attention then
            winhighlight = Highlights.CHAT_PROMPT_ATTENTION_WINHIGHLIGHT
        end
        vim.wo[pwin].winhighlight = winhighlight
        pcall(vim.api.nvim_win_set_config, pwin, { title = " " .. title .. " ", title_pos = "center" })
        return
    end

    if self._mode == "side" and not Config.resolve_side_layout().panels.prompt.winbar then
        clear_winbar(pwin)
        return
    end

    local state = self._prompt_state or self._prompt:statusline():state()
    local title_hl = "PiChatPromptWinbarTitle"
    if self._prompt_mode == "request" then
        title_hl = "PiChatPromptWinbarAttentionTitle"
    elseif self._command_mode ~= "compose" then
        title_hl = "PiChatPromptWinbarBashTitle"
    elseif self._has_attention then
        title_hl = "PiChatPromptWinbarAttentionTitle"
    end

    local width = vim.api.nvim_win_get_width(pwin)
    local title_text = title
    local running = state.busy ~= nil
    local state_hl = running and "PiSessionsListBusy" or "PiSessionsListDone"
    local state_icon = running and "󰔟" or "󰄬"
    local model = state.model_id or "no model"
    local thinking = state.thinking_level or "off"
    local details
    local cwd
    if width >= 100 then
        details = ("model: %s  think: %s  %s"):format(model, thinking, context_text(state))
        cwd = " " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":~")
    elseif width >= 72 then
        details = ("model: %s  think: %s  %s"):format(model, thinking, context_text(state))
    elseif width >= 48 then
        details = ("model: %s  %s"):format(model, context_text(state))
    else
        details = "model: " .. model
    end

    local winbar = ("%%#PiChatPromptWinbar# %%#%s#󰍩 %s  %%#%s#%s %s  %%#PiStatusLine#%%<%s"):format(
        title_hl,
        winbar_text(title_text):upper(),
        state_hl,
        state_icon,
        running and "running" or "idle",
        winbar_text(details)
    )
    if cwd then
        winbar = winbar .. "%=" .. winbar_text(cwd) .. " "
    end
    if vim.wo[pwin].winbar ~= winbar then
        vim.wo[pwin].winbar = winbar
    end
end

---@param mode pi.LayoutMode
---@param history pi.ChatHistory
---@param prompt pi.ChatPrompt
---@param attachments pi.ChatAttachments
---@return pi.ChatLayout
function Layout.new(mode, history, prompt, attachments)
    local self = setmetatable({}, Layout)
    self._mode = mode
    self._history_win = nil
    self._prompt_win = nil
    self._attachments_win = nil
    self._return_win = nil
    self._return_buf = nil
    self._return_opts = nil
    self._history = history
    self._prompt = prompt
    self._attachments = attachments
    self._has_attention = false
    self._command_mode = "compose"
    self._content_buf = nil
    self._content_title = nil
    self._prompt_mode = "compose"
    self._prompt_request_kind = nil
    self._prompt_state = prompt:statusline():state()

    prompt:set_on_status_change(function(state)
        self._prompt_state = state
        self:_refresh_prompt_chrome()
    end)
    prompt:set_on_mode_change(function(prompt_mode, kind)
        self._prompt_mode = prompt_mode
        self._prompt_request_kind = kind
        self:_refresh_prompt_chrome()
    end)

    attachments:set_on_change(function()
        self:_refresh_attachments()
    end)

    return self
end

---@param history pi.ChatHistory
function Layout:set_history(history)
    self._history = history
end

---@param win integer
---@param number? boolean
---@param relativenumber? boolean
function Layout:_configure_content_window(win, number, relativenumber)
    if self._content_buf then
        set_terminal_win_opts(win)
        if self._mode == "side" and Config.resolve_side_layout().panels.history.winbar then
            set_winbar(win, self._content_title or "local terminal", "PiChatHistoryWinbar")
        elseif self._mode == "float" then
            vim.wo[win].winhighlight = Highlights.CHAT_HISTORY_WINHIGHLIGHT
            pcall(vim.api.nvim_win_set_config, win, {
                title = " " .. (self._content_title or "local terminal") .. " ",
                title_pos = "center",
            })
        else
            clear_winbar(win)
        end
        return
    end
    set_win_opts(win, function(target)
        if self._mode == "buffer" then
            vim.wo[target].number = number == true
            vim.wo[target].relativenumber = relativenumber == true
            vim.wo[target].foldenable = true
            vim.wo[target].foldmethod = "expr"
            vim.wo[target].foldexpr = "v:lua.require'pi.ui.chat.history'.nvim_foldexpr(v:lnum)"
            vim.wo[target].foldtext = "v:lua.require'pi.ui.chat.history'.nvim_foldtext()"
            vim.wo[target].foldlevel = 0
            vim.wo[target].foldcolumn = "1"
        elseif self._mode == "side" then
            vim.wo[target].winfixwidth = true
        end
        if Render.engine() == "builtin" then
            vim.wo[target].conceallevel = 0
        end
    end)
    if self._mode == "side" and Config.resolve_side_layout().panels.history.winbar then
        set_winbar(win, Config.options.panels.history.title, "PiChatHistoryWinbar")
    elseif self._mode == "float" then
        vim.wo[win].winbar = ""
        vim.wo[win].winhighlight = Highlights.CHAT_HISTORY_WINHIGHLIGHT
        pcall(vim.api.nvim_win_set_config, win, {
            title = " " .. Config.options.panels.history.title .. " ",
            title_pos = "center",
        })
    elseif self._mode == "buffer" then
        clear_winbar(win)
    end
end

--- Replace chat History with another content buffer, or restore History with nil.
---@param buf integer?
---@param title? string
function Layout:set_content_buffer(buf, title)
    self._content_buf = buf
    self._content_title = title
    local win = self:history_win()
    if not win then
        return
    end
    if vim.api.nvim_win_get_buf(win) == (buf or self._history:buf()) then
        self:_configure_content_window(win)
        return
    end
    self._history:set_win(nil)
    set_win_buf(win, buf or self._history:buf())
    self:_configure_content_window(win)
    if not buf then
        self._history:set_win(win)
    end
end

---@return integer
function Layout:content_buf()
    return self._content_buf or self._history:buf()
end

---@param active boolean
function Layout:set_prompt_terminal(active)
    local win = self:prompt_win()
    if not win then
        return
    end
    if active then
        set_terminal_win_opts(win)
        vim.wo[win].virtualedit = "onemore"
    else
        set_win_opts(win, function(target)
            vim.wo[target].winfixheight = true
            vim.wo[target].virtualedit = "onemore"
            if self._mode == "side" then
                vim.wo[target].winfixwidth = true
            end
        end)
    end
    self:_refresh_prompt_chrome()
end

---@param after_win integer
function Layout:_open_attachments_in_side_layout(after_win)
    local prev_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(after_win)
    vim.cmd("belowright " .. self._attachments:count() .. "split")
    self._attachments_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self._attachments_win, self._attachments:buf())
    vim.wo[self._attachments_win].winfixheight = true
    vim.wo[self._attachments_win].winfixwidth = true
    vim.wo[self._attachments_win].signcolumn = "no"
    vim.wo[self._attachments_win].foldcolumn = editor_foldcolumn
    vim.wo[self._attachments_win].winfixbuf = false
    vim.wo[self._attachments_win].wrap = false
    -- Fingerprint options — see pi.ui.winfix
    vim.wo[self._attachments_win].concealcursor = "nvic"
    vim.wo[self._attachments_win].number = false
    vim.wo[self._attachments_win].relativenumber = false
    vim.wo[self._attachments_win].cursorline = false

    vim.api.nvim_set_current_win(prev_win)
end

---@param col integer
---@param row integer
---@param width integer
---@param border string|string[]
function Layout:_open_attachments_in_float_layout(col, row, width, border)
    -- Available height: screen lines minus cmdline, statusline (1), rows above (row), border (2)
    local max_height = vim.o.lines - vim.o.cmdheight - 1 - row - 2
    if max_height < 1 then
        return
    end
    local height = math.min(self._attachments:count(), max_height)
    self._attachments_win = vim.api.nvim_open_win(self._attachments:buf(), false, {
        relative = "editor",
        width = width,
        height = height,
        col = col,
        row = row,
        style = "minimal",
        border = border,
        zindex = FLOAT_ZINDEX,
        title = " " .. Config.options.panels.attachments.title .. " ",
        title_pos = "center",
    })
    vim.wo[self._attachments_win].winfixheight = true
    vim.wo[self._attachments_win].signcolumn = "yes"
    vim.wo[self._attachments_win].winfixbuf = false
    vim.wo[self._attachments_win].wrap = false
    vim.wo[self._attachments_win].winhighlight = Highlights.CHAT_ATTACHMENTS_WINHIGHLIGHT
    -- Fingerprint options — see pi.ui.winfix
    vim.wo[self._attachments_win].concealcursor = "nvic"
    vim.wo[self._attachments_win].number = false
    vim.wo[self._attachments_win].relativenumber = false
    vim.wo[self._attachments_win].cursorline = false
end

function Layout:_close_history_win()
    local hwin = self:history_win()
    self._history:set_win(nil)
    if hwin then
        vim.api.nvim_win_close(hwin, false)
    end
    self._history_win = nil
end

function Layout:_close_prompt_win()
    local pwin = self:prompt_win()
    if pwin then
        vim.api.nvim_win_close(pwin, false)
    end
    self._prompt_win = nil
    self._prompt:set_win(nil)
end

function Layout:_close_attachments_win()
    local awin = self:attachments_win()
    if not awin then
        self._attachments_win = nil
        return
    end
    -- Move focus away before closing: try previous window, fall back to next
    -- if the previous window is the one we're closing (only window in column).
    if vim.api.nvim_get_current_win() == awin then
        vim.cmd("wincmd p")
        if vim.api.nvim_get_current_win() == awin then
            vim.cmd("wincmd w")
        end
    end
    vim.api.nvim_win_close(awin, false)
    self._attachments_win = nil
end

--- Reposition (and optionally resize) the float window stack.
--- When target_width / target_height are given, windows are resized to match
--- the new dimensions (used on VimResized). Without them, the current window
--- sizes are preserved and only positions are recalculated (used when the
--- attachment count changes).
---@param target_width? integer
---@param target_height? integer
---@param float_cfg? pi.FloatLayout Pre-resolved config; resolved internally if omitted.
function Layout:_reposition_float_stack(target_width, target_height, float_cfg)
    if not self._history_win or not vim.api.nvim_win_is_valid(self._history_win) then
        return
    end
    if not self._prompt_win or not vim.api.nvim_win_is_valid(self._prompt_win) then
        return
    end

    float_cfg = float_cfg or Config.resolve_float_layout()
    local ui_width = vim.o.columns
    local ui_height = vim.o.lines - vim.o.cmdheight - 1
    local border = float_cfg.border or "rounded"

    local width = target_width or vim.api.nvim_win_get_width(self._history_win)
    local prompt_height = vim.api.nvim_win_get_height(self._prompt_win)
    local attach_count = self._attachments:count()

    local history_height
    if target_height then
        -- Derive history height from the target total height.
        history_height = target_height - prompt_height - 1
        if attach_count > 0 then
            history_height = history_height - attach_count - 2
        end
        history_height = math.max(3, history_height)
    else
        history_height = vim.api.nvim_win_get_height(self._history_win)
    end

    -- border takes 2 lines per window (top + bottom)
    local total = history_height + 2 + prompt_height + 2
    if attach_count > 0 then
        total = total + attach_count + 2
    end

    -- Shrink history if stack doesn't fit
    local overhead = total - history_height
    if total > ui_height then
        history_height = math.max(3, ui_height - overhead)
        total = history_height + overhead
    end

    -- If it still doesn't fit, skip attachments
    if total > ui_height and attach_count > 0 then
        total = total - attach_count - 2
        attach_count = 0
        self:_close_attachments_win()
    end

    local col = math.floor((ui_width - width) / 2)
    local row = math.max(0, math.floor((ui_height - total) / 2))

    vim.api.nvim_win_set_config(self._history_win, {
        relative = "editor",
        row = row,
        col = col,
        height = history_height,
        width = width,
    })

    local prompt_row = row + history_height + 2
    vim.api.nvim_win_set_config(self._prompt_win, {
        relative = "editor",
        row = prompt_row,
        col = col,
        width = width,
    })

    if attach_count > 0 then
        local attach_row = prompt_row + prompt_height + 2
        local awin = self:attachments_win()
        if awin then
            vim.api.nvim_win_set_config(awin, {
                relative = "editor",
                row = attach_row,
                col = col,
                width = width,
                height = attach_count,
            })
        else
            self:_open_attachments_in_float_layout(col, attach_row, width, border)
        end
    end
end

function Layout:_refresh_attachments()
    if not self._prompt_win or not vim.api.nvim_win_is_valid(self._prompt_win) then
        return
    end
    local is_float = self._mode == "float"

    if self._attachments:count() == 0 then
        local was_visible = self:attachments_win() ~= nil
        self:_close_attachments_win()
        vim.api.nvim_set_current_win(self._prompt_win)
        vim.cmd("stopinsert")
        if was_visible then
            if is_float then
                self:_reposition_float_stack()
            else
                vim.api.nvim_win_call(self._history_win, function()
                    vim.cmd("wincmd _")
                end)
                vim.api.nvim_win_set_height(self._prompt_win, self._prompt:content_height())
            end
        end
        return
    end

    if is_float then
        self:_reposition_float_stack()
    else
        if not self:attachments_win() then
            self:_open_attachments_in_side_layout(self._prompt_win)
        end
        local awin = self:attachments_win()
        if awin then
            local side_cfg = Config.resolve_side_layout()
            if side_cfg.panels.attachments.winbar then
                set_winbar(awin, Config.options.panels.attachments.title, "PiChatAttachmentsWinbar")
            end
            -- Account for winbar + padding in target height
            local aheight = self._attachments:count() + 1 -- +1 for padding line
            if vim.wo[awin].winbar ~= "" then
                aheight = aheight + 1
            end
            vim.api.nvim_win_set_height(awin, aheight)
        end
        -- Maximize history, then re-fix prompt and attachments heights.
        -- Capture attachment height before wincmd _ steals its space.
        local target_attachments_height = awin and vim.api.nvim_win_get_height(awin) or 0
        vim.api.nvim_win_call(self._history_win, function()
            vim.cmd("wincmd _")
        end)
        vim.api.nvim_win_set_height(self._prompt_win, self._prompt:content_height())
        if awin then
            vim.api.nvim_win_set_height(awin, target_attachments_height)
        end
    end
end

--- Resolve a dimension (width or height) from a config value.
--- Values < 1 are treated as fractions of the available space.
---@param value number
---@param available integer
---@return integer
local function resolve_dimension(value, available)
    if value < 1 then
        return math.floor(available * value)
    end
    return math.floor(value)
end

--- Resolve side panel width in columns from config.
---@return integer
local function resolve_side_width()
    local side_cfg = Config.resolve_side_layout()
    return resolve_dimension(side_cfg.width, vim.o.columns)
end

--- Resolve float dimensions in pixels from config.
---@param float_cfg? pi.FloatLayout Pre-resolved config; resolved internally if omitted.
---@return integer width, integer total_height
local function resolve_float_size(float_cfg)
    float_cfg = float_cfg or Config.resolve_float_layout()
    local width = resolve_dimension(float_cfg.width, vim.o.columns)
    local total_height = resolve_dimension(float_cfg.height, vim.o.lines - vim.o.cmdheight - 1)
    return width, total_height
end

function Layout:_open_in_buffer_layout()
    self._return_win = vim.api.nvim_get_current_win()
    self._return_buf = vim.api.nvim_get_current_buf()
    self._return_opts = capture_win_opts(self._return_win)
    local global_number = vim.go.number
    local global_relativenumber = vim.go.relativenumber
    self._history_win = self._return_win
    set_win_buf(self._history_win, self:content_buf())
    if self._return_buf and vim.api.nvim_buf_is_valid(self._return_buf) then
        local old_buf = self._return_buf
        if vim.api.nvim_buf_get_name(old_buf) == "" and not vim.bo[old_buf].modified then
            local lines = vim.api.nvim_buf_get_lines(old_buf, 0, -1, false)
            if #lines == 1 and lines[1] == "" then
                vim.api.nvim_buf_delete(old_buf, { force = true })
                self._return_buf = nil
            end
        end
    end
    set_win_opts(self._history_win, function(win)
        vim.wo[win].winfixbuf = false
        vim.wo[win].number = global_number
        vim.wo[win].relativenumber = global_relativenumber
        vim.wo[win].foldenable = true
        vim.wo[win].foldmethod = "expr"
        vim.wo[win].foldexpr = "v:lua.require'pi.ui.chat.history'.nvim_foldexpr(v:lnum)"
        vim.wo[win].foldtext = "v:lua.require'pi.ui.chat.history'.nvim_foldtext()"
        vim.wo[win].foldlevel = 0
        vim.wo[win].foldcolumn = "1"
        if Render.engine() == "builtin" then
            vim.wo[win].conceallevel = 0
        end
    end)
    self:_configure_content_window(self._history_win, global_number, global_relativenumber)
    if not self._content_buf then
        self._history:set_win(self._history_win)
    end

    vim.cmd("belowright " .. Prompt.HEIGHT .. "split")
    self._prompt_win = vim.api.nvim_get_current_win()
    set_win_buf(self._prompt_win, self._prompt:buf())
    set_win_opts(self._prompt_win, function(win)
        vim.wo[win].winfixheight = true
        vim.wo[win].virtualedit = "onemore"
    end)
    set_winbar(self._prompt_win, Config.options.panels.prompt.title, "PiChatPromptWinbar")
    self._prompt:set_layout("buffer")
    self._prompt:set_win(self._prompt_win)
end

function Layout:_open_in_side_layout()
    local side_cfg = Config.resolve_side_layout()
    local panels = side_cfg.panels
    local w = resolve_side_width()
    local vsplit_cmd = side_cfg.position == "left" and "topleft" or "botright"
    vim.cmd(vsplit_cmd .. " " .. w .. "vsplit")

    self._history_win = vim.api.nvim_get_current_win()
    set_win_buf(self._history_win, self:content_buf())
    set_win_opts(self._history_win, function(win)
        vim.wo[win].winfixwidth = true
        -- Builtin engine: conceallevel=0 because treesitter markdown can't
        -- conceal brackets/bold in tool output.  render-markdown engine needs
        -- conceallevel=2 (set by set_win_opts) to hide syntax markers.
        if Render.engine() == "builtin" then
            vim.wo[win].conceallevel = 0
        end
    end)
    self:_configure_content_window(self._history_win)
    if not self._content_buf then
        self._history:set_win(self._history_win)
    end

    local prompt_winbar = panels.prompt.winbar
    vim.cmd("belowright " .. Prompt.HEIGHT .. "split")
    self._prompt_win = vim.api.nvim_get_current_win()
    set_win_buf(self._prompt_win, self._prompt:buf())
    set_win_opts(self._prompt_win, function(win)
        vim.wo[win].winfixwidth = true
        vim.wo[win].winfixheight = true
        vim.wo[win].virtualedit = "onemore"
    end)
    if prompt_winbar then
        set_winbar(self._prompt_win, Config.options.panels.prompt.title, "PiChatPromptWinbar")
    end
    self._prompt:set_layout("side")
    self._prompt:set_win(self._prompt_win)
end

function Layout:_open_in_float_layout()
    local float_cfg = Config.resolve_float_layout()
    local width, total_height = resolve_float_size(float_cfg)
    local history_height = total_height - Prompt.HEIGHT - 1
    local col = math.floor((vim.o.columns - width) / 2)
    local row = math.floor((vim.o.lines - vim.o.cmdheight - 1 - total_height) / 2)
    local border = float_cfg.border or "rounded"
    local user_win = float_cfg.win or {}

    self._history_win = vim.api.nvim_open_win(
        self:content_buf(),
        false,
        vim.tbl_deep_extend("force", {
            relative = "editor",
            width = width,
            height = history_height,
            col = col,
            row = row,
            style = "minimal",
            border = border,
            zindex = FLOAT_ZINDEX,
            title = " " .. Config.options.panels.history.title .. " ",
            title_pos = "center",
        }, user_win)
    )
    set_win_opts(self._history_win)
    vim.wo[self._history_win].winbar = ""
    vim.wo[self._history_win].winhighlight = Highlights.CHAT_HISTORY_WINHIGHLIGHT
    self:_configure_content_window(self._history_win)
    if not self._content_buf then
        self._history:set_win(self._history_win)
    end

    self._prompt_win = vim.api.nvim_open_win(
        self._prompt:buf(),
        true,
        vim.tbl_deep_extend("force", {
            relative = "editor",
            width = width,
            height = Prompt.HEIGHT,
            col = col,
            row = row + history_height + 2,
            style = "minimal",
            border = border,
            zindex = FLOAT_ZINDEX,
            title = " " .. Config.options.panels.prompt.title .. " ",
            title_pos = "center",
        }, user_win)
    )
    set_win_opts(self._prompt_win, function(win)
        vim.wo[win].winfixheight = true
        vim.wo[win].virtualedit = "onemore"
    end)
    vim.wo[self._prompt_win].winbar = ""
    vim.wo[self._prompt_win].winhighlight = Highlights.CHAT_PROMPT_WINHIGHLIGHT
    self._prompt:set_layout("float")
    self._prompt:set_win(self._prompt_win)
end

--- Handle editor resize. Re-evaluates layout config (which may be a function)
--- and updates window geometry in the current mode.
function Layout:on_resize()
    if not self:is_visible() then
        return
    end

    if self._mode == "float" then
        local float_cfg = Config.resolve_float_layout()
        local width, total_height = resolve_float_size(float_cfg)
        self:_reposition_float_stack(width, total_height, float_cfg)
    elseif self._mode == "side" then
        if self._history_win and vim.api.nvim_win_is_valid(self._history_win) then
            vim.api.nvim_win_set_width(self._history_win, resolve_side_width())
        end
    end
end

---@param entered_win integer
---@param entered_buf integer
function Layout:detach_for_buffer(entered_win, entered_buf)
    if not self:is_visible() then
        return
    end

    if self._mode == "buffer" and entered_win == self:history_win() then
        self._history:set_win(nil)
        self:_close_attachments_win()
        self:_close_prompt_win()
        self._history_win = nil
        self._return_win = nil
        self._return_buf = nil
        self._return_opts = nil
        vim.api.nvim_win_set_buf(entered_win, entered_buf)
        return
    end

    if entered_win == self:prompt_win() or entered_win == self:attachments_win() then
        local hwin = self:history_win()
        if hwin then
            vim.api.nvim_set_current_win(hwin)
            vim.api.nvim_win_set_buf(hwin, entered_buf)
        end
        self:hide()
    end
end

---@param other pi.ChatLayout
function Layout:takeover(other)
    if self == other then
        return
    end

    self._mode = other._mode
    self._history_win = other:history_win()
    self._prompt_win = other:prompt_win()
    self._attachments_win = other:attachments_win()
    self._return_win = other._return_win
    self._return_buf = other._return_buf
    self._return_opts = other._return_opts

    other._history:set_win(nil)
    other._prompt:set_win(nil)
    other._history_win = nil
    other._prompt_win = nil
    other._attachments_win = nil
    other._return_win = nil
    other._return_buf = nil
    other._return_opts = nil

    local hwin = self:history_win()
    if hwin then
        vim.wo[hwin].winfixbuf = false
        set_win_buf(hwin, self:content_buf())
        self:_configure_content_window(hwin)
        if not self._content_buf then
            self._history:set_win(hwin)
        end
    end

    local pwin = self:prompt_win()
    if pwin then
        vim.wo[pwin].winfixbuf = false
        set_win_buf(pwin, self._prompt:buf())
        self._prompt:set_layout(self._mode)
        self._prompt:set_win(pwin)
    end

    if self._attachments:count() == 0 then
        self:_close_attachments_win()
    elseif self._attachments_win then
        vim.wo[self._attachments_win].winfixbuf = false
        set_win_buf(self._attachments_win, self._attachments:buf())
    elseif pwin then
        self:_refresh_attachments()
    end

    self:_refresh_prompt_chrome()
end

---@return boolean opened true if a fresh open occurred
function Layout:show()
    if self._history_win and vim.api.nvim_win_is_valid(self._history_win) then
        return false
    end
    if self._mode == "buffer" then
        self:_open_in_buffer_layout()
    elseif self._mode == "float" then
        self:_open_in_float_layout()
    else
        self:_open_in_side_layout()
    end
    -- auto_open lives here (not in Chat:show) so every path that makes the
    -- chat visible — including set_layout/set_mode — opens the list too.
    if Config.options.sessions_list.auto_open then
        require("pi.ui.sessions").open()
    end
    return true
end

function Layout:hide()
    -- Clear winbars before closing to prevent window-buffer-local
    -- winbar state from leaking into the next layout's windows.
    local awin = self:attachments_win()
    if awin then
        clear_winbar(awin)
    end
    local pwin = self:prompt_win()
    if pwin then
        clear_winbar(pwin)
    end
    local hwin = self:history_win()
    if hwin then
        clear_winbar(hwin)
    end

    self:_close_attachments_win()
    self:_close_prompt_win()

    if self._mode == "buffer" then
        local buffer_win = self:history_win()
        self._history:set_win(nil)
        if buffer_win then
            local target = self._return_buf
            if not target or not vim.api.nvim_buf_is_valid(target) then
                target = vim.api.nvim_create_buf(true, false)
            end
            vim.api.nvim_win_set_buf(buffer_win, target)
            restore_win_opts(buffer_win, self._return_opts or {})
        end
        self._history_win = nil
        self._history:set_win(nil)
        self._return_win = nil
        self._return_buf = nil
        self._return_opts = nil
    else
        self:_close_history_win()
    end
end

---@return pi.LayoutMode
function Layout:mode()
    return self._mode
end

---@param mode pi.LayoutMode
function Layout:set_mode(mode)
    -- Save prompt cursor before tearing down windows.
    local prompt_cursor
    local pwin = self:prompt_win()
    if pwin then
        prompt_cursor = vim.api.nvim_win_get_cursor(pwin)
    end

    self:hide()
    self._mode = mode
    self:show()
    self._prompt:resize()
    if self._attachments:count() > 0 then
        self:_refresh_attachments()
    end

    -- Restore prompt cursor in the new window.
    if prompt_cursor then
        pwin = self:prompt_win()
        if pwin then
            local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(pwin))
            prompt_cursor[1] = math.min(prompt_cursor[1], line_count)
            vim.api.nvim_win_set_cursor(pwin, prompt_cursor)
        end
    end
end

function Layout:toggle()
    self:set_mode(self._mode == "float" and "buffer" or "float")
end

---@return boolean
function Layout:is_visible()
    return self._history_win ~= nil and vim.api.nvim_win_is_valid(self._history_win)
end

---@return integer?
function Layout:history_win()
    if self._history_win and vim.api.nvim_win_is_valid(self._history_win) then
        return self._history_win
    end
    return nil
end

---@return integer?
function Layout:prompt_win()
    if self._prompt_win and vim.api.nvim_win_is_valid(self._prompt_win) then
        return self._prompt_win
    end
    return nil
end

---@return integer?
function Layout:attachments_win()
    if self._attachments_win and vim.api.nvim_win_is_valid(self._attachments_win) then
        return self._attachments_win
    end
    return nil
end

return Layout
