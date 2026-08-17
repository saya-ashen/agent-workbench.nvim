---@alias agent_workbench.TabId integer Neovim tabpage handle

---@class agent_workbench.SessionAttention
---@field pending agent_workbench.AttentionEntry[]
---@field transition_seq? integer Hide queued entries with seq <= this while a session transition is in flight.

---@class agent_workbench.StartupAnnouncement
---@field lines string[]

---@class agent_workbench.SystemErrorEntry
---@field message string
---@field timestamp integer

---@class agent_workbench.ModelRef
---@field provider string
---@field id string

---@class agent_workbench.Session
---@field id integer
---@field tab agent_workbench.TabId Current or most recent view tab.
---@field history_buf? integer
---@field rpc agent_workbench.Rpc
---@field chat agent_workbench.Chat
---@field attention agent_workbench.SessionAttention
---@field workspace_tab agent_workbench.TabId Workspace tab that created this session.
---@field cwd string Workspace cwd used by its RPC process.
---@field session_file? string
---@field uri string
---@field pinned_model? agent_workbench.ModelRef Model selected in this session.
---@field startup_announcements table<string, agent_workbench.StartupAnnouncement> Extension startup data (keys ending with `:startup`) shown in the system preamble. Process-level: persists across session switches.
---@field system_errors agent_workbench.SystemErrorEntry[]
---@field changed_files table<string, true> Set of file paths modified by edit/write tools during the current session.
---@field _pending_file_change_args? table<string, table> Pending tool args by tool call id for file-changing tools.
---@field _compaction_rebuilding? boolean True while compacted messages are being fetched/replayed.
---@field _compaction_event_queue? agent_workbench.RpcEvent[] Events received while compacted messages are being fetched/replayed.
---@field _switching_session? boolean True until persisted messages are installed after switch_session.

---@class agent_workbench.SessionCreateOpts
---@field layout? agent_workbench.LayoutMode
---@field new? boolean Create a separate session even when current tab already has one.

local M = {}

local Rpc = require("agent-workbench.rpc")
local Chat = require("agent-workbench.ui.chat")
local Config = require("agent-workbench.config")
local Startup = require("agent-workbench.startup")
local Notify = require("agent-workbench.notify")
local Attention = require("agent-workbench.attention")
local Extension = require("agent-workbench.ui.extension")
local CommandsCache = require("agent-workbench.cache.commands")
local Workspace = require("agent-workbench.workspace")
local HistoryBuffer = require("agent-workbench.ui.chat.history")

---@type table<string, agent_workbench.ChatHistory>
local transcript_resources = {}

---@param session agent_workbench.Session
---@param uri string
---@return agent_workbench.ChatHistory
local function transcript_for(session, uri)
    local history = transcript_resources[uri]
    if history and vim.api.nvim_buf_is_valid(history:buf()) then
        return history
    end
    history = HistoryBuffer.new(session.id, uri)
    transcript_resources[uri] = history
    return history
end

---@class agent_workbench.StartupSection
---@field header string
---@field items string[]
---@field hl? string

---@param session agent_workbench.Session
---@param commands? agent_workbench.SlashCommand[]
local function show_startup_block(session, commands)
    local sections = Startup.build_startup_sections(session, commands)
    session.chat:show_startup_block({ sections = sections, errors = session.system_errors })
end

--- Fetch commands and render the startup block on a session's chat.
---@param session agent_workbench.Session
local function fetch_commands_and_show_startup_block(session)
    CommandsCache.fetch(session.rpc, function(commands)
        show_startup_block(session, commands)
    end)
end

---@type table<integer, agent_workbench.Session>
local sessions = {}
---@type table<integer, agent_workbench.Session>
local sessions_by_component = {}
---@type table<agent_workbench.TabId, agent_workbench.Session>
local active_by_tab = {}
local next_session_id = 0
local activating = false

---@return agent_workbench.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
end

---@return integer
local function current_buf()
    return vim.api.nvim_get_current_buf()
end

--- Events we've reviewed and deliberately choose not to handle.
--- turn_start/turn_end: TUI doesn't handle them; lifecycle is fully
--- covered by message_start / message_end / agent_end.
--- thinking_level_changed: pi.nvim refreshes state through command
--- callbacks; this is a redundant notification.
---@type table<string, true>
local ignored_events = {
    turn_start = true,
    turn_end = true,
    thinking_level_changed = true,
}

--- Lifecycle transitions the sessions overview (:AgentWorkbenchSessions) tracks. The
--- list module coalesces redraws and is a no-op while no list window is
--- visible, so this stays cheap on the hot path.
---@type table<string, true>
local sessions_list_events = {
    agent_start = true,
    agent_end = true,
    agent_settled = true,
    compaction_start = true,
    compaction_end = true,
    auto_compaction_start = true,
    auto_compaction_end = true,
    _process_exit = true,
}

---@type fun(session: agent_workbench.Session, result: table, will_retry: boolean)?
local rebuild_after_compaction
local load_session
local activate

---@type fun(session: agent_workbench.Session, flush_queue?: boolean, will_retry?: boolean)?
local finish_compaction_rebuild

---@param chat agent_workbench.Chat
local function restore_active_agent_status(chat)
    -- Compaction/retry cleanup can fire after agent_end (between turns).
    -- Only restore the spinner if an agent loop is still active.
    local active_verb = chat:active_verb()
    if active_verb then
        chat:set_status({ type = "agent", text = active_verb .. "…" })
    else
        chat:set_status(nil)
    end
end

---@param args any
---@return table?
local function normalize_tool_args(args)
    if type(args) == "table" then
        return args
    end
    if type(args) ~= "string" or args == "" then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, args)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

---@param args table?
---@return string?
local function get_changed_file_path(args)
    if type(args) ~= "table" then
        return nil
    end
    local path = args.path or args.file_path or args.filePath
    if type(path) == "string" and path ~= "" then
        return path
    end
    return nil
end

---@param session agent_workbench.Session
---@param args table?
local function track_changed_file(session, args)
    local path = get_changed_file_path(args)
    if path then
        session.changed_files[path] = true
    end
end

