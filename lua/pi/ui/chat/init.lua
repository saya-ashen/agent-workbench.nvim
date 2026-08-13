--- Chat UI orchestration — layout, window management, and wiring.

---@class pi.ChatAgent
---@field send fun(msg: pi.RpcCommand, callback?: fun(res: pi.RpcEvent)): boolean?

---@class pi.Chat
---@field _tab pi.TabId
---@field _agent pi.ChatAgent
---@field _layout pi.ChatLayout
---@field _history pi.ChatHistory
---@field _prompt pi.ChatPrompt
---@field _keymaps_set boolean
---@field _streaming boolean
---@field _retrying boolean True while the core is in an auto-retry backoff (between agent_end and the retry's agent_start). The double-<Esc> abort gesture stays live here even though nothing is streaming.
---@field _abort_esc_at number? Timestamp (ms) of the first <Esc> in a double-<Esc> abort gesture (nil = not armed)
---@field _abort_esc_timer uv.uv_timer_t? Disarms the double-<Esc> gesture after `abort.timeout`
---@field _aborted_notice_timer uv.uv_timer_t? Clears the transient "Aborted" overlay notice
---@field _compacting boolean
---@field _assistant_block_open boolean
---@field _assistant_message_header_rendered boolean
---@field _assistant_tool_only_header_rendered boolean
---@field _assistant_message_timestamp number?
---@field _flushed_queue_entries pi.PendingQueueEntry[]
---@field _replay_flushed_queue_entries pi.PendingQueueEntry[]
---@field _compaction_queue pi.CompactionQueuedMessage[]
---@field _active_verb string?
---@field _done_verb string?
---@field _last_turn_stop_reason "aborted"|"error"|nil
---@field _attachments pi.ChatAttachments
---@field _zen pi.Zen
---@field _bash_running boolean
---@field _bash_req_id string?
---@field _bash_req_counter integer
local Chat = {}
Chat.__index = Chat

local Config = require("pi.config")
local Notify = require("pi.notify")
local CommandsCache = require("pi.cache.commands")
local Layout = require("pi.ui.chat.layout")
local Attention = require("pi.attention")
local History = require("pi.ui.chat.history")
local Render = require("pi.ui.render")
local Prompt = require("pi.ui.chat.prompt")
local Attachments = require("pi.ui.chat.attachments")
local Mentions = require("pi.ui.chat.mentions")
local Zen = require("pi.ui.chat.zen")
local PromptHistory = require("pi.prompt_history")

---@class pi.CompactionQueuedMessage
---@field text string
---@field expanded string
---@field mode "steer"|"follow_up"
---@field images? table[]
---@field image_count? integer

---@param tab pi.TabId
---@param mode pi.LayoutMode
---@param agent pi.ChatAgent
---@param history_name? string
---@param session_id? integer
---@return pi.Chat
function Chat.new(tab, mode, agent, history_name, session_id)
    local self = setmetatable({}, Chat)
    self._tab = tab
    self._session_id = session_id or tab
    self._agent = agent
    self._attachments = Attachments.new()
    self._prompt = Prompt.new(self._session_id, self._attachments)
    self._history = History.new(tab, history_name, self._session_id)
    self._layout = Layout.new(mode, self._history, self._prompt, self._attachments)
    self._keymaps_set = false
    self._streaming = false
    self._retrying = false
    self._abort_esc_at = nil
    self._abort_esc_timer = nil
    self._aborted_notice_timer = nil
    self._compacting = false
    self._assistant_block_open = false
    self._assistant_message_header_rendered = false
    self._assistant_tool_only_header_rendered = false
    self._assistant_message_timestamp = nil
    self._flushed_queue_entries = {}
    self._replay_flushed_queue_entries = {}
    self._compaction_queue = {}
    self._active_verb = nil
    self._done_verb = nil
    self._last_turn_stop_reason = nil
    self._zen = Zen.new(self._prompt)
    self._prompt_history = nil
    self._last_applied_prompt = nil
    self._bash_running = false
    self._bash_req_id = nil
    self._bash_req_counter = 0
    self._prompt:set_on_bash_mode_change(function(is_bash)
        self._layout:set_bash_mode(is_bash)
    end)
    -- History owns busy/queue rendering at latest output; statusline still keeps
    -- the same busy state for prompt winbar and API consumers.
    local statusline = self._prompt:statusline()
    self._history:set_status_listener(function(model)
        statusline:set_busy(model)
    end)
    self._history:set_queue_listener(function(count)
        statusline:set_queue_count(count)
    end)
    return self
end

function Chat:_set_keymaps()
    if self._keymaps_set then
        return
    end
    self._keymaps_set = true

    local hbuf = self._history:buf()
    local pbuf = self._prompt:buf()

    -- Redirect insert-mode keys from history -> prompt
    for _, key in ipairs({ "i", "I", "a", "A", "o", "O", "c", "C" }) do
        vim.keymap.set("n", key, function()
            self:ensure_shown_and_focus_prompt()
        end, { buffer = hbuf, desc = "Redirect to π prompt" })
    end

    -- Auto-enter insert mode when focusing the prompt from outside
    vim.api.nvim_create_autocmd("WinEnter", {
        buffer = pbuf,
        callback = function()
            vim.schedule(function()
                -- Guard: by the time this runs, focus may have moved elsewhere
                local buf = vim.api.nvim_get_current_buf()
                if buf ~= pbuf then
                    return
                end
                Attention.dismiss_notification(self._tab)
                self:_auto_dispatch_attention_on_prompt_focus()
                if vim.api.nvim_get_current_buf() ~= pbuf then
                    return
                end
                if vim.api.nvim_get_mode().mode ~= "i" then
                    local resume = self._prompt._resume_insert
                    if resume then
                        self._prompt._resume_insert = nil
                        if resume == "eol" then
                            vim.cmd("startinsert!")
                        elseif resume == "mid" then
                            -- Mid-line: move cursor right to undo the
                            -- InsertLeave left-shift, then enter insert.
                            vim.cmd("normal! l")
                            vim.cmd("startinsert")
                        else
                            -- bol: InsertLeave doesn't shift at col 0.
                            vim.cmd("startinsert")
                        end
                    else
                        vim.cmd("startinsert")
                    end
                end
            end)
        end,
    })

    -- Submit keymaps on prompt
    vim.keymap.set("n", "<CR>", function()
        self:submit()
    end, { buffer = pbuf, desc = "Submit π prompt" })

    vim.keymap.set("i", "<CR>", function()
        self:submit()
    end, { buffer = pbuf, desc = "Submit π prompt" })

    -- Follow-up: queued until agent finishes
    vim.keymap.set("n", "<A-CR>", function()
        self:submit_follow_up()
    end, { buffer = pbuf, desc = "Submit π follow-up" })

    vim.keymap.set("i", "<A-CR>", function()
        self:submit_follow_up()
    end, { buffer = pbuf, desc = "Submit π follow-up" })

    -- New line
    -- TODO?: Should be configurable?
    vim.keymap.set("i", "<S-CR>", function()
        vim.api.nvim_put({ "", "" }, "c", false, true)
    end, { buffer = pbuf, desc = "New line" })

    -- Double-<Esc> abort: while streaming, the first <Esc> shows a gentle hint
    -- and arms the gesture; a second <Esc> within the configured window aborts
    -- the agent (same as :PiAbort). Insert mode always leaves insert (returns
    -- the literal "<Esc>", see gotcha G2); normal mode only arms/aborts.
    vim.keymap.set("i", "<Esc>", function()
        self:_handle_abort_esc()
        return "<Esc>"
    end, { buffer = pbuf, expr = true, desc = "Leave insert (double-<Esc> aborts π)" })

    vim.keymap.set("n", "<Esc>", function()
        self:_handle_abort_esc()
    end, { buffer = pbuf, desc = "Double-<Esc> aborts π" })

    vim.keymap.set("n", "<Esc>", function()
        self:_handle_abort_esc()
    end, { buffer = hbuf, desc = "Double-<Esc> aborts π" })

    -- Prompt history recall (readline-style). <C-p>/<C-n> are the canonical
    -- readline keys and never conflict with multi-line cursor movement.
    -- <Up>/<Down> also recall, but only when they wouldn't otherwise move the
    -- cursor (top/bottom line) and the completion menu is closed.
    vim.keymap.set({ "i", "n" }, "<C-p>", function()
        if vim.fn.pumvisible() == 0 then
            self:history_prev()
        end
    end, { buffer = pbuf, desc = "π history: previous" })

    vim.keymap.set({ "i", "n" }, "<C-n>", function()
        if vim.fn.pumvisible() == 0 then
            self:history_next()
        end
    end, { buffer = pbuf, desc = "π history: next" })

    vim.keymap.set("i", "<Up>", function()
        if vim.fn.pumvisible() == 1 or vim.api.nvim_win_get_cursor(0)[1] > 1 then
            return "<Up>"
        end
        return self:history_prev() and "" or "<Up>"
    end, { buffer = pbuf, expr = true, desc = "π history: previous (top line)" })

    vim.keymap.set("i", "<Down>", function()
        if vim.fn.pumvisible() == 1 then
            return "<Down>"
        end
        local store = self:_history_store()
        local navigating = store and store:navigating() or false
        local last_line = vim.api.nvim_buf_line_count(pbuf)
        if navigating or vim.api.nvim_win_get_cursor(0)[1] >= last_line then
            if self:history_next() then
                return ""
            end
        end
        return "<Down>"
    end, { buffer = pbuf, expr = true, desc = "π history: next (bottom line)" })

    -- Leave history-navigation mode when the user edits the prompt by hand, so
    -- a later <Down> doesn't clobber their typing with a stale entry.
    --
    -- We can't use a boolean "applying" flag here: TextChangedI is a *deferred*
    -- event, so it fires after the schedule that would clear such a flag, and
    -- the flag would already be false by the time this runs. Instead, compare
    -- the buffer text against what we last wrote programmatically — equal means
    -- a recall edit (keep navigation), different means a manual edit (reset).
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = pbuf,
        callback = function()
            local buf = self._prompt:buf()
            if not vim.api.nvim_buf_is_valid(buf) then
                return
            end
            local cur = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            if cur == self._last_applied_prompt then
                return
            end
            local store = self:_history_store()
            if store and store:navigating() then
                store:reset_nav()
            end
        end,
    })

    local function set_block(expanded)
        local kind, current = self._history:block_state_at_cursor()
        if not kind then
            return false
        end
        if kind == "tool" then
            return self._history:set_tool_block_expanded_at_cursor(expanded)
        end
        return self._history:set_block_expanded_at_cursor(expanded ~= nil and expanded or not current)
    end

    local function toggle_block()
        local kind, expanded = self._history:block_state_at_cursor()
        if not kind then
            return false
        end
        if kind == "tool" then
            return self._history:toggle_tool_block()
        end
        return self._history:set_block_expanded_at_cursor(not expanded)
    end

    for _, lhs in ipairs({ "za", "<CR>", "o" }) do
        vim.keymap.set("n", lhs, toggle_block, {
            buffer = hbuf,
            silent = true,
            desc = "Toggle π block under cursor",
        })
    end
    vim.keymap.set("n", "<Tab>", function()
        local kind, expanded = self._history:block_state_at_cursor()
        if not kind then
            return false
        end
        if kind == "tool" then
            return self._history:open_tool_output_at_cursor()
        end
        return self._history:set_block_expanded_at_cursor(not expanded)
    end, {
        buffer = hbuf,
        silent = true,
        desc = "Open π block output",
    })
    vim.keymap.set("n", "zo", function()
        set_block(true)
    end, { buffer = hbuf, silent = true, desc = "Expand π block under cursor" })
    vim.keymap.set("n", "zc", function()
        set_block(false)
    end, { buffer = hbuf, silent = true, desc = "Collapse π block under cursor" })

    -- Open the file referenced under the cursor (tool path lines, @mentions,
    -- path:line) in an editor window. gf has no default use on a nofile chat
    -- buffer, so it's a natural fit.
    vim.keymap.set("n", "gf", function()
        self:goto_path_at_cursor()
    end, { buffer = hbuf, desc = "π: open file under cursor" })

    -- Zen toggle key — permanent on the prompt buffer.
    -- Enters zen when inactive, exits when active.
    local zen_cfg = Config.options.zen
    local zen_keys = zen_cfg and zen_cfg.keys or nil
    if zen_keys and zen_keys.toggle then
        local Keys = require("pi.keys")
        for _, key in ipairs(Keys.resolve(zen_keys.toggle)) do
            Keys.bind(pbuf, key, function()
                self:zen_toggle()
            end, { modes = { "n", "i" }, nowait = true, desc = "Toggle π zen mode" })
        end
    end
