--- Prompt buffer management.

---@class pi.ChatPrompt
---@field _buf integer
---@field _win integer?
---@field _layout pi.LayoutMode
---@field _statusline pi.StatusLine
---@field _attachments pi.ChatAttachments
---@field _tab pi.TabId
---@field _zen boolean
---@field _bash_mode boolean
---@field _on_bash_mode_change fun(is_bash: boolean)?
---@field _resume_insert? "eol"|"bol"|"mid"
local Prompt = {}
Prompt.__index = Prompt

local Ft = require("pi.filetypes")
local Config = require("pi.config")
local Keys = require("pi.keys")
local Decorators = require("pi.ui.chat.decorators")
local Draft = require("pi.draft")
local StatusLine = require("pi.ui.chat.statusline")

Prompt.HEIGHT = 5
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
    if vim.wo[win].winbar ~= "" then
        height = height - 1
    end
    return math.max(height, 1)
end

---@param mode string?
---@return boolean
local function is_visual_mode(mode)
    local first = mode and mode:sub(1, 1) or ""
    return first == "v" or first == "V" or first == "\22"
end

---@param tab pi.TabId
---@param attachments pi.ChatAttachments
---@return pi.ChatPrompt
function Prompt.new(tab, attachments)
    local self = setmetatable({}, Prompt)
    self._win = nil
    self._attachments = attachments
    self._tab = tab
    self._zen = false
    self._bash_mode = false
    self._on_bash_mode_change = nil

    local panel = Config.options.panels.prompt
    local name = panel.name and panel.name(tab) or ("π-prompt | " .. tab)
    wipe_stale_buf(name)
    self._buf = vim.api.nvim_create_buf(false, true)
    vim.bo[self._buf].buftype = "nofile"
    vim.bo[self._buf].filetype = Ft.prompt
    vim.bo[self._buf].swapfile = false
    vim.bo[self._buf].bufhidden = "hide"
    vim.api.nvim_buf_set_name(self._buf, name)

    -- Unsent-draft persistence: restore a draft saved before a restart (once
    -- per process) and keep saving the current text (debounced) thereafter.
    local draft_cfg = Config.options.prompt and Config.options.prompt.draft
    if draft_cfg and draft_cfg.enabled ~= false then
        local draft = Draft.restore_once()
        if draft and draft ~= "" then
            vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, vim.split(draft, "\n", { plain = true }))
        end

        local save_timer = assert(vim.uv.new_timer())
        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
            buffer = self._buf,
            callback = function()
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
    Decorators.attach(self._buf)

    Keys.bind_wrapped_line_navigation(self._buf)

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = self._buf,
        callback = function()
            vim.cmd("stopinsert")
        end,
    })

    self._statusline = StatusLine.new(self._buf, tab, function()
        return self:win()
    end)

    -- Auto-resize prompt window to fit content while editing.
    -- Order matters: resize first (uses content height minus status padding),
    -- then render status line (uses resulting window height for padding).
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = self._buf,
        callback = function()
            self:resize()
            self:_render_statusline()
            self:_refresh_bash_mode()
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
                self:resize()
                self:_render_statusline()
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
                        self:_render_statusline()
                        return
                    end
                end
            end
        end,
    })

    -- Override vim.paste to intercept drag-and-drop image file paths
    local original_paste = vim.paste
    vim.paste = (function(original)
        return function(lines, phase)
            if vim.api.nvim_get_current_buf() ~= self._buf then
                return original(lines, phase)
            end
            local line = lines[1]
            if line and #lines == 1 and line ~= "" then
                local stat = vim.uv.fs_stat(line)
                if stat and stat.type == "file" then
                    local ext = line:match("%.(%w+)$")
                    if ext and vim.tbl_contains({ "png", "jpg", "jpeg", "gif", "webp", "svg" }, ext:lower()) then
                        self._attachments:add_file(line)
                        return true
                    end
                end
            end
            return original(lines, phase)
        end
    end)(original_paste)

    return self
end

---@return integer
function Prompt:buf()
    return self._buf
end

---@return pi.StatusLine
function Prompt:statusline()
    return self._statusline
end

---@param cb fun(is_bash: boolean)
function Prompt:set_on_bash_mode_change(cb)
    self._on_bash_mode_change = cb
end

---@return boolean
function Prompt:is_bash_mode()
    return self._bash_mode
end

--- Bash mode is active when the prompt text starts with "!" (leading
--- whitespace ignored), mirroring the pi TUI's editor behavior.
---@return boolean
function Prompt:_compute_bash_mode()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return false
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(self._buf, 0, -1, false), "\n")
    return text:match("^%s*!") ~= nil
end

--- Recompute bash mode from the buffer text and notify on change. Called on
--- text changes; also invoked explicitly after programmatic edits since
--- TextChangedI is deferred and may not have fired yet (gotcha G4).
function Prompt:_refresh_bash_mode()
    local is_bash = self:_compute_bash_mode()
    if is_bash == self._bash_mode then
        return
    end
    self._bash_mode = is_bash
    if self._on_bash_mode_change then
        self._on_bash_mode_change(is_bash)
    end
end

--- Re-render the prompt statusline and reset wrapped scrolling when the
--- whole prompt fits again. Neovim can leave stale skipcol/topline state
--- after a wrapped line splits before the statusline extmark is moved.
function Prompt:_render_statusline()
    self._statusline:render()
    self:_reset_view_if_content_fits()
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
    local visual_lines = vim.api.nvim_win_text_height(self._win, {}).all
    -- Subtract status line virt_lines (padding + status) so padding doesn't
    -- prevent the window from shrinking. Add 1 back for the status line itself.
    local content_lines = visual_lines - self._statusline:virt_line_count() + 1
    local target_height = math.max(Prompt.HEIGHT, math.min(content_lines, Prompt.MAX_HEIGHT))
    if vim.wo[self._win].winbar ~= "" then
        target_height = target_height + 1
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

---@param cb? fun()
function Prompt:focus(cb)
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    vim.api.nvim_set_current_win(self._win)
    vim.schedule(function()
        vim.cmd("startinsert")
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
    local lines = vim.api.nvim_buf_get_lines(self._buf, 0, -1, false)
    return vim.fn.trim(table.concat(lines, "\n"))
end

function Prompt:clear_text()
    if self._buf and vim.api.nvim_buf_is_valid(self._buf) then
        vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, { "" })
        self:resize()
        self:_render_statusline()
        self:_refresh_bash_mode()
    end
end

--- Persist the current prompt text as the unsent draft (empty text clears it).
--- Called (debounced) on text changes; exposed as a method so the save logic is
--- testable independent of the TextChanged event.
function Prompt:_save_draft()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(self._buf, 0, -1, false), "\n")
    Draft.save(vim.trim(text) == "" and "" or text)
end

---@return integer
function Prompt:content_height()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return Prompt.HEIGHT
    end
    local line_count = vim.api.nvim_buf_line_count(self._buf) + 1 -- +1 for status line
    local target_height = math.max(Prompt.HEIGHT, math.min(line_count, Prompt.MAX_HEIGHT))
    if self._win and vim.api.nvim_win_is_valid(self._win) and vim.wo[self._win].winbar ~= "" then
        target_height = target_height + 1
    end
    return target_height
end

return Prompt