---@param session agent_workbench.Session
---@param tool_name string?
---@param tool_call_id string?
---@param args any
local function stash_file_tool_args(session, tool_name, tool_call_id, args)
    if (tool_name ~= "edit" and tool_name ~= "write") or type(tool_call_id) ~= "string" or tool_call_id == "" then
        return
    end
    local decoded = normalize_tool_args(args)
    if not decoded then
        return
    end
    session._pending_file_change_args = session._pending_file_change_args or {}
    session._pending_file_change_args[tool_call_id] = decoded
end

--- Fetch current state and update the status line.
---@param session agent_workbench.Session
function M.refresh_state(session)
    session.rpc:send({ type = "get_state" }, function(res)
        if res.success and res.data then
            vim.schedule(function()
                session.chat:update_state(res.data)
            end)
        end
    end)
end

--- Capture the backend's current model as this tab's pinned model.
---@param session agent_workbench.Session
---@param state table? get_state response data
local function capture_model_pin(session, state)
    local model = type(state) == "table" and state.model or nil
    if type(model) == "table" and type(model.provider) == "string" and type(model.id) == "string" then
        session.pinned_model = { provider = model.provider, id = model.id }
    end
end

--- Fetch current state, update the status line, and (re)capture the model pin.
--- Used where the backend's model is authoritative for this tab: session
--- creation (core resolves it from global settings) and session resume
--- (core restores it from the session file).
local function update_identity(session, state)
    if type(state) ~= "table" then
        return
    end
    if type(state.sessionFile) == "string" and state.sessionFile ~= "" then
        session.session_file = state.sessionFile
    end
    local old_uri = session.uri
    session.uri = Workspace.uri(session.cwd, session.session_file, session.id)
    local history = session.chat:history()
    if session.chat:set_history_name(session.uri) then
        transcript_resources[old_uri] = nil
        transcript_resources[session.uri] = history
    end
    if vim.api.nvim_buf_is_valid(session.history_buf) then
        vim.b[session.history_buf].pi_session_uri = session.uri
    end
end

---@param session agent_workbench.Session
local function refresh_state_and_pin(session)
    session.rpc:send({ type = "get_state" }, function(res)
        if res.success and res.data then
            vim.schedule(function()
                update_identity(session, res.data)
                capture_model_pin(session, res.data)
                session.chat:update_state(res.data)
            end)
        end
    end)
end