end

---@class pi.ChatShowOpts
---@field loading? boolean Show "Loading session…" placeholder

---@param opts? pi.ChatShowOpts
function Chat:show(opts)
    if not self._layout:show() then
        -- already shown
        self:refresh_prompt_attention()
        return
    end
    self:_set_keymaps()
    if opts and opts.loading then
        self:show_loading()
    else
        -- Render the welcome header with loading hint until startup data arrives.
        self._history:show_loading_startup()
    end
    self:refresh_prompt_attention()
    self._prompt:focus()
end

--- Show a loading placeholder on the empty history buffer.
function Chat:show_loading()
    local icon = " " .. Config.options.labels.agent_response .. " "
    self._history:show_loading_placeholder({
        {
            { icon, "PiAgentResponseLabel" },
            { "  Loading session…", "PiWelcomeHint" },
        },
    })
end

function Chat:hide()
    if self._zen:is_active() then
        self._zen:exit()
    end
    self._layout:hide()
end

--- Handle editor resize. Re-evaluates layout config and updates geometry.
function Chat:on_resize()
    self._layout:on_resize()
    self:refresh_prompt_attention()
end

---@param cb? fun()
function Chat:toggle_layout(cb)
    self._prompt._resume_insert = nil
    self._layout:toggle()
    self:refresh_prompt_attention()

    -- Determine how to re-enter insert mode based on the normal-mode
    -- cursor position after the switch.  InsertLeave shifts the cursor
    -- left by 1 (except at col 0), so we compensate:
    --   eol (on or past last char) → startinsert!  (A)
    --   bol (col 0)                → startinsert   (no shift happened)
    --   mid                        → normal! l + startinsert
    local pwin = self._layout:prompt_win()
    if pwin then
        local cur = vim.api.nvim_win_get_cursor(pwin)
        local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(pwin), cur[1] - 1, cur[1], false)[1] or ""
        local last_col = math.max(0, #line - 1)
        if cur[2] >= last_col then
            self._prompt._resume_insert = "eol"
        elseif cur[2] == 0 then
            self._prompt._resume_insert = "bol"
        else
            self._prompt._resume_insert = "mid"
        end
    end

    self:focus_prompt(cb)
end

---@param mode pi.LayoutMode
function Chat:set_layout(mode)
    self._layout:set_mode(mode)
    self:refresh_prompt_attention()
end

---@return pi.LayoutMode
function Chat:layout()
    return self._layout:mode()
end

---@return boolean
function Chat:is_visible()
    return self._layout:is_visible()
end

---@return pi.ChatHistory
function Chat:history()
    return self._history
end

---@param other pi.Chat
function Chat:takeover_view(other)
    self:set_tab(vim.api.nvim_get_current_tabpage())
    self._layout:takeover(other._layout)
    self:_set_keymaps()
    self:refresh_prompt_attention()
end

---@param win integer
---@param buf integer
function Chat:detach_for_buffer(win, buf)
    self._layout:detach_for_buffer(win, buf)
end

---@param tab pi.TabId
function Chat:set_tab(tab)
    self._tab = tab
    self._prompt:set_tab(tab)
end

---@return integer
function Chat:history_buf()
    return self._history:buf()
end

---@param history pi.ChatHistory
function Chat:attach_history(history)
    if self._history == history then
        return
    end
    local was_visible = self:is_visible()
    if was_visible then
        self:hide()
    end
    self._history = history
    self._layout:set_history(history)
    local statusline = self._prompt:statusline()
    history:set_status_listener(function(model)
        statusline:set_busy(model)
    end)
    history:set_queue_listener(function(count)
        statusline:set_queue_count(count)
    end)
    self._keymaps_set = false
    if was_visible then
        self:show()
    end
end

---@param name string
function Chat:set_history_name(name)
    self._history:set_name(name)
end

---@return integer
function Chat:prompt_buf()
    return self._prompt:buf()
end

---@return integer
function Chat:attachments_buf()
    return self._attachments:buf()
end

---@return integer?
function Chat:prompt_win()
    return self._layout:prompt_win()
end

---@return "history"|"prompt"|"attachments"|nil
function Chat:focus_kind()
    local current_tab = vim.api.nvim_get_current_tabpage()
    local current_win = vim.api.nvim_get_current_win()
    if self._tab and self._tab ~= current_tab then
        return nil
    end

    local history_win = self._layout:history_win()
    if history_win and history_win == current_win then
        return "history"
    end

    local prompt_win = self._layout:prompt_win()
    if prompt_win and prompt_win == current_win then
        return "prompt"
    end

    local attachments_win = self._layout:attachments_win()
    if attachments_win and attachments_win == current_win then
        return "attachments"
    end

    return nil
end

---@return boolean
function Chat:has_focus()
    return self:focus_kind() ~= nil
end

---@return boolean
function Chat:has_prompt_focus()
    return self:focus_kind() == "prompt"
end

---@return boolean
function Chat:has_draft()
    return self._prompt:text() ~= "" or self._attachments:count() > 0
end

---@return boolean opened
function Chat:_auto_dispatch_attention_on_prompt_focus()
    local attention_config = Config.options.attention
    if not attention_config or not attention_config.auto_open_on_prompt_focus then
        return false
    end
    if not self:has_prompt_focus() or self:has_draft() then
        return false
    end
    return require("pi.attention").open_next_for_tab(self._tab)
end

---@param cb? fun()
function Chat:focus_prompt(cb)
    vim.schedule(function()
        self._prompt:focus(cb)
    end)
end

function Chat:ensure_shown_and_focus_prompt()
    self:show()
    vim.schedule(function()
        self._prompt:focus()
    end)
end

function Chat:focus_history()
    local hwin = self._layout:history_win()
    if hwin then
        vim.api.nvim_set_current_win(hwin)
    end
end

function Chat:focus_attachments()
    local awin = self._layout:attachments_win()
    if awin then
        vim.api.nvim_set_current_win(awin)
    end
end

function Chat:toggle()
    if self._layout:is_visible() then
        self._layout:hide()
    else
        self:ensure_shown_and_focus_prompt()
    end
end

--- Toggle zen mode (full-screen prompt float).
function Chat:zen_toggle()
    if not self._layout:is_visible() then
        self:ensure_shown_and_focus_prompt()
    end
    self._zen:toggle()
end

---@return boolean
function Chat:zen_active()
    return self._zen:is_active()
end

--- Submit the prompt. When streaming, sends as a steer (interrupt); otherwise regular prompt.
function Chat:submit()
    if self._compacting then
        self:_queue_compaction_message("steer")
        return
    end
    self:_send_message(self._streaming and "steer" or nil)
end

--- Submit the prompt as a follow-up. When streaming, queued until agent finishes;
--- otherwise sends as a regular prompt.
function Chat:submit_follow_up()
    if self._compacting then
        self:_queue_compaction_message("follow_up")
        return
    end
    self:_send_message(self._streaming and "follow_up" or nil)
end

---@return boolean
function Chat:is_streaming()
    return self._streaming
end

--- Track the core's auto-retry backoff state. While retrying, the double-<Esc>
--- abort gesture stays live (arming on the first press) even though nothing is
--- streaming; the second press then sends abort_retry instead of abort.
---@param retrying boolean
function Chat:set_retrying(retrying)
    if self._retrying == retrying then
        return
    end
    self._retrying = retrying
    if not retrying then
        -- Don't let a gesture armed during the backoff bleed into the next
        -- streaming phase: the user must re-arm while streaming.
        self:_disarm_abort_esc()
    end
end

--- Render or clear the abort hint in the statusline center to match the
--- current armed state. Deferred with vim.schedule because the caller may run inside
--- the insert-mode <expr> mapping, where buffer/window mutations are dropped
--- (gotcha G1). State-driven (the last scheduled sync wins), so rapid
--- arm/disarm sequences never leave a stale hint behind.
function Chat:_sync_abort_hint()
    vim.schedule(function()
        if self._abort_esc_at and (self._streaming or self._retrying) then
            local cfg = Config.options.abort or {}
            if cfg.enabled ~= false then
                self._prompt:statusline():set_abort_hint(cfg.message or "Press <Esc> again to abort")
                return
            end
        end
        self._prompt:statusline():clear_abort_hint()
    end)
end

--- Disarm the double-<Esc> gesture: forget the armed state, stop the disarm
--- timer, and clear the overlay hint. Safe to call from an <expr> mapping (no
--- synchronous buffer/window mutations).
function Chat:_disarm_abort_esc()
    self._abort_esc_at = nil
    if self._abort_esc_timer then
        self._abort_esc_timer:stop()
        self._abort_esc_timer:close()
        self._abort_esc_timer = nil
    end
    self:_sync_abort_hint()
end

--- Handle one <Esc> press of the double-<Esc> abort gesture.
---
--- While the agent is streaming **or auto-retrying** (statusline shows
--- "Retrying…"), the first press arms the gesture and shows a hint row in the
--- bottom status overlay; a second press within `abort.timeout` ms aborts
--- (same as :PiAbort / pi.abort()). A timer disarms automatically once the
--- window elapses. Outside of streaming/retrying, or when the feature is
--- disabled, this is a no-op so <Esc> keeps its normal behavior.
function Chat:_handle_abort_esc()
    if not (self._streaming or self._retrying) then
        -- A single <Esc> cancels a running direct bash command (TUI behavior).
        if self._bash_running then
            require("pi").abort_bash()
            return
        end
        self:_disarm_abort_esc()
        return
    end
    local cfg = Config.options.abort or {}
    if cfg.enabled == false then
        return
    end
    -- Second press while armed -> abort. During the retry backoff there is no
    -- agent run to abort, so the precise abort_retry command is sent instead
    -- (it only cancels the backoff sleep, matching the TUI's retry escape
    -- handler). Decide synchronously: by the time the scheduled callback runs
    -- the retry may already have transitioned into streaming.
    if self._abort_esc_at then
        self:_disarm_abort_esc()
        local abort_retry = self._retrying and not self._streaming
        vim.schedule(function()
            if abort_retry then
                require("pi").abort_retry()
            else
                require("pi").abort()
            end
        end)
        return
    end
    -- First press -> arm, show the hint, and schedule an automatic disarm.
    self._abort_esc_at = vim.uv.now()
    if self._abort_esc_timer then
        self._abort_esc_timer:stop()
        self._abort_esc_timer:close()
    end
    local timeout = cfg.timeout or 1500
    self._abort_esc_timer = assert(vim.uv.new_timer())
    self._abort_esc_timer:start(
        timeout,
        0,
        vim.schedule_wrap(function()
            self:_disarm_abort_esc()
        end)
    )
    self:_sync_abort_hint()
end

--- Clear the transient "Aborted" overlay notice and stop its timer.
function Chat:_clear_aborted_notice()
    if self._aborted_notice_timer then
        self._aborted_notice_timer:stop()
        self._aborted_notice_timer:close()
        self._aborted_notice_timer = nil
    end
    self._prompt:statusline():clear_aborted_notice()
end

--- Show a transient "Aborted" confirmation in the statusline center for ~2s,
--- so the user gets clear feedback that the turn was aborted.
function Chat:_show_aborted_notice()
    self:_clear_aborted_notice()
    self._prompt:statusline():set_aborted_notice("Aborted")
    self._aborted_notice_timer = assert(vim.uv.new_timer())
    self._aborted_notice_timer:start(
        2000,
        0,
        vim.schedule_wrap(function()
            self:_clear_aborted_notice()
        end)
    )
end

---@return boolean
function Chat:is_compacting()
    return self._compacting
end

---@param compacting boolean
function Chat:set_compacting(compacting)
    self._compacting = compacting
end

---@param text string
---@return boolean
function Chat:_is_extension_command(text)
    if not text:match("^%s*/") then
        return false
    end
    local name = text:match("^%s*/([^%s]+)")
    if not name then
        return false
    end
    for _, command in ipairs(CommandsCache.list()) do
        if command.name == name and command.source == "extension" then
            return true
        end
    end
    return false
end

---@param entry pi.CompactionQueuedMessage
---@param command_type "prompt"|"steer"|"follow_up"
---@return boolean
function Chat:_send_compaction_entry(entry, command_type)
    ---@type pi.RpcCommand
    local cmd = { type = command_type, message = entry.expanded }
    if entry.images and #entry.images > 0 then
        cmd.images = entry.images
    end
    return self._agent.send(cmd) ~= false
end

---@param entry pi.PendingQueueEntry|pi.CompactionQueuedMessage
function Chat:_remember_flushed_queue_entry(entry)
    self._flushed_queue_entries[#self._flushed_queue_entries + 1] = {
        queue_type = entry.queue_type or entry.mode,
        text = entry.text,
        expanded_text = entry.expanded_text or entry.expanded,
        image_count = entry.image_count,
    }
end

---@param entry pi.CompactionQueuedMessage
function Chat:_ensure_pending_compaction_entry(entry)
    self._history:remove_pending_queue_entry(entry.expanded)
    self._history:add_pending_queue_entry(entry.mode, entry.text, entry.expanded, entry.image_count)
end

---@param mode "steer"|"follow_up"
function Chat:_queue_compaction_message(mode)
    local text = self._prompt:text()
    local image_count = self._attachments:count()
    if text == "" and image_count == 0 then
        return
    end

    if self._zen:is_active() then
        self._zen:exit()
    end

    self._prompt:clear_text()
    local attachments = image_count > 0 and self._attachments:get() or nil
    self._attachments:clear()
    local expanded = Mentions.expand(text)

    if self:_is_extension_command(text) then
        self._history:add_user_message(text, nil, attachments and #attachments or nil)
        self:_send_compaction_entry({ text = text, expanded = expanded, mode = mode, images = attachments }, "prompt")
        return
    end

    local entry = {
        text = text,
        expanded = expanded,
        mode = mode,
        images = attachments,
        image_count = attachments and #attachments or nil,
    }
    self._compaction_queue[#self._compaction_queue + 1] = entry
    self._history:add_pending_queue_entry(mode, text, expanded, entry.image_count)
    Notify.info("Queued message for after compaction")
end

---@param will_retry boolean
function Chat:flush_compaction_queue(will_retry)
    if #self._compaction_queue == 0 then
        return
    end

    local queued = self._compaction_queue
    self._compaction_queue = {}

    if will_retry then
        for _, entry in ipairs(queued) do
            self:_ensure_pending_compaction_entry(entry)
            self:_remember_flushed_queue_entry(entry)
            self:_send_compaction_entry(entry, entry.mode)
        end
        return
    end

    local first = table.remove(queued, 1)
    if first then
        self._history:remove_pending_queue_entry(first.expanded)
        self._history:add_user_message(first.text, nil, first.image_count)
        self:_send_compaction_entry(first, "prompt")
    end

    for _, entry in ipairs(queued) do
        self:_ensure_pending_compaction_entry(entry)
        self:_send_compaction_entry(entry, entry.mode)
    end
end

--- Get the prompt-history store for this chat, honoring config. Returns nil
--- when history is disabled so callers can no-op.
---@return pi.PromptHistoryStore?
function Chat:_history_store()
    local cfg = Config.options.prompt and Config.options.prompt.history
    if not cfg or cfg.enabled == false then
        return nil
    end
    if not self._prompt_history then
        self._prompt_history = PromptHistory.get({ max = cfg.max, path = cfg.path })
    end
    return self._prompt_history
end

--- Current prompt buffer text (untrimmed; used as the draft to stash).
---@return string
function Chat:_prompt_draft()
    local buf = self._prompt:buf()
    if not vim.api.nvim_buf_is_valid(buf) then
        return ""
    end
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- Replace the prompt buffer text (e.g. with a recalled history entry) and move
--- the cursor to the end. Sets `_applying_history` so the manual-edit reset
--- autocmd ignores this programmatic change.
---@param text string
function Chat:_set_prompt_draft(text)
    local buf = self._prompt:buf()
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    -- Record what we are about to write so the TextChangedI reset-autocmd can
    -- tell this programmatic edit apart from a manual one (see the autocmd).
    self._last_applied_prompt = text
    -- Defer the buffer edit: <expr> mappings (e.g. <Up>/<Down>) must not
    -- modify the buffer while their expression is being evaluated, or Neovim
    -- silently drops the change. Scheduling is harmless for the plain
    -- <C-p>/<C-n> mappings too.
    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local lines = vim.split(text, "\n", { plain = true })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        local win = self._prompt:win()
        if win then
            local row = math.max(#lines, 1)
            local col = #(lines[row] or "")
            pcall(vim.api.nvim_win_set_cursor, win, { row, col })
        end
    end)
end

--- Recall the previous (older) prompt into the prompt buffer.
---@return boolean handled
function Chat:history_prev()
    local store = self:_history_store()
    if not store then
        return false
    end
    local entry = store:prev(self:_prompt_draft())
    if entry == nil then
        return false
    end
    self:_set_prompt_draft(entry)
    return true
end

--- Recall the next (newer) prompt, restoring the draft at the present.
---@return boolean handled
function Chat:history_next()
    local store = self:_history_store()
    if not store then
        return false
    end
    local entry = store:next()
    if entry == nil then
        return false
    end
    self:_set_prompt_draft(entry)
    return true
end

--- Open the file referenced on the history line under the cursor (in an editor
--- window, never a π panel). Returns true when a file was opened.
---@return boolean
function Chat:goto_path_at_cursor()
    return self._history:goto_path_at_cursor()
end

--- Send the current prompt contents as a message.
--- When queue_type is set, the message is added to the pending queue (virtual text)
--- instead of the chat history. It moves to the history when `message_start` arrives.
---@param queue_type "steer"|"follow_up"|nil
function Chat:_send_message(queue_type)
    local text = self._prompt:text()

    -- Direct bash execution (! prefix) runs immediately, independent of
    -- streaming/queue state — mirroring the pi TUI. "!!" excludes the
    -- command's output from the LLM context.
    if text:match("^!") then
        local exclude = text:match("^!!") ~= nil
        local command = vim.trim(text:sub(exclude and 3 or 2))
        if command ~= "" then
            self:_send_bash(text, command, exclude)
            return
        end
    end

    -- Local controls mirror agent-client's built-in slash commands. Backend
    -- extension, prompt, and skill commands continue through the normal RPC path.
    if require("pi.slash_commands").execute(text) then
        self._prompt:clear_text()
        return
    end

    -- A bare "/tree" opens the session-tree navigator locally instead of
    -- being sent as a prompt (mirrors the TUI's built-in /tree command).
    if text == "/tree" then
        self._prompt:clear_text()
        require("pi.tree").open()
        return
    end

    if text == "" and self._attachments:count() == 0 then
        return
    end

    -- Record the raw prompt in readline-style history (before mention expansion).
    local hist_store = self:_history_store()
    if hist_store and text ~= "" then
        hist_store:add(text)
    end

    -- Exit zen mode before sending so the user returns to normal chat.
    if self._zen:is_active() then
        self._zen:exit()
    end

    self._prompt:clear_text()

    local attachments = self._attachments:count() > 0 and self._attachments:get() or nil
    self._attachments:clear()

    local expanded = Mentions.expand(text)

    if queue_type then
        -- Queued message: show in pending area, render in history on delivery
        self._history:add_pending_queue_entry(queue_type, text, expanded, attachments and #attachments or nil)
    else
        -- Immediate: render in history now
        self._history:add_user_message(text, nil, attachments and #attachments or nil)
    end

    ---@type pi.RpcCommand
    local cmd
    if queue_type == "steer" then
        cmd = { type = "steer", message = expanded }
    elseif queue_type == "follow_up" then
        cmd = { type = "follow_up", message = expanded }
    else
        cmd = { type = "prompt", message = expanded }
    end
    if attachments and #attachments > 0 then
        cmd.images = attachments
    end

    self._agent.send(cmd)
end

--- Execute a direct bash command (! prefix) via the RPC `bash` command.
--- Output streams into a dedicated history block via bash_execution_update
--- events; the response completes the block.
---@param raw_text string original prompt text (recorded in prompt history)
---@param command string command with the !/!! prefix stripped
---@param exclude boolean exclude the output from the LLM context (!! prefix)
function Chat:_send_bash(raw_text, command, exclude)
    if self._bash_running then
        Notify.warn("A bash command is already running. Press <Esc> to cancel it first.")
        return
    end

    local hist_store = self:_history_store()
    if hist_store then
        hist_store:add(raw_text)
    end

    if self._zen:is_active() then
        self._zen:exit()
    end

    if self._attachments:count() > 0 then
        Notify.warn("Attachments are not supported with bash commands; discarding them")
        self._attachments:clear()
    end

    self._prompt:clear_text()

    self._bash_req_counter = self._bash_req_counter + 1
    local req_id = self._tab .. ":bash:" .. self._bash_req_counter
    self._bash_running = true
    self._bash_req_id = req_id

    self._history:on_bash_start(req_id, command, exclude)
    self:set_status({ type = "agent", text = "Running…" })

    ---@type pi.RpcCommand
    local cmd = { type = "bash", id = req_id, command = command }
    if exclude then
        cmd.excludeFromContext = true
    end
    local sent = self._agent.send(cmd, function(res)
        vim.schedule(function()
            self:_on_bash_response(req_id, res)
        end)
    end)
    if not sent then
        self:_on_bash_response(req_id, { type = "response", success = false, error = "Process not running" })
    end
end

--- Complete the bash block for req_id from the RPC response.
---@param req_id string
---@param res pi.RpcEvent
function Chat:_on_bash_response(req_id, res)
    if self._bash_req_id == req_id then
        self._bash_running = false
        self._bash_req_id = nil
    end
    if res.success == false then
        self._history:on_bash_end(req_id, { error = res.error or "Bash command failed" })
    else
        self._history:on_bash_end(req_id, res.data or {})
    end
    if not self._streaming and not self._compacting then
        self:set_status(nil)
    end
end

--- Stream a bash_execution_update chunk into the bash block.
---@param id string?
---@param delta string
function Chat:on_bash_update(id, delta)
    if type(id) ~= "string" then
        return
    end
    self._history:on_bash_output(id, delta)
end

--- Render a bashExecution message from session replay.
---@param msg table
function Chat:on_bash_replay(msg)
    self._history:on_bash_replay(msg)
end

---@return string?
function Chat:active_verb()
    return self._active_verb
end

---@param status pi.Status?
function Chat:set_status(status)
    self._history:set_status(status)
end

---@param msg string
---@param timestamp? number
---@param image_count? integer
function Chat:add_user_message(msg, timestamp, image_count)
    self._history:add_user_message(msg, timestamp, image_count)
end

---@param replaying boolean
function Chat:set_replaying(replaying)
    self._history._replaying = replaying
    -- Pause render-markdown while replaying: it would otherwise re-render the
    -- whole buffer on every edit (hundreds of edits during a large session
    -- load), which is O(n^2) and hangs loading. On completion, re-enable and
    -- render once.
    local buf = self._history:buf()
    if replaying then
        Render.pause_history(buf)
    else
        Render.resume_history(buf)
    end
end

--- Finish asynchronous replay writes, then reveal the final message once.
function Chat:finish_replaying()
    vim.schedule(function()
        self:set_replaying(false)
        self._history:scroll_to_bottom()
    end)
end

---@param timestamp? number
function Chat:on_agent_start(timestamp)
    self._streaming = true
    -- The retry backoff is over: this is a real streaming run again, so the
    -- abort gesture must target the run (abort), not the backoff (abort_retry).
    self._retrying = false
    self._last_turn_stop_reason = nil
    self:_clear_aborted_notice()
    self._assistant_block_open = false
    self._assistant_message_header_rendered = false
    self._assistant_tool_only_header_rendered = false
    self._assistant_message_timestamp = timestamp
    local verbs = Config.random_verbs()
    self._active_verb = verbs[1]
    self._done_verb = verbs[2]
    self:set_status({ type = "agent", text = verbs[1] .. "…" })
end

function Chat:_ensure_assistant_block_open()
    if self._assistant_block_open then
        self._assistant_message_header_rendered = true
        return
    end
    self._history:on_agent_start(self._assistant_message_timestamp)
    self._assistant_block_open = true
    self._assistant_message_header_rendered = true
end

---@param delta string
function Chat:on_text_delta(delta)
    if not self._assistant_block_open and not delta:match("%S") then
        return
    end
    self:_ensure_assistant_block_open()
    self._assistant_tool_only_header_rendered = false
    self._history:on_text_delta(delta)
end

---@param entries pi.PendingQueueEntry[]
---@param text string
---@return pi.PendingQueueEntry?
function Chat:_remove_queue_entry(entries, text)
    for i, entry in ipairs(entries) do
        if entry.expanded_text == text then
            return table.remove(entries, i)
        end
    end
    return nil
end

---@param text string
---@return pi.PendingQueueEntry?
function Chat:_remove_flushed_queue_entry(text)
    return self:_remove_queue_entry(self._flushed_queue_entries, text)
end

---@param text string
---@return pi.PendingQueueEntry?
function Chat:_remove_replay_flushed_queue_entry(text)
    return self:_remove_queue_entry(self._replay_flushed_queue_entries, text)
end

function Chat:preserve_flushed_queue_for_rebuild()
    self._replay_flushed_queue_entries = { unpack(self._flushed_queue_entries) }
end

function Chat:clear_for_compaction_rebuild()
    self:preserve_flushed_queue_for_rebuild()
    local replay_flushed_queue_entries = self._replay_flushed_queue_entries
    local compaction_queue = self._compaction_queue
    self:clear()
    self._compacting = true
    self._replay_flushed_queue_entries = replay_flushed_queue_entries
    self._compaction_queue = compaction_queue
end

function Chat:on_agent_end()
    self._streaming = false
    self:_disarm_abort_esc()
    self._assistant_block_open = false
    self._assistant_message_header_rendered = false
    self._assistant_tool_only_header_rendered = false
    self._assistant_message_timestamp = nil
    -- Flush any remaining pending queue entries into the history.
    -- Normally they are moved on message_start, but if the agent ends
    -- without delivering them (e.g. abort), render them now so they
    -- don't silently vanish.
    local pending_queue = self._history:get_pending_queue()
    for _, entry in ipairs(pending_queue) do
        self:_remember_flushed_queue_entry(entry)
        self._history:add_user_message(entry.text, nil, entry.image_count, entry.queue_type)
    end
    self._history:clear_pending_queue()

    local stop_reason = self._last_turn_stop_reason
    local completion_text = self._done_verb
    local force_completion = false
    if stop_reason == "aborted" then
        completion_text = "Aborted"
        force_completion = true
    elseif stop_reason == "error" then
        completion_text = "Failed"
        force_completion = true
    end

    self._active_verb = nil
    self._done_verb = nil
    self._last_turn_stop_reason = nil

    self._history:on_agent_end(completion_text, { force_completion = force_completion, stop_reason = stop_reason })
    self:set_status(nil)

    -- Clear, eye-catching confirmation that the turn was aborted.
    if stop_reason == "aborted" then
        self:_show_aborted_notice()
    end

    if not self:has_prompt_focus() then
        local attention_config = Config.options.attention
        if attention_config and attention_config.notify_on_completion then
            Attention.notify(self._tab, "Agent finished - waiting for your input", vim.log.levels.INFO)
        end
    end
end

--- Handle queue_update events: reconcile the pending queue display with
--- pi's authoritative queue state (steer/follow-up queues). Payload shape:
--- `{ steering: string[], followUp: string[] }` (expanded message texts).
---@param msg pi.RpcEvent
function Chat:on_queue_update(msg)
    -- Treat compaction as active: compaction-held entries are displayed in
    -- the pending queue but only sent to pi after compaction ends, so pi's
    -- payload legitimately lacks them until then.
    self._history:sync_pending_queue(msg.steering, msg.followUp, self._streaming or self._compacting)
end

--- Handle message_start events. When a user message arrives and matches
--- a pending queue entry, move it from the queue into the chat history.
---@param msg pi.RpcEvent
function Chat:on_message_start(msg)
    local message = msg.message
    if not message then
        return
    end

    if message.role == "user" then
        -- Extract text and attachments from the user message content
        local text = ""
        local image_count = 0
        if type(message.content) == "string" then
            text = message.content
        elseif type(message.content) == "table" then
            for _, part in ipairs(message.content) do
                if type(part) == "string" then
                    text = text .. part
                elseif type(part) == "table" and part.type == "text" then
                    text = text .. (part.text or "")
                elseif type(part) == "table" and part.type == "image" then
                    image_count = image_count + 1
                end
            end
        end
        local entry = self._history:remove_pending_queue_entry(text) or self:_remove_replay_flushed_queue_entry(text)
        if entry then
            self._history:add_user_message(
                entry.text,
                nil,
                image_count > 0 and image_count or entry.image_count,
                entry.queue_type
            )
            self:_remove_flushed_queue_entry(text)
        else
            self:_remove_flushed_queue_entry(text)
        end
    elseif message.role == "assistant" then
        self._assistant_block_open = false
        self._assistant_message_header_rendered = false
        self._assistant_message_timestamp = message.timestamp
    end
end

--- Handle message_end events.  When an assistant message ends with
--- stopReason "aborted" or "error", mark all pending tool blocks as
--- errored so they don't hang open forever.
--- Also updates status line context usage from assistant message usage.
---@param msg pi.RpcEvent
function Chat:on_message_end(msg)
    local message = msg.message
    if not message or message.role ~= "assistant" then
        return
    end

    local stop = message.stopReason

    -- Accumulate usage stats (skip aborted/errored messages —
    -- they may have zero or stale usage, matching TUI's estimateContextTokens).
    if stop ~= "aborted" and stop ~= "error" and type(message.usage) == "table" then
        self._prompt:statusline():add_usage(message.usage)
    end

    if stop == "aborted" or stop == "error" then
        self._last_turn_stop_reason = stop

        local error_message
        if stop == "aborted" then
            error_message = "[aborted] Operation aborted"
        else
            error_message = message.errorMessage or "Error"
        end
        self._history:mark_pending_tools_errored(error_message)

        local has_tool_calls = false
        if type(message.content) == "table" then
            for _, part in ipairs(message.content) do
                if type(part) == "table" and part.type == "toolCall" then
                    has_tool_calls = true
                    break
                end
            end
        end
        if stop == "error" and not has_tool_calls then
            self._history:on_error(error_message)
        end
    end
    self._assistant_block_open = false
end

--- Update status line state (model, thinking level) from get_state response.
---@param data table
function Chat:update_state(data)
    self._prompt:statusline():update_state(data)
end

--- Accumulate usage stats on the status line (e.g. after session replay).
---@param usage table
function Chat:add_usage(usage)
    self._prompt:statusline():add_usage(usage)
end

--- Set or clear an extension status value on the status line.
---@param key string
---@param value string? nil to clear
function Chat:set_extension_status(key, value)
    self._prompt:statusline():set_extension_status(key, value)
end

--- Render a custom block inline in the chat history.
---@param block pi.CustomBlock
function Chat:append_custom_block(block)
    self._history:append_custom_block(block)
end

---@param summary string
---@param tokens_before integer
function Chat:append_compaction_summary(summary, tokens_before)
    self._history:append_compaction_summary(summary, tokens_before)
end

--- Re-render the prompt status line.
function Chat:render_statusline()
    self._prompt:statusline():render()
end

--- Refresh prompt title styling when attention state changes.
function Chat:refresh_prompt_attention()
    self._layout:refresh_prompt_attention(require("pi.attention").has_attention(self._tab))
end

--- Reset status line usage stats (new session / clear).
function Chat:reset_usage()
    self._prompt:statusline():reset_usage()
end

---@param opts { sections: pi.StartupSection[], errors?: pi.SystemErrorEntry[] }
function Chat:show_startup_block(opts)
    self._history:show_startup_block(opts)
end

function Chat:clear_placeholder()
    self._history:clear_placeholder()
end

---@param error_message string
---@param opts? pi.ChatErrorOpts
function Chat:on_error(error_message, opts)
    self._history:on_error(error_message, opts)
end

---@param error_message string
---@param opts? pi.ChatErrorOpts
function Chat:on_system_error(error_message, opts)
    self._history:on_system_error(error_message, opts)
end

---@param tool_name string
---@param tool_call_id string
---@param tool_input? table
function Chat:on_tool_start(tool_name, tool_call_id, tool_input)
    if not self._assistant_message_header_rendered and not self._assistant_tool_only_header_rendered then
        self:_ensure_assistant_block_open()
        self._assistant_tool_only_header_rendered = true
    end
    self._history:on_tool_start(tool_name, tool_call_id, tool_input)
end

---@param tool_name string
---@param tool_call_id string
---@param result? table
---@param is_error? boolean
function Chat:on_tool_end(tool_name, tool_call_id, result, is_error)
    self._history:on_tool_end(tool_name, tool_call_id, result, is_error)
end

---@param tool_name string
---@param tool_call_id string
---@param msg table
function Chat:on_tool_update(tool_name, tool_call_id, msg)
    self._history:on_tool_update(tool_name, tool_call_id, msg)
end

---@param opts? { unmeasured?: boolean }
function Chat:on_thinking_start(opts)
    self._history:on_thinking_start(opts)
end

---@param delta string
function Chat:on_thinking_delta(delta)
    self._history:on_thinking_delta(delta)
end

function Chat:on_thinking_end()
    self._history:on_thinking_end()
end

function Chat:toggle_thinking()
    self._history:toggle_thinking()
end

--- Toggle the startup block between compact and expanded.
---@param check_cursor? boolean default true; false skips cursor check (for commands)
---@return boolean toggled
function Chat:toggle_startup_block(check_cursor)
    return self._history:toggle_startup_block(check_cursor)
end

--- Toggle all expandable history blocks
---@return boolean changed
function Chat:toggle_history_blocks()
    return self._history:toggle_blocks_expanded()
end

function Chat:clear()
    self._streaming = false
    self._retrying = false
    self:_disarm_abort_esc()
    self:_clear_aborted_notice()
    self._bash_running = false
    self._bash_req_id = nil
    self._compacting = false
    self._assistant_block_open = false
    self._assistant_message_header_rendered = false
    self._assistant_tool_only_header_rendered = false
    self._assistant_message_timestamp = nil
    self._flushed_queue_entries = {}
    self._replay_flushed_queue_entries = {}
    self._compaction_queue = {}
    self._active_verb = nil
    self._done_verb = nil
    self._last_turn_stop_reason = nil
    self._history:clear()
    self._prompt:statusline():reset_usage()
end

--- Scroll the history window by a number of lines.
---@param direction "up"|"down"
---@param lines? integer lines to scroll (default 15)
function Chat:scroll_history(direction, lines)
    self._history:scroll(direction, lines)
end

--- Scroll the history window to the bottom (most recent message).
function Chat:scroll_history_to_bottom()
    self._history:scroll_to_bottom()
end

--- Scroll the history window to the first agent response in the latest user turn.
function Chat:scroll_history_to_first_agent_response()
    self._history:scroll_to_first_agent_response()
end

--- Scroll the history window to the last agent response in the latest user turn.
function Chat:scroll_history_to_last_agent_response()
    self._history:scroll_to_last_agent_response()
end

---@param path string
---@return boolean
function Chat:attach_image(path)
    return self._attachments:add_file(path)
end

---@return boolean
function Chat:attach_from_clipboard()
    return self._attachments:add_from_clipboard()
end

return Chat
