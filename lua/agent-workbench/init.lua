--- Agent Workbench public API.

---@class AgentWorkbench
local M = {}

local Config = require("agent-workbench.config")

local is_initialized = false

---@param chat agent_workbench.Chat
---@param mode? agent_workbench.LayoutMode
local function show_chat(chat, mode)
    if mode and chat:layout() ~= mode then
        chat:set_layout(mode)
        chat:focus_prompt()
    else
        chat:ensure_shown_and_focus_prompt()
    end
end

---@param opts? agent_workbench.Options
function M.setup(opts)
    Config.setup(opts)

    if is_initialized then
        return
    end

    is_initialized = true

    vim.treesitter.language.register("markdown", require("agent-workbench.filetypes").history)
    require("agent-workbench.ui.highlights").setup()
    require("agent-workbench.attention").setup_autocmds()
    require("agent-workbench.sessions.manager").setup_autocmds()
    require("agent-workbench.ui.workspaces").setup()
    require("agent-workbench.ui.workspace_sidebar").setup()
    require("agent-workbench.workspace_buffers").setup()
    require("agent-workbench.commands").setup()
    require("agent-workbench.ui.winfix").setup()
    require("agent-workbench.paste").setup()
end

--- Show the chat and focus the prompt. Creates a session if none exists.
---@param opts? agent_workbench.SessionCreateOpts
function M.show(opts)
    local Sessions = require("agent-workbench.sessions.manager")
    local existing = Sessions.get()
    if existing then
        show_chat(existing.chat, opts and opts.layout or nil)
        return
    end

    local session = Sessions.get_or_create(opts)
    if session then
        session.chat:ensure_shown_and_focus_prompt()
    end
end

--- Toggle the chat. If a layout is given and the chat is visible in another
--- layout, switch to that layout instead of hiding. Creates a session if none exists.
---@param opts? agent_workbench.SessionCreateOpts
function M.toggle(opts)
    local Sessions = require("agent-workbench.sessions.manager")
    local existing = Sessions.get()
    if not existing then
        local session = Sessions.get_or_create(opts)
        if session then
            session.chat:ensure_shown_and_focus_prompt()
        end
        return
    end

    local requested_layout = opts and opts.layout or nil
    if existing.chat:is_visible() then
        if requested_layout and existing.chat:layout() ~= requested_layout then
            existing.chat:set_layout(requested_layout)
            existing.chat:focus_prompt()
        else
            existing.chat:hide()
        end
        return
    end

    show_chat(existing.chat, requested_layout)
end

--- Continue the most recent session for the current cwd.
---@param opts? agent_workbench.SessionCreateOpts
function M.continue_session(opts)
    require("agent-workbench.sessions.manager").continue_session(opts)
end

--- Show a picker to resume a past session.
---@param opts? agent_workbench.SessionCreateOpts
function M.resume_session(opts)
    require("agent-workbench.sessions.manager").resume_session(opts)
end

--- Toggle chat visibility. No-op if no session exists.
function M.toggle_chat()
    local session = require("agent-workbench.sessions.manager").get()
    if not session then
        return
    end
    session.chat:toggle()
end

--- Toggle between buffer and float layout. No-op if no session exists.
--- If given, callback runs after pi has switched layouts, focused the new
--- prompt window, and requested insert mode.
---@param cb? fun(layout: agent_workbench.LayoutMode)
function M.toggle_layout(cb)
    local session = require("agent-workbench.sessions.manager").get()
    if not session then
        return
    end
    if cb then
        session.chat:toggle_layout(function()
            cb(session.chat:layout())
        end)
    else
        session.chat:toggle_layout()
    end
end

--- Check whether the chat is currently visible.
---@return boolean
function M.is_visible()
    local session = require("agent-workbench.sessions.manager").get()
    return session ~= nil and session.chat:is_visible()
end

--- Return the current chat layout mode.
--- Returns nil if no session is active.
---@return agent_workbench.LayoutMode?
function M.layout()
    local session = require("agent-workbench.sessions.manager").get()
    if not session then
        return nil
    end
    return session.chat:layout()
end

--- Abort the current agent operation.
function M.abort()
    local session = require("agent-workbench.sessions.manager").get()
    if session and session.rpc:is_running() then
        require("agent-workbench.attention").clear_session(session)
        session.rpc:send({ type = "abort" })
    end
end

--- Focus persistent local terminal used by !! prompt mode.
function M.focus_terminal()
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        session.chat:focus_terminal()
    end
end

--- Abort a running direct bash command (! prefix).
function M.abort_bash()
    local session = require("agent-workbench.sessions.manager").get()
    if session and session.rpc:is_running() then
        session.rpc:send({ type = "abort_bash" })
    end