--- Central event handler for a session.
--- Route a raw RPC event into the session's chat and companion modules.
--- Exposed (not just local) so the retry/abort wiring is unit-testable with a
--- fake session; the RPC handler calls it for every decoded message.
---@param session agent_workbench.Session
---@param msg agent_workbench.RpcEvent
---@return boolean handled
function M.handle_event(session, msg)
    local t = msg.type
    local chat = session.chat

    if sessions_list_events[t] then
        require("agent-workbench.ui.sessions").request_refresh()
        require("agent-workbench.ui.workspace_sidebar").request_refresh()
        require("agent-workbench.ui.workspaces").refresh()
    end

    -- NOTE: This compaction-specific rebuild gate should become a small
    -- transaction helper if other session rebuild flows need event buffering.
    if session._compaction_rebuilding and t ~= "response" then
        if t == "_process_exit" and finish_compaction_rebuild then
            finish_compaction_rebuild(session, false)
        else
            session._compaction_event_queue = session._compaction_event_queue or {}
            session._compaction_event_queue[#session._compaction_event_queue + 1] = msg
            return true
        end
    end

    if t == "agent_start" then
        chat:on_agent_start()
        require("agent-workbench.ui.sessions").on_agent_start(session)
    elseif t == "agent_end" then
        chat:on_agent_end()
        require("agent-workbench.ui.sessions").on_agent_end(session)
        CommandsCache.refresh(session.rpc)
        M.refresh_state(session)
    elseif t == "agent_settled" then
        -- Authoritative end of the session-level run: pi emits this only after
        -- no retry, compaction retry, or queued continuation remains. The
        -- compaction/retry branches above restore state piecemeal; this is the
        -- final fallback that converges any leftover spinner.
        chat:set_status(nil)
    elseif t == "message_update" then
        local event = msg.assistantMessageEvent
        if event then
            if event.type == "thinking_start" then
                chat:on_thinking_start()
            elseif event.type == "thinking_delta" then
                chat:on_thinking_delta(event.delta or "")
            elseif event.type == "thinking_end" then
                chat:on_thinking_end()
            elseif event.type == "text_delta" then
                chat:on_thinking_end() -- no-op if not thinking
                chat:on_text_delta(event.delta or "")
            elseif event.type == "toolcall_end" then
                local tool_call = event.toolCall
                if type(tool_call) == "table" then
                    stash_file_tool_args(session, tool_call.name, tool_call.id, tool_call.arguments)
                end
                -- NOTE: Other sub-events stay intentionally ignored:
                --   toolcall_start/delta — we render on tool_execution_start.
                --   start, done — redundant with message_start/end.
                --   text_start, text_end — text_delta suffices.
            end
        end
    elseif t == "tool_execution_start" then
        local args = normalize_tool_args(msg.args) or msg.args
        chat:on_tool_start(msg.toolName or "tool", msg.toolCallId, args)
        -- Stash args for file-changing tools; tool_execution_end doesn't carry args.
        stash_file_tool_args(session, msg.toolName, msg.toolCallId, args)
        -- Stash search-tool args so the quickfix list can be titled with the pattern.
        require("agent-workbench.quickfix").on_tool_start(msg.toolName, msg.toolCallId, args)
    elseif t == "tool_execution_end" then
        chat:on_tool_end(msg.toolName or "tool", msg.toolCallId, msg.result, msg.isError)
        vim.schedule(function()
            require("agent-workbench.quickfix").on_tool_end(msg.toolName, msg.toolCallId, msg.result, msg.isError)
        end)
        if session._pending_file_change_args and not msg.isError then
            local args = session._pending_file_change_args[msg.toolCallId]
            track_changed_file(session, args)
            session._pending_file_change_args[msg.toolCallId] = nil
            local changed_path = get_changed_file_path(args)
            if changed_path then
                vim.schedule(function()
                    require("agent-workbench.reload").on_file_changed(changed_path)
                end)
            end
        end
    elseif t == "compaction_start" or t == "auto_compaction_start" then
        chat:set_compacting(true)
        chat:set_status({ type = "compaction" })
    elseif t == "compaction_end" or t == "auto_compaction_end" then
        if msg.aborted then
            chat:set_compacting(false)
            restore_active_agent_status(chat)
            chat:on_error("Compaction cancelled", { pad_top = true, pad_bottom = true })
            chat:flush_compaction_queue(msg.willRetry == true)
        elseif type(msg.errorMessage) == "string" and msg.errorMessage ~= "" then
            require("agent-workbench.ui.sessions").mark_error(session)
            chat:set_compacting(false)
            restore_active_agent_status(chat)
            chat:on_error(msg.errorMessage, { pad_top = true, pad_bottom = true })
            chat:flush_compaction_queue(msg.willRetry == true)
        elseif type(msg.result) == "table" and rebuild_after_compaction then
            rebuild_after_compaction(session, msg.result, msg.willRetry == true)
        else
            chat:set_compacting(false)
            restore_active_agent_status(chat)
            chat:flush_compaction_queue(msg.willRetry == true)
        end
    elseif t == "auto_retry_start" then
        chat:set_retrying(true)
        chat:set_status({ type = "agent", text = "Retrying…" })
    elseif t == "auto_retry_end" then
        chat:set_retrying(false)
        if msg.success == false then
            require("agent-workbench.ui.sessions").mark_error(session)
            chat:set_status(nil)
            chat:on_error(
                "Retry failed after "
                    .. tostring(msg.attempt or 0)
                    .. " attempts: "
                    .. (msg.finalError or "Unknown error"),
                { pad_top = true, pad_bottom = true }
            )
        else
            restore_active_agent_status(chat)
        end
    elseif t == "summarization_retry_scheduled" then
        -- Transient error while generating a compaction or branch summary.
        -- Compaction retries are already covered by the ongoing compaction
        -- status; branch summaries run while the agent is idle, so there is
        -- nothing to restore either way. Surface the error in debug mode only
        -- (on_error would render a scary red block for a transient hiccup).
        if Config.options.debug then
            vim.schedule(function()
                vim.notify(
                    "Summary retry scheduled (attempt "
                        .. tostring(msg.attempt or "?")
                        .. "/"
                        .. tostring(msg.maxAttempts or "?")
                        .. "): "
                        .. (msg.errorMessage or "unknown error"),
                    vim.log.levels.WARN,
                    { title = "pi" }
                )
            end)
        end
    elseif t == "summarization_retry_attempt_start" then
        if msg.source == "branchSummary" then
            -- navigateTree summarization runs while the agent is idle: show a
            -- lightweight busy state. Compaction-source retries keep the
            -- existing compaction status untouched.
            chat:set_status({ type = "summary", text = "Summarizing branch…" })
        end
    elseif t == "summarization_retry_finished" then
        -- Retry loop ended. During compaction, compaction_end restores the
        -- status; only the branchSummary state (agent idle) needs settling.
        if not chat:is_compacting() then
            restore_active_agent_status(chat)
        end
    elseif t == "extension_ui_request" then
        vim.schedule(function()
            Extension.handle(session, msg)
        end)
    elseif t == "session_info_changed" then
        require("agent-workbench.ui.sessions").on_session_info_changed(session, msg.name)
    elseif t == "extension_error" then
        local extension_path = type(msg.extensionPath) == "string" and msg.extensionPath or "unknown extension"
        local extension_event = type(msg.event) == "string" and msg.event or "unknown event"
        local error_message = type(msg.error) == "string" and msg.error or "Unknown error"
        local formatted = "Extension error ("
            .. vim.fn.fnamemodify(extension_path, ":~:.")
            .. ", "
            .. extension_event
            .. "):\n"
            .. error_message
        session.system_errors[#session.system_errors + 1] = {
            message = formatted,
            timestamp = os.time() * 1000,
        }
        chat:on_system_error(formatted, { pad_top = true, pad_bottom = true })
    elseif t == "_stderr" then
        if type(msg.message) == "string" and msg.message ~= "" then
            session.system_errors[#session.system_errors + 1] = {
                message = msg.message --[[@as string]],
                timestamp = os.time() * 1000,
            }
            chat:on_system_error(msg.message --[[@as string]], { pad_top = true, pad_bottom = true })
        end
    elseif t == "_process_exit" then
        vim.schedule(function()
            chat:set_status(nil)
            if Config.options.debug and msg.code ~= 0 and msg.code ~= 143 then
                print("Process exited with code " .. (msg.code or "-"))
            end
        end)
    elseif t == "response" then
        -- Normally handled by rpc:send() one-shot callbacks. Late error
        -- responses (e.g. async prompt failures like auth errors) arrive
        -- after the initial success response already consumed the callback.
        if msg.success == false and type(msg.error) == "string" then
            require("agent-workbench.ui.sessions").mark_error(session)
            chat:on_error(msg.error, { pad_top = true, pad_bottom = true })
        end
        return false
    elseif t == "message_start" then
        chat:on_message_start(msg)
    elseif t == "message_end" then
        chat:on_message_end(msg)
        require("agent-workbench.ui.sessions").on_message_end(session)
        local message = msg.message
        if type(message) == "table" and message.stopReason == "error" then
            require("agent-workbench.ui.sessions").mark_error(session)
        end
        if type(message) == "table" and message.role == "toolResult" and session._pending_file_change_args then
            local tool_call_id = message.toolCallId or message.toolUseId
            if type(tool_call_id) == "string" and tool_call_id ~= "" then
                if message.isError ~= true then
                    local args = session._pending_file_change_args[tool_call_id]
                    track_changed_file(session, args)
                end
                session._pending_file_change_args[tool_call_id] = nil
            end
        end
    elseif t == "tool_execution_update" then
        chat:on_tool_update(msg.toolName or "tool", msg.toolCallId, msg)
    elseif t == "queue_update" then
        chat:on_queue_update(msg)
    elseif t == "bash_execution_update" then
        chat:on_bash_update(msg.id, msg.delta or "")
    elseif ignored_events[t] then
        return true
    else
        Rpc.log_unhandled(t)
        return false
    end

    return true
end

---@param session agent_workbench.Session
---@param flush_queue? boolean default true
---@param will_retry? boolean
finish_compaction_rebuild = function(session, flush_queue, will_retry)
    local queued = session._compaction_event_queue or {}
    session._compaction_event_queue = {}
    session._compaction_rebuilding = false
    session.chat:set_compacting(false)
    restore_active_agent_status(session.chat)
    if flush_queue ~= false then
        session.chat:flush_compaction_queue(will_retry == true)
    end

    for i, queued_msg in ipairs(queued) do
        if session._compaction_rebuilding then
            local active_queue = session._compaction_event_queue or {}
            for j = i, #queued do
                active_queue[#active_queue + 1] = queued[j]
            end
            session._compaction_event_queue = active_queue
            return
        end
        M.handle_event(session, queued_msg)
    end
end

--- Get active session for current buffer or tab.
---@return agent_workbench.Session?
function M.get()
    return sessions_by_component[current_buf()] or active_by_tab[current_tab()]
end

---@param session agent_workbench.Session
---@return boolean
function M.is_current(session)
    return active_by_tab[current_tab()] == session
end

---@param tab? agent_workbench.TabId
---@return agent_workbench.Session?
function M.get_for_tab(tab)
    return active_by_tab[tab or current_tab()]
end

---@param id integer
---@return agent_workbench.Session?
function M.get_by_id(id)
    return sessions[id]
end

---@param session agent_workbench.Session
function M.activate(session)
    activate(session)
end

--- List all active sessions in creation order.
---@return agent_workbench.Session[]
function M.list()
    ---@type agent_workbench.Session[]
    local result = {}
    for _, session in pairs(sessions) do
        result[#result + 1] = session
    end
    ---@type table<agent_workbench.TabId, integer> visual position per tab
    local rank = {}
    for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
        rank[tab] = i
    end
    table.sort(result, function(a, b)
        local ar = rank[a.tab] or math.huge
        local br = rank[b.tab] or math.huge
        return ar == br and a.id < b.id or ar < br
    end)
    return result
end

---@param session agent_workbench.Session
local function register_components(session)
    session.history_buf = session.chat:history_buf()
    sessions_by_component[session.history_buf] = session
    sessions_by_component[session.chat:prompt_buf()] = session
    sessions_by_component[session.chat:attachments_buf()] = session
    vim.b[session.history_buf].pi_session_id = session.id
    vim.b[session.history_buf].pi_session_uri = session.uri
    require("agent-workbench.workspace_buffers").assign(session.history_buf, session.workspace_tab)
end

---@param session agent_workbench.Session
---@param history agent_workbench.ChatHistory
function M._rebind_history(session, history)
    local old_history = session.chat:history()
    local old_buf = session.history_buf
    local old_uri = session.uri
    if old_buf then
        sessions_by_component[old_buf] = nil
        Workspace.unregister(old_uri, old_buf)
        if vim.api.nvim_buf_is_valid(old_buf) then
            vim.b[old_buf].pi_session_id = nil
            vim.b[old_buf].pi_session_uri = nil
        end
    end
    if transcript_resources[old_uri] == old_history then
        transcript_resources[old_uri] = nil
    end
    local was_activating = activating
    activating = true
    local attached, attach_err = pcall(session.chat.attach_history, session.chat, history)
    activating = was_activating
    if not attached then
        error(attach_err, 0)
    end
    if old_buf then
        require("agent-workbench.workspace_buffers").unassign(old_buf, session.workspace_tab)
    end
    session.uri = history._name or session.uri
    session.history_buf = history:buf()
    transcript_resources[session.uri] = history
    sessions_by_component[session.history_buf] = session
    vim.b[session.history_buf].pi_session_id = session.id
    vim.b[session.history_buf].pi_session_uri = session.uri
    require("agent-workbench.workspace_buffers").assign(session.history_buf, session.workspace_tab)
end

---@param session agent_workbench.Session
activate = function(session)
    if activating or sessions[session.id] ~= session then
        return
    end
    activating = true
    local owner_tab = session.workspace_tab
    if owner_tab and vim.api.nvim_tabpage_is_valid(owner_tab) and owner_tab ~= current_tab() then
        -- Keep chat view takeover inside session's workspace. Background sessions
        -- must not rebind another workspace's windows when selected globally.
        vim.api.nvim_set_current_tabpage(owner_tab)
    end
    local tab = current_tab()
    local entered_history = current_buf() == session.history_buf
    local previous = active_by_tab[tab]
    session.tab = tab
    session.chat:set_tab(tab)
    active_by_tab[tab] = session

    if previous and previous ~= session and previous.chat:is_visible() then
        session.chat:takeover_view(previous.chat)
    elseif not session.chat:is_visible() then
        session.chat:show()
    end

    if entered_history then
        session.chat:focus_history()
    end

    require("agent-workbench.ui.sessions").clear_flags(session)
    activating = false
end

---@param session agent_workbench.Session
local function destroy_session(session)
    if sessions[session.id] ~= session then
        return
    end
    Attention.clear_session(session)
    session.chat:clear_prompt_request()
    session.chat:destroy()
    session.rpc:stop()
    if session.chat:is_visible() then
        session.chat:hide()
    end
    sessions[session.id] = nil
    sessions_by_component[session.history_buf] = nil
    sessions_by_component[session.chat:prompt_buf()] = nil
    sessions_by_component[session.chat:attachments_buf()] = nil
    for tab, active in pairs(active_by_tab) do
        if active == session then
            active_by_tab[tab] = nil
        end
    end
    require("agent-workbench.ui.sessions").request_refresh()
    require("agent-workbench.ui.workspace_sidebar").request_refresh()
    require("agent-workbench.ui.workspaces").refresh()
end

--- Get or create active session for current tab.
---@param opts? agent_workbench.SessionCreateOpts
---@return agent_workbench.Session?
function M.get_or_create(opts)
    opts = opts or {}

    local tab = current_tab()
    local workspace_cwd = Workspace.cwd(tab)
    local session = not opts.new and active_by_tab[tab] or nil
    if session then
        return session
    end

    next_session_id = next_session_id + 1
    local id = next_session_id
    local cwd = workspace_cwd
    local rpc = Rpc.new(id, cwd)

    if not rpc:start() then
        Notify.error("Failed to start process")
        return nil
    end

    local layout = opts.layout or Config.resolve_default_layout_mode()

    ---@type agent_workbench.ChatAgent
    local agent = {
        send = function(msg, callback)
            if session and session._switching_session then
                Notify.warn("Session is still loading; wait before sending")
                return false
            end
            return rpc:send(msg, callback)
        end,
    }

    local uri = Workspace.uri(cwd, nil, id)
    local chat = Chat.new(tab, layout, agent, uri, id, cwd)
    transcript_resources[uri] = chat:history()

    ---@type agent_workbench.Session
    session = {
        id = id,
        tab = tab,
        workspace_tab = tab,
        cwd = cwd,
        uri = uri,
        rpc = rpc,
        chat = chat,
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
        changed_files = {},
    }

    rpc:set_handler(function(msg)
        M.handle_event(session, msg)
    end)

    sessions[id] = session
    register_components(session)
    activate(session)
    require("agent-workbench.ui.sessions").request_refresh()
    require("agent-workbench.ui.workspace_sidebar").request_refresh()
    require("agent-workbench.ui.workspaces").refresh()

    -- Fetch available /commands for completion, highlighting, and system info
    fetch_commands_and_show_startup_block(session)

    -- Fetch initial state for status line (model, thinking level) and
    -- capture the initial model pin.
    refresh_state_and_pin(session)

    return session
end

--- Stop session owning current chat component.
function M.stop()
    local session = M.get()
    if not session then
        return
    end
    local history_buf = session.history_buf
    destroy_session(session)
    if vim.api.nvim_buf_is_valid(history_buf) then
        vim.api.nvim_buf_delete(history_buf, { force = true })
    end
end

--- Create a separate conversation buffer and RPC process.
function M.new_session()
    local session = M.get_or_create({ new = true })
    if session then
        session.chat:ensure_shown_and_focus_prompt()
    end
end

--- Replace the current conversation while keeping its workspace and view.
function M.replace_session()
    local current = M.get()
    if not current then
        M.new_session()
        return
    end
    if current.chat:is_busy() then
        Notify.warn("Cannot replace session while π is running")
        return
    end

    local history_buf = current.history_buf
    local replacement = M.get_or_create({ new = true, layout = current.chat:layout() })
    if not replacement then
        return
    end
    destroy_session(current)
    if vim.api.nvim_buf_is_valid(history_buf) then
        vim.api.nvim_buf_delete(history_buf, { force = true })
    end
    replacement.chat:ensure_shown_and_focus_prompt()
end

--- Replay messages from get_messages response into chat.
---@param messages table[]
---@return table[]
local function comparable_messages(messages)
    local comparable = vim.deepcopy(messages)
    for _, message in ipairs(comparable) do
        if message.role == "custom" or message.role == "branchSummary" or message.role == "compactionSummary" then
            message.timestamp = nil
        end
    end
    return comparable
end

---@param left table[]
---@param right table[]
---@return boolean
local function messages_equal(left, right)
    return vim.deep_equal(comparable_messages(left), comparable_messages(right))
end

---@param session agent_workbench.Session
---@param messages table[]
local function replay_messages(session, messages)
    session.chat:set_replaying(true)
    local pending_agent_end = false
    local tool_call_args = {} ---@type table<string, table>
    for _, msg in ipairs(messages) do
        local role = msg.role
        -- Flush pending agent_end before a user message
        if pending_agent_end and role == "user" then
            session.chat:on_agent_end()
            pending_agent_end = false
        end
        if role == "user" then
            local text = ""
            local image_count = 0
            if type(msg.content) == "string" then
                text = msg.content
            elseif type(msg.content) == "table" then
                for _, part in ipairs(msg.content) do
                    if type(part) == "string" then
                        text = text .. part
                    elseif type(part) == "table" and part.type == "text" then
                        text = text .. (part.text or "")
                    elseif type(part) == "table" and part.type == "image" then
                        image_count = image_count + 1
                    end
                end
            end
            if text ~= "" or image_count > 0 then
                session.chat:add_user_message(text, msg.timestamp, image_count > 0 and image_count or nil)
            end
        elseif role == "assistant" then
            local text = ""
            local tool_calls = {} ---@type { id: string, name: string, args: table? }[]
            local thinking_parts = {} ---@type string[]
            if type(msg.content) == "string" then
                text = msg.content
            elseif type(msg.content) == "table" then
                for _, part in ipairs(msg.content) do
                    if type(part) == "string" then
                        text = text .. part
                    elseif type(part) == "table" and part.type == "text" then
                        text = text .. (part.text or "")
                    elseif type(part) == "table" and part.type == "thinking" then
                        local t = part.thinking or ""
                        if t ~= "" then
                            thinking_parts[#thinking_parts + 1] = t
                        end
                    elseif type(part) == "table" and part.type == "toolCall" then
                        tool_calls[#tool_calls + 1] = {
                            id = part.toolCallId or part.id or "",
                            name = part.toolName or part.name or "tool",
                            args = normalize_tool_args(part.arguments or part.args or part.input),
                        }
                    end
                end
            end
            -- Replay thinking as a single block (session files store at most
            -- one thinking part per assistant message).
            local thinking_text = table.concat(thinking_parts, "\n")
            if text ~= "" or #tool_calls > 0 or thinking_text ~= "" then
                -- Suppress agent header for tool-only continuation turns:
                -- if previous turn was tool-only and this turn is also tool-only,
                -- skip the header to keep consecutive tool calls visually grouped.
                -- A turn with thinking is NOT tool-only — the thinking block
                -- needs the agent header above it.
                local tool_only = text == "" and #tool_calls > 0 and thinking_text == ""
                if not (tool_only and pending_agent_end) then
                    if pending_agent_end then
                        session.chat:on_agent_end()
                        pending_agent_end = false
                    end
                    session.chat:on_agent_start(msg.timestamp)
                end
                if thinking_text ~= "" then
                    -- Replayed blocks have no timing data; don't fabricate a duration.
                    session.chat:on_thinking_start({ unmeasured = true })
                    session.chat:on_thinking_delta(thinking_text)
                    session.chat:on_thinking_end()
                end
                if text ~= "" then
                    session.chat:on_text_delta(text)
                end
                -- Don't call on_agent_end yet — tool results follow as separate messages.
                -- Store pending tool calls so on_tool_end can fire before on_agent_end.
                for _, tc in ipairs(tool_calls) do
                    session.chat:on_tool_start(tc.name, tc.id, tc.args)
                    if tc.args then
                        tool_call_args[tc.id] = tc.args
                    end
                end
                if #tool_calls == 0 then
                    session.chat:on_agent_end()
                else
                    pending_agent_end = true
                end
            end
            local stop = msg.stopReason
            if stop ~= "aborted" and stop ~= "error" and type(msg.usage) == "table" then
                session.chat:add_usage(msg.usage)
            end
        elseif role == "toolResult" then
            local tool_call_id = msg.toolCallId or msg.toolUseId or ""
            local tool_name = msg.toolName or "tool"
            local is_error = msg.isError == true
            -- msg itself has .content, matching what on_tool_end expects as result
            session.chat:on_tool_end(tool_name, tool_call_id, msg, is_error)
            -- Track files changed by edit/write tools during replay.
            local tc_args = not is_error and tool_call_args[tool_call_id]
            if tc_args then
                track_changed_file(session, tc_args)
            end
        elseif role == "compactionSummary" then
            if pending_agent_end then
                session.chat:on_agent_end()
                pending_agent_end = false
            end
            session.chat:append_compaction_summary(msg.summary or "", tonumber(msg.tokensBefore) or 0)
        elseif role == "bashExecution" then
            if pending_agent_end then
                session.chat:on_agent_end()
                pending_agent_end = false
            end
            session.chat:on_bash_replay(msg)
        end
    end
    -- Flush any remaining pending agent_end
    if pending_agent_end then
        session.chat:on_agent_end()
    end
    session.chat:finish_replaying()
end

---@param session agent_workbench.Session
---@param _ table
---@param will_retry boolean
rebuild_after_compaction = function(session, _, will_retry)
    session._compaction_rebuilding = true
    session._compaction_event_queue = {}
    if will_retry then
        session.chat:flush_compaction_queue(true)
    end

    local sent = session.rpc:send({ type = "get_messages" }, function(res)
        vim.schedule(function()
            if not res.success then
                local err = res.error or "Failed to load compacted session messages"
                Notify.error(err)
                session.chat:on_error(err, { pad_top = true, pad_bottom = true })
                finish_compaction_rebuild(session, not will_retry, will_retry)
                return
            end

            local messages = (res.data or {}).messages or {}
            session.changed_files = {}
            session._pending_file_change_args = nil
            session.chat:clear_for_compaction_rebuild()
            show_startup_block(session, CommandsCache.list())
            replay_messages(session, messages)
            M.refresh_state(session)
            vim.schedule(function()
                finish_compaction_rebuild(session, not will_retry, will_retry)
            end)
        end)
    end)
    if not sent then
        finish_compaction_rebuild(session, false)
    end
end

--- Reload the current session's messages into the chat: clear -> get_messages
--- -> replay. Used after in-place session-tree navigation (:AgentWorkbenchTree), where the
--- backend moved the leaf and the active branch's context changed.
---@param session agent_workbench.Session
function M.reload_messages(session)
    vim.schedule(function()
        session.changed_files = {}
        session._pending_file_change_args = nil
        session.chat:clear()
        session.chat:show_loading()
    end)

    local sent = session.rpc:send({ type = "get_messages" }, function(res)
        vim.schedule(function()
            session.chat:clear_placeholder()
            if not res.success then
                local err = res.error or "Failed to load session messages"
                Notify.error(err)
                session.chat:on_error(err, { pad_top = true, pad_bottom = true })
                return
            end

            local messages = (res.data or {}).messages or {}
            -- Fetch commands, show startup block, then replay.
            CommandsCache.fetch(session.rpc, function(commands)
                show_startup_block(session, commands)
                replay_messages(session, messages)
                M.refresh_state(session)
            end)
        end)
    end)
    if not sent then
        vim.schedule(function()
            session.chat:clear()
            Notify.error("Failed to load session messages")
            session.chat:on_error("Failed to load session messages", { pad_top = true, pad_bottom = true })
        end)
    end
end

--- Open a persisted session URI in the current tab workspace.
---@param uri string
---@param requested_buf? integer
---@return boolean
function M.open_uri(uri, requested_buf)
    local project, session_key, resource = Workspace.parse(uri)
    if resource ~= "transcript" or not project or project ~= Workspace.project_key(Workspace.cwd()) then
        Notify.error("Session URI belongs to another project: " .. uri)
        return false
    end

    local History = require("agent-workbench.sessions.history")
    local session_path
    for _, info in ipairs(History.list()) do
        local id = vim.fs.basename(info.path):gsub("%.jsonl$", "")
        if id == session_key or info.id == session_key then
            session_path = info.path
            break
        end
    end
    if not session_path then
        Notify.error("Session not found: " .. uri)
        return false
    end

    local existing = Workspace.buffer(uri)
    if existing then
        local live = sessions_by_component[existing]
        if live then
            activate(live)
        end
        if requested_buf and vim.api.nvim_buf_is_valid(requested_buf) and requested_buf ~= existing then
            vim.api.nvim_buf_delete(requested_buf, { force = true })
        end
        return true
    end

    local session = M.get_or_create({ new = true })
    if not session then
        return false
    end
    if requested_buf and vim.api.nvim_buf_is_valid(requested_buf) and requested_buf ~= session.chat:history_buf() then
        vim.api.nvim_buf_delete(requested_buf, { force = true })
    end
    M._rebind_history(session, transcript_for(session, uri))
    session.chat:show({ loading = true })
    load_session(session, session_path)
    return true
end

--- Load a session by path: render a local read-only preview immediately, then
--- let RPC switch sessions and replace the preview with authoritative messages.
---@param session agent_workbench.Session
---@param session_path string
load_session = function(session, session_path)
    session._switching_session = true
    Attention.begin_session_transition(session)

    local preview = require("agent-workbench.sessions.history").load_messages(session_path)
    if preview then
        session.changed_files = {}
        session._pending_file_change_args = nil
        session.chat:clear()
        replay_messages(session, preview.messages)
    end
    session.chat:focus_for_session_entry()

    local sent_switch = session.rpc:send({ type = "switch_session", sessionPath = session_path }, function(msg)
        local data = msg.data or {}
        if not msg.success then
            session._switching_session = false
            vim.schedule(function()
                Attention.end_session_transition(session, false)
                Notify.error(msg.error or "Failed to switch session")
            end)
            return
        end
        if data.cancelled then
            session._switching_session = false
            vim.schedule(function()
                Attention.end_session_transition(session, false)
                Notify.warn("Session switch was cancelled")
            end)
            return
        end

        Attention.end_session_transition(session, true)
        require("agent-workbench.ui.sessions").invalidate(session)
        require("agent-workbench.ui.sessions").clear_flags(session)
        require("agent-workbench.ui.sessions").request_refresh()
        -- The resumed session's model was restored from its session file by
        -- core; adopt it as this tab's pin.
        refresh_state_and_pin(session)

        vim.schedule(function()
            session.changed_files = {}
            session._pending_file_change_args = nil
            if not preview then
                session.chat:clear()
                session.chat:show_loading()
            end
        end)

        local sent_messages = session.rpc:send({ type = "get_messages" }, function(res)
            vim.schedule(function()
                session.chat:clear_placeholder()
                if not res.success then
                    session._switching_session = false
                    local err = res.error or "Failed to load session messages"
                    Notify.error(err)
                    session.chat:on_error(err, { pad_top = true, pad_bottom = true })
                    return
                end

                local messages = (res.data or {}).messages or {}
                if not (preview and messages_equal(preview.messages, messages)) then
                    session.chat:clear()
                    replay_messages(session, messages)
                end
                session._switching_session = false
                CommandsCache.fetch(session.rpc, function(commands)
                    show_startup_block(session, commands)
                end)
            end)
        end)
        if not sent_messages then
            session._switching_session = false
            vim.schedule(function()
                session.chat:clear()
                Notify.error("Failed to load session messages")
                session.chat:on_error("Failed to load session messages", { pad_top = true, pad_bottom = true })
            end)
        end
    end)

    if not sent_switch then
        session._switching_session = false
        Attention.end_session_transition(session, false)
    end
end

---@param current_session_file? string
---@return string?
local function find_continue_session_path(current_session_file)
    local History = require("agent-workbench.sessions.history")
    local live_files = {}
    for _, live in ipairs(M.list()) do
        if live.session_file then
            live_files[live.session_file] = true
        end
    end
    local sessions_list = History.list()
    for _, session in ipairs(sessions_list) do
        if session.path ~= current_session_file and not live_files[session.path] then
            return session.path
        end
    end
    return nil
end

---@param session agent_workbench.Session
---@param state table?
---@return boolean
local function is_empty_session_state(session, state)
    if type(state) ~= "table" then
        return false
    end

    local message_count = type(state.messageCount) == "number" and state.messageCount or nil
    local pending_count = type(state.pendingMessageCount) == "number" and state.pendingMessageCount or nil
    if message_count == nil or pending_count == nil then
        return false
    end

    return message_count == 0
        and pending_count == 0
        and state.isStreaming ~= true
        and state.isCompacting ~= true
        and not session.chat:has_draft()
end

---@param session agent_workbench.Session
local function show_no_previous_sessions(session)
    Notify.info("No previous sessions found")
    session.chat:ensure_shown_and_focus_prompt()
end

--- Continue the most recent session for the current cwd.
---@param opts? agent_workbench.SessionCreateOpts
function M.continue_session(opts)
    local session = M.get()
    if not session then
        local session_path = find_continue_session_path(nil)
        opts = vim.tbl_extend("force", opts or {}, { new = true })
        session = M.get_or_create(opts)
        if not session then
            return
        end
        if not session_path then
            show_no_previous_sessions(session)
            return
        end
        session.chat:show({ loading = true })
        load_session(session, session_path)
        return
    end

    local sent = session.rpc:send({ type = "get_state" }, function(res)
        vim.schedule(function()
            if M.get() ~= session then
                return
            end
            if not res.success then
                Notify.error(res.error or "Failed to fetch session state")
                return
            end

            local state = res.data or {}
            if not is_empty_session_state(session, state) then
                return
            end

            local session_path = find_continue_session_path(state.sessionFile)
            if not session_path then
                show_no_previous_sessions(session)
                return
            end

            session.chat:show({ loading = true })
            load_session(session, session_path)
        end)
    end)
    if not sent then
        Notify.error("Failed to fetch session state")
    end
end

--- Show a picker to resume a past session.
---@param opts? agent_workbench.SessionCreateOpts
function M.resume_session(opts)
    local History = require("agent-workbench.sessions.history")
    local sessions_list = History.list()
    if #sessions_list == 0 then
        Notify.info("No sessions found")
        return
    end

    ---@class agent_workbench.SessionSelectItem
    ---@field session agent_workbench.SessionInfo
    ---@field file string

    ---@type agent_workbench.SessionSelectItem[]
    local items = {}
    for i, session in ipairs(sessions_list) do
        items[i] = {
            session = session,
            file = session.path,
        }
    end

    vim.ui.select(items, {
        prompt = "Resume session",
        kind = "pi-resume-session",
        -- Pass picker items with a `file` field so backends like snacks.nvim
        -- can preview the raw session file when preview is enabled. Other
        -- vim.ui.select implementations ignore extra fields and render via
        -- `format_item`.
        format_item = function(item)
            local session = item.session
            local date = session.timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)") or session.timestamp
            local label = session.name or (session.first_message ~= "" and session.first_message or "(empty)")
            return date .. "  " .. label
        end,
        snacks = {
            -- snacks.nvim (if installed) overrides vim.ui.select with its picker.
            -- It has a bug where the list height can be non-integer, crashing
            -- nvim_win_set_config. This `snacks` key is merged into the picker
            -- config and overrides the broken height calculation with math.floor.
            -- Safe to include even if snacks isn't used — the key is just ignored.
            layout = {
                config = function(layout)
                    for _, box in ipairs(layout.layout) do
                        if box.win == "list" then
                            box.height = math.floor(math.max(math.min(#items, vim.o.lines * 0.8 - 10), 2))
                        end
                    end
                end,
            },
            win = {
                input = { keys = { ["<C-x>"] = { "delete_session", mode = { "i", "n" }, desc = "Delete session" } } },
                list = { keys = { ["<C-x>"] = { "delete_session", mode = { "n" }, desc = "Delete session" } } },
            },
            actions = {
                delete_session = function(picker)
                    local selected = picker:selected({ fallback = true })
                    if #selected == 0 then
                        return
                    end
                    local n = #selected
                    local msg = n == 1 and "Delete session?" or ("Delete %d sessions?"):format(n)
                    if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
                        return
                    end
                    ---@type table<string, boolean>
                    local deleted = {}
                    for _, sel in ipairs(selected) do
                        local path = sel.item.file
                        local ok, err = os.remove(path)
                        if ok then
                            deleted[path] = true
                        else
                            Notify.warn("Failed to delete session: " .. (err or path))
                        end
                    end
                    for i = #items, 1, -1 do
                        if deleted[items[i].file] then
                            table.remove(items, i)
                        end
                    end
                    if #items == 0 then
                        picker:close()
                        Notify.info("No sessions remaining")
                    else
                        picker:refresh()
                    end
                end,
            },
        },
    }, function(item)
        if not item then
            return
        end
        local uri = Workspace.uri(Workspace.cwd(), item.session.path, item.session.path)
        local existing = Workspace.buffer(uri)
        local live = existing and sessions_by_component[existing]
        if live then
            activate(live)
            return
        end
        opts = vim.tbl_extend("force", opts or {}, { new = true })
        local session = M.get_or_create(opts)
        if not session then
            return
        end
        session.chat:show({ loading = true })
        load_session(session, item.session.path)
    end)
end

--- Drop view bindings for closed tabs; buffers own session lifetime.
function M.cleanup()
    for tab in pairs(active_by_tab) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
            active_by_tab[tab] = nil
        end
    end
end

function M._reset()
    local live = M.list()
    for _, session in ipairs(live) do
        local history_buf = session.history_buf
        destroy_session(session)
        if history_buf and vim.api.nvim_buf_is_valid(history_buf) then
            vim.api.nvim_buf_delete(history_buf, { force = true })
        end
    end
    sessions = {}
    sessions_by_component = {}
    active_by_tab = {}
    transcript_resources = {}
    next_session_id = 0
    activating = false
end

--- Set up session buffer lifecycle and activation autocmds.
function M.setup_autocmds()
    local group = vim.api.nvim_create_augroup("PiSessions", { clear = true })

    vim.api.nvim_create_autocmd("BufReadCmd", {
        group = group,
        pattern = "agent://*",
        callback = function(args)
            local uri = vim.api.nvim_buf_get_name(args.buf)
            vim.schedule(function()
                M.open_uri(uri, args.buf)
            end)
        end,
    })

    vim.api.nvim_create_autocmd("TabNewEntered", {
        group = group,
        callback = function()
            if not Config.options.auto_start_session then
                return
            end
            vim.schedule(function()
                if vim.api.nvim_get_current_tabpage() == nil then
                    return
                end
                M.get_or_create()
            end)
        end,
    })

    vim.api.nvim_create_autocmd("VimEnter", {
        group = group,
        callback = function()
            if not Config.options.auto_start_session then
                return
            end
            vim.schedule(function()
                M.get_or_create()
            end)
        end,
    })

    vim.api.nvim_create_autocmd("BufEnter", {
        callback = function(args)
            if activating then
                return
            end
            local session = sessions_by_component[args.buf]
            if session and args.buf == session.history_buf then
                activate(session)
                return
            end
            if session then
                return
            end
            local active = active_by_tab[current_tab()]
            if active and active.chat:owns_buffer(args.buf) then
                return
            end
            if active and active.chat:is_visible() then
                local win = vim.api.nvim_get_current_win()
                local kind = active.chat:focus_kind()
                if kind then
                    activating = true
                    active.chat:detach_for_buffer(win, args.buf)
                    active_by_tab[current_tab()] = nil
                    activating = false
                end
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = group,
        callback = function(args)
            if require("agent-workbench.workspace_buffers").is_updating_listed() then
                return
            end
            local session = sessions_by_component[args.buf]
            if session and args.buf == session.history_buf then
                destroy_session(session)
            end
        end,
    })

    vim.api.nvim_create_autocmd("DirChanged", {
        group = group,
        pattern = "tabpage",
        callback = function()
            local tab = current_tab()
            local session = active_by_tab[tab]
            local cwd = Workspace.cwd(tab)
            if not session or session.cwd == cwd then
                return
            end
            if session.chat:is_busy() then
                Notify.warn("Cannot change workspace while π is running; restored " .. session.cwd)
                vim.cmd("tcd " .. vim.fn.fnameescape(session.cwd))
                return
            end
            local replacement = M.get_or_create({ new = true, layout = session.chat:layout() })
            if replacement then
                destroy_session(session)
                if vim.api.nvim_buf_is_valid(session.history_buf) then
                    vim.api.nvim_buf_delete(session.history_buf, { force = true })
                end
            else
                vim.cmd("tcd " .. vim.fn.fnameescape(session.cwd))
            end
        end,
    })

    vim.api.nvim_create_autocmd("TabClosed", {
        group = group,
        callback = function()
            vim.schedule(function()
                M.cleanup()
            end)
        end,
    })

    -- Entering a tab consumes that session's done/error notification: the
    -- user has seen it, so the dot returns to idle.
    vim.api.nvim_create_autocmd("TabEnter", {
        group = group,
        callback = function()
            local session = M.get()
            if session then
                require("agent-workbench.ui.sessions").clear_flags(session)
            elseif Config.options.auto_start_session then
                vim.schedule(function()
                    M.get_or_create()
                end)
            end
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            for _, session in pairs(sessions) do
                Attention.clear_session(session)
                session.chat:clear_prompt_request()
                session.chat:destroy()
                session.rpc:stop()
            end
        end,
    })

    vim.api.nvim_create_autocmd("VimResized", {
        group = group,
        callback = function()
            for _, session in pairs(sessions) do
                if session.chat:is_visible() then
                    session.chat:on_resize()
                end
            end
        end,
    })
end

return M