end

--- Cancel an in-progress auto-retry backoff (the "Retrying…" state). Only
--- takes effect while the core is between retry attempts; the retry is
--- cancelled and the failed turn ends. Sent by the double-<Esc> abort gesture
--- during the retry window.
function M.abort_retry()
    local session = require("agent-workbench.sessions.manager").get()
    if session and session.rpc:is_running() then
        session.rpc:send({ type = "abort_retry" })
    end
end

--- Stop the process and close the chat.
function M.stop()
    require("agent-workbench.sessions.manager").stop()
end

--- Open the next queued π attention request.
---@return boolean opened
function M.attention()
    return require("agent-workbench.attention").open_next()
end

--- Count active attention requests for a tab.
--- Pass nil or 0 for the current tab.
---@param tab? agent_workbench.TabId|0
---@return integer
function M.attention_count(tab)
    return require("agent-workbench.attention").count(tab)
end

--- Count active attention requests across all tabs.
---@return integer
function M.attention_total()
    return require("agent-workbench.attention").total_count()
end

--- Return a snapshot of the current attention state.
---@param current_tab? agent_workbench.TabId|0
---@return agent_workbench.AttentionState
function M.attention_state(current_tab)
    return require("agent-workbench.attention").state(current_tab)
end

---@param tab? agent_workbench.TabId|0
---@return boolean
function M.has_attention(tab)
    return require("agent-workbench.attention").has_attention(tab)
end

--- Start a new conversation in the current session.
function M.new_session()
    require("agent-workbench.sessions.manager").new_session()
end

--- Navigate the session tree (:AgentWorkbenchTree): pick a past conversation point and
--- move the session leaf to it, optionally summarizing the abandoned branch.
function M.tree()
    require("agent-workbench.tree").open()
end

--- Toggle the sessions overview list (:AgentWorkbenchSessions): a live list of all
--- active sessions with their display name and status (busy/idle/attention).
--- One shared buffer; each tab opens its own window on it.
function M.sessions()
    require("agent-workbench.ui.sessions").toggle()
end

--- Select a tab-backed workspace.
function M.workspaces()
    require("agent-workbench.ui.workspaces").select()
end

--- Toggle the workspace explorer sidebar.
function M.workspace_sidebar()
    require("agent-workbench.ui.workspace_sidebar").toggle()
end

--- Create a tab-backed workspace after prompting for its cwd.
function M.new_workspace()
    require("agent-workbench.ui.workspaces").create()
end

--- Return workspace rows in tabline order.
---@return agent_workbench.WorkspaceRow[]
function M.workspace_list()
    return require("agent-workbench.ui.workspaces").list()
end

--- Render built-in workspace tabline content.
---@return string
function M.workspace_tabline()
    return require("agent-workbench.ui.workspaces").tabline()
end

--- Move current buffer to another tab-backed workspace.
---@param workspace integer
---@return boolean
function M.move_buffer(workspace)
    return require("agent-workbench.workspace_buffers").move_current(workspace)
end

--- Review every file changed by the current session (:AgentWorkbenchDiff): a floating
--- window with the combined `git diff` of the session's changed files.
--- Untracked files render as full-file additions; <CR>/o jumps to the file
--- and line under the cursor, q closes.
function M.diff_review()
    require("agent-workbench.ui.diff_review").open()
end

--- Toggle thinking block visibility.
function M.toggle_thinking()
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        require("agent-workbench.thinking").toggle(session)
    end
end

--- Toggle the startup block between compact and expanded.
function M.toggle_startup_details()
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        session.chat:toggle_startup_block(false)
    end
end

--- Toggle all expandable history blocks.
---@return boolean changed
function M.toggle_history_blocks()
    local session = require("agent-workbench.sessions.manager").get()
    if not session then
        return false
    end
    return session.chat:toggle_history_blocks()
end

--- Cycle to the next thinking level.
function M.cycle_thinking_level()
    local session = require("agent-workbench.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        require("agent-workbench.notify").warn("No active session")
        return
    end
    require("agent-workbench.thinking").cycle(session)
end

--- Select a thinking level from a picker.
function M.select_thinking_level()
    local session = require("agent-workbench.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        require("agent-workbench.notify").warn("No active session")
        return
    end
    require("agent-workbench.thinking").select(session)
end

--- Cycle to the next model.
--- If `models` is configured, cycles within the resolved subset.
function M.cycle_model()
    local session = require("agent-workbench.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        require("agent-workbench.notify").warn("No active session")
        return
    end
    require("agent-workbench.models").cycle(session)
end

--- Select a model from configured models (or all if none configured).
--- Uses Dialog.select for the curated list.
function M.select_model()
    local session = require("agent-workbench.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        require("agent-workbench.notify").warn("No active session")
        return
    end
    require("agent-workbench.models").select(session)
end

--- Select a model from all available models using vim.ui.select (searchable).
function M.select_model_all()
    local session = require("agent-workbench.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        require("agent-workbench.notify").warn("No active session")
        return
    end
    require("agent-workbench.models").select_all(session)
end

--- Send an @-mention to the prompt.
--- With no args or command args: mentions current buffer (with visual selection if any).
--- With a loc table: mentions the given path and optional line range.
---@param args? table|{ path: string, start_line?: integer, end_line?: integer }
---@param opts? { focus?: boolean } default: focus = true
function M.send_mention(args, opts)
    local Mentions = require("agent-workbench.ui.chat.mentions")
    if args and args.path then
        Mentions.send(args, opts)
    else
        Mentions.send_current(args, opts)
    end
end

--- Attach an image file to the prompt.
---@param path string
---@return boolean
function M.attach_image(path)
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        return session.chat:attach_image(path)
    end
    return false
end

--- Paste an image from clipboard as an attachment.
---@return boolean
function M.paste_image()
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        local in_prompt = vim.bo.filetype == require("agent-workbench.filetypes").prompt
        local cursor = in_prompt and vim.api.nvim_win_get_cursor(0) or nil
        local ok = session.chat:attach_from_clipboard()
        if ok and cursor then
            vim.schedule(function()
                pcall(vim.api.nvim_win_set_cursor, 0, cursor)
                vim.cmd("startinsert")
            end)
        end
        return ok
    end
    return false
end

--- Manually compact conversation context.
---@param custom_instructions? string optional instructions to guide compaction
function M.compact(custom_instructions)
    local Notify = require("agent-workbench.notify")
    local session = require("agent-workbench.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        Notify.warn("No active session")
        return
    end
    if session.chat:is_streaming() then
        Notify.warn("Cannot compact while streaming")
        return
    end
    if session.chat:is_compacting() then
        Notify.warn("Compaction is already running")
        return
    end

    session.chat:set_compacting(true)
    session.chat:set_status({ type = "compaction" })

    ---@type table
    local cmd = { type = "compact" }
    if custom_instructions and custom_instructions ~= "" then
        cmd.customInstructions = custom_instructions
    end

    local sent = session.rpc:send(cmd, function(res)
        vim.schedule(function()
            if not res.success then
                session.chat:set_compacting(false)
                session.chat:set_status(nil)
                Notify.error("Compaction failed: " .. (res.error or "unknown error"))
            end
        end)
    end)
    if not sent then
        session.chat:set_compacting(false)
        session.chat:set_status(nil)
    end
end

--- Toggle automatic context compaction.
--- Reads the backend's current setting via get_state, then sends
--- set_auto_compaction with the inverted value. On success the statusline is
--- refreshed so its `compaction` component (`(auto)`) reflects the new state.
--- Session-level state is held by the backend, so there is no new config
--- option. Silent no-op when there is no active session.
function M.toggle_auto_compaction()
    local Sessions = require("agent-workbench.sessions.manager")
    local session = Sessions.get()
    if not session or not session.rpc:is_running() then
        return
    end
    session.rpc:send({ type = "get_state" }, function(res)
        if not res.success or not res.data or res.data.autoCompactionEnabled == nil then
            return
        end
        local enabled = not res.data.autoCompactionEnabled
        session.rpc:send({ type = "set_auto_compaction", enabled = enabled }, function(res2)
            if not res2.success then
                vim.schedule(function()
                    require("agent-workbench.notify").error(
                        "Toggle auto compaction failed: " .. (res2.error or "unknown error")
                    )
                end)
                return
            end
            vim.schedule(function()
                Sessions.refresh_state(session)
            end)
        end)
    end)
end

--- Set or show the session display name.
--- With no argument, shows the current name. With a name, sets it.
---@param name? string session name to set (nil to show current)
function M.set_session_name(name)
    local Notify = require("agent-workbench.notify")
    local Dialog = require("agent-workbench.ui.dialog")
    local session = require("agent-workbench.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        Notify.warn("No active session")
        return
    end

    if name and name ~= "" then
        session.rpc:send({ type = "set_session_name", name = name }, function(res)
            vim.schedule(function()
                if res.success then
                    Notify.info("Session name set: " .. name)
                else
                    Notify.error("Failed to set session name: " .. (res.error or "unknown error"))
                end
            end)
        end)
        return
    end

    -- No name provided — prompt for one, pre-filling with current name
    session.rpc:send({ type = "get_state" }, function(res)
        vim.schedule(function()
            if not res.success then
                Notify.error("Failed to get session state")
                return
            end
            Dialog.input({
                title = "Session Name",
                default = res.data and res.data.sessionName or "",
            }, function(value)
                if value and value ~= "" then
                    M.set_session_name(value)
                end
            end)
        end)
    end)
end

--- Toggle RPC debug logging.
function M.toggle_debug()
    require("agent-workbench.rpc").toggle_debug()
end

--- Show the current session's stats dashboard (:AgentWorkbenchSessionStats): identity,
--- message counts, token usage (with cache split), per-model cost breakdown
--- (via get_entries, port of the TUI's getUsageCostBreakdown), cache re-billed
--- waste, and context-window usage with a threshold-colored bar.
--- Silent no-op without an active session; a failed get_entries degrades to
--- the session-stats-only view.
function M.session_stats()
    local Sessions = require("agent-workbench.sessions.manager")
    local session = Sessions.get()
    if not session or not session.rpc:is_running() then
        return
    end

    local Stats = require("agent-workbench.stats")
    local Dialog = require("agent-workbench.ui.dialog")
    local Notify = require("agent-workbench.notify")

    local stats ---@type table?
    local breakdown ---@type agent_workbench.StatsCostEntry[]?
    local cache_waste ---@type agent_workbench.StatsCacheWaste?

    local function try_show()
        if stats == nil or breakdown == nil or cache_waste == nil then
            return
        end
        local rendered = Stats.render_stats(stats, breakdown, cache_waste)
        vim.schedule(function()
            Dialog.info({
                title = "Pi Session Stats",
                lines = rendered.lines,
                highlights = rendered.highlights,
            })
        end)
    end

    session.rpc:send({ type = "get_session_stats" }, function(res)
        vim.schedule(function()
            if not res.success then
                Notify.error("Failed to get session stats: " .. (res.error or "unknown error"))
                return
            end
            stats = res.data
            try_show()
        end)
    end)

    session.rpc:send({ type = "get_entries" }, function(res)
        vim.schedule(function()
            local entries = res.success and res.data and res.data.entries or {}
            breakdown = Stats.get_usage_cost_breakdown(entries)
            cache_waste = Stats.compute_cache_waste(entries)
            try_show()
        end)
    end)
end

--- Scroll the chat history by a number of lines.
--- Can be called from the prompt buffer to scroll without leaving it.
---@param direction "up"|"down"
---@param lines? integer lines to scroll (default 15)
function M.scroll_chat_history(direction, lines)
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        session.chat:scroll_history(direction, lines)
    end
end

--- Scroll the chat history to the bottom (most recent message).
function M.scroll_chat_history_to_bottom()
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        session.chat:scroll_history_to_bottom()
    end
end

--- Scroll the chat history to the first agent response in the latest user turn.
function M.scroll_chat_history_to_first_agent_response()
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        session.chat:scroll_history_to_first_agent_response()
    end
end

--- Scroll the chat history to the last agent response in the latest user turn.
function M.scroll_chat_history_to_last_agent_response()
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        session.chat:scroll_history_to_last_agent_response()
    end
end

--- Focus the chat history window.
function M.focus_chat_history()
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        session.chat:focus_history()
    end
end

--- Open the file referenced on the chat-history line under the cursor in an
--- editor window (never a π panel). Handles tool path lines, @mentions with an
--- optional #L<line>, and path:line. Returns true when a file was opened.
---@return boolean
function M.goto_file_under_cursor()
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        return session.chat:goto_path_at_cursor()
    end
    return false
end

--- Focus the chat prompt window.
function M.focus_chat_prompt()
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        session.chat:focus_prompt()
    end
end

--- Focus the chat attachments window.
function M.focus_chat_attachments()
    local session = require("agent-workbench.sessions.manager").get()
    if session then
        session.chat:focus_attachments()
    end
end

--- Invoke an extension command on the current session.
--- Accepts with or without leading "/" (e.g. "toggle-auto-accept" or "/toggle-auto-accept").
---@param command string
function M.invoke(command)
    local session = require("agent-workbench.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        require("agent-workbench.notify").warn("No active session")
        return
    end
    if command:sub(1, 1) ~= "/" then
        command = "/" .. command
    end
    session.rpc:send({ type = "prompt", message = command })
end

--- Return the list of file paths modified by edit/write tools during the current session.
--- Returns an empty table if no session is active or no files have been changed.
---@return string[]
function M.changed_files()
    local session = require("agent-workbench.sessions.manager").get()
    if not session then
        return {}
    end
    return vim.tbl_keys(session.changed_files)
end

return M
