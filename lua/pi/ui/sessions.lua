--- Sessions overview (:PiSessions) — a live list of all active pi sessions.
---
--- One shared scratch buffer lists every active session (one per Neovim tab)
--- with its display name and status (busy / compacting / idle / attention).
--- The buffer is global: each tab that opens the list gets its own window on
--- the same buffer, so content and highlights are shared and a single redraw
--- updates every view at once. Window geometry is per-tab.
---
--- Updates are event-driven: the session manager and the attention module
--- call request_refresh() on lifecycle transitions. Redraws are coalesced via
--- vim.schedule and only run while a list window is visible.

local M = {}

local Config = require("pi.config")
local Ft = require("pi.filetypes")
local Highlights = require("pi.ui.highlights")

local ns = vim.api.nvim_create_namespace("pi-sessions-list")

---@alias pi.SessionsListStatus "busy"|"compacting"|"idle"|"exited"

---@class pi.SessionsListRow
---@field tab pi.TabId
---@field status pi.SessionsListStatus
---@field attention integer pending attention request count
---@field done boolean last turn finished while the user was elsewhere
---@field error boolean last turn failed and the user hasn't seen it yet
---@field name string? display name (nil while still fetching)

---@type integer? shared list buffer
local buf = nil

---@type table<pi.TabId, integer> list window per tab
local wins = {}

---@type pi.SessionsListRow[] rows of the last render (index == buffer line)
local rows = {}

--- Per-session name cache. Weak keys drop entries together with dead
--- sessions. A string entry marks a fetch in flight.
---   name:          backend sessionName (false = fetched, none set)
---   first_message: fallback from the session file (false = none)
---@type table<pi.Session, { name: string|false, first_message: string|false }|string>
local name_cache = setmetatable({}, { __mode = "k" })

local refresh_scheduled = false

---@return pi.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
end

--- Current status of a session.
---@param session pi.Session
---@return pi.SessionsListStatus
function M.status_of(session)
    if not session.rpc:is_running() then
        return "exited"
    end
    if session.chat:is_compacting() then
        return "compacting"
    end
    if session.chat:is_streaming() then
        return "busy"
    end
    return "idle"
end

--- Highlight group of a row's status dot at a given animation tick.
--- Busy blinks every tick, compacting at half speed; attention, idle and
--- exited are steady (their color alone carries the state).
---@param row pi.SessionsListRow
---@param tick integer
---@return string
function M.dot_hl(row, tick)
    if row.status == "exited" then
        return "PiSessionsListExited"
    end
    if row.error then
        return tick % 2 == 0 and "PiSessionsListError" or "PiSessionsListDotDim"
    end
    if row.attention > 0 then
        return "PiStatusLineAttention"
    end
    if row.done then
        return tick % 2 == 0 and "PiSessionsListDone" or "PiSessionsListDotDim"
    end
    if row.status == "busy" then
        return tick % 2 == 0 and "PiBusy" or "PiSessionsListDotDim"
    end
    if row.status == "compacting" then
        return math.floor(tick / 2) % 2 == 0 and "PiSessionsListCompacting" or "PiSessionsListDotDim"
    end
    return "PiSessionsListIdle"
end

--- Format a row: the status dot at the left edge, the name right after it.
--- Chunks are byte ranges: { col_start, col_end, hl_group }.
---@param row pi.SessionsListRow
---@param tick integer
---@return string line
---@return integer[][] chunks
function M.format_line(row, tick)
    local indent = " "
    local dot = "●"
    local name = row.name or "…"
    local line = indent .. dot .. " " .. name
    local dot_start = #indent
    local name_start = dot_start + #dot + 1
    local chunks = {
        { dot_start, dot_start + #dot, M.dot_hl(row, tick) },
        { name_start, name_start + #name, row.name and "Normal" or "PiSessionsListPending" },
    }
    return line, chunks
end

--- Build display rows from live sessions.
---@param sessions pi.Session[]
---@param attention_count fun(tab: pi.TabId): integer
---@param name_of fun(session: pi.Session): string?
---@param flags_of? fun(session: pi.Session): { done: boolean, error: boolean }
---@return pi.SessionsListRow[]
function M.build_rows(sessions, attention_count, name_of, flags_of)
    ---@type pi.SessionsListRow[]
    local out = {}
    for _, session in ipairs(sessions) do
        local f = flags_of and flags_of(session) or nil
        out[#out + 1] = {
            tab = session.tab,
            status = M.status_of(session),
            attention = attention_count(session.tab) or 0,
            done = f ~= nil and f.done == true,
            error = f ~= nil and f.error == true,
            name = name_of(session),
        }
    end
    return out
end

-- Turn flags (done / error) -----------------------------------------------------

--- Per-session turn flags, weak-keyed like the name cache.
---   done:  the agent finished a turn while the session's tab was not current;
---          cleared when the user enters the tab (or a new turn starts).
---   error: the last turn failed; cleared the same way.
---@type table<pi.Session, { done: boolean, error: boolean }>
local flags = setmetatable({}, { __mode = "k" })

---@param session pi.Session
---@return { done: boolean, error: boolean }
local function session_flags(session)
    local f = flags[session]
    if not f then
        f = { done = false, error = false }
        flags[session] = f
    end
    return f
end

--- A new turn starts: the user is about to see fresh activity, so both
--- notifications are consumed.
---@param session pi.Session
function M.on_agent_start(session)
    local f = session_flags(session)
    f.done = false
    f.error = false
end

--- The turn failed (stopReason error, retry exhausted, async prompt error,
--- compaction error). Blinks red until the user looks at the tab.
---@param session pi.Session
function M.mark_error(session)
    session_flags(session).error = true
    M.request_refresh()
end

--- A turn finished. If it ended in error, keep the error flag; otherwise mark
--- the session "done" (green blink) only when the user is looking elsewhere.
---@param session pi.Session
function M.on_agent_end(session)
    local f = session_flags(session)
    if not f.error and session.tab ~= current_tab() then
        f.done = true
    end
    M.request_refresh()
end

--- The user is now looking at this session (TabEnter): both notifications are
--- consumed and the dot returns to idle.
---@param session pi.Session
function M.clear_flags(session)
    local f = flags[session]
    if f then
        f.done = false
        f.error = false
    end
    M.request_refresh()
end

-- Name cache ------------------------------------------------------------------

---@param session pi.Session
---@return string?
local function resolve_name(session)
    local entry = name_cache[session]
    if type(entry) ~= "table" then
        return nil
    end
    if entry.name then
        return entry.name --[[@as string]]
    end
    if entry.first_message then
        return entry.first_message --[[@as string]]
    end
    return "(unnamed)"
end

--- Ask the backend for the session's display name (and fall back to the first
--- user message from its session file). Successful non-empty results are
--- cached; lifecycle transitions invalidate the cache (M.invalidate).
--- Entries that resolved empty stay retryable: a brand-new session has no
--- sessionName and its file does not exist yet, so the first-message fallback
--- only becomes available after the first turn.
---@param session pi.Session
local function fetch_name(session)
    local entry = name_cache[session]
    local retryable = entry == nil or (type(entry) == "table" and not entry.name and not entry.first_message)
    if not retryable or not session.rpc:is_running() then
        return
    end
    name_cache[session] = "pending"
    local sent = session.rpc:send({ type = "get_state" }, function(res)
        vim.schedule(function()
            local data = res.success and res.data or {}
            local name = type(data.sessionName) == "string" and data.sessionName ~= "" and data.sessionName or false
            ---@type string|false
            local first_message = false
            if not name and type(data.sessionFile) == "string" then
                local info = require("pi.sessions.history").parse(data.sessionFile)
                if info and info.first_message ~= "" then
                    first_message = info.first_message
                end
            end
            name_cache[session] = { name = name, first_message = first_message }
            M.request_refresh()
        end)
    end)
    if not sent then
        name_cache[session] = nil
    end
end

--- Drop the cached name for a session (new session, resumed session).
---@param session pi.Session
function M.invalidate(session)
    name_cache[session] = nil
end

--- Backend reports the session name changed (e.g. :PiSessionName).
---@param session pi.Session
---@param name string?
function M.on_session_info_changed(session, name)
    local entry = name_cache[session]
    if type(entry) ~= "table" then
        entry = { name = false, first_message = false }
        name_cache[session] = entry
    end
    entry.name = type(name) == "string" and name ~= "" and name or false
    M.request_refresh()
end

-- Rendering -------------------------------------------------------------------

---@return boolean
local function any_win_visible()
    for _, win in pairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            return true
        end
    end
    return false
end

-- Blink animation -------------------------------------------------------------

local uv = vim.uv or vim.loop
local blink_tick = 0
---@type uv.uv_timer_t?
local blink_timer = nil

---@return boolean whether any row animates (busy/compacting)
local function has_animated_row()
    for _, row in ipairs(rows) do
        if row.status == "busy" or row.status == "compacting" then
            return true
        end
    end
    return false
end

local function stop_blink()
    if not blink_timer then
        return
    end
    pcall(blink_timer.stop, blink_timer)
    if not blink_timer:is_closing() then
        blink_timer:close()
    end
    blink_timer = nil
end

--- Run the blink timer only while an animated row is on screen.
local function ensure_blink()
    if not has_animated_row() then
        stop_blink()
        return
    end
    if blink_timer and not blink_timer:is_closing() then
        return
    end
    blink_timer = assert(uv.new_timer())
    blink_timer:start(
        500,
        500,
        vim.schedule_wrap(function()
            if not any_win_visible() or not has_animated_row() then
                vim.schedule(stop_blink)
                return
            end
            blink_tick = blink_tick + 1
            M._render()
        end)
    )
end

--- Rebuild the buffer contents from live session state.
function M._render()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    local Sessions = require("pi.sessions.manager")
    local Attention = require("pi.attention")
    local sessions = Sessions.list()

    rows = M.build_rows(sessions, function(tab)
        return Attention.count(tab)
    end, function(session)
        local name = resolve_name(session)
        -- A dead process will never answer the name fetch; stop showing the
        -- pending placeholder for it.
        if name == nil and not session.rpc:is_running() then
            return "(unnamed)"
        end
        return name
    end, function(session)
        return flags[session] or { done = false, error = false }
    end)

    ---@type string[]
    local lines = {}
    ---@type table<integer, integer[][]>
    local line_chunks = {}
    for i, row in ipairs(rows) do
        local line, chunks = M.format_line(row, blink_tick)
        lines[i] = line
        line_chunks[i] = chunks
    end
    if #lines == 0 then
        lines = { "  (no active sessions)" }
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for lnum, chunks in ipairs(line_chunks) do
        for _, chunk in ipairs(chunks) do
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, chunk[1], {
                end_col = chunk[2],
                hl_group = chunk[3],
            })
        end
    end
    vim.bo[buf].modifiable = false

    -- Keep cursors inside the (possibly shrunk) buffer.
    for _, win in pairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            local cursor = vim.api.nvim_win_get_cursor(win)
            if cursor[1] > #lines then
                pcall(vim.api.nvim_win_set_cursor, win, { #lines, 0 })
            end
        end
    end

    for _, session in ipairs(sessions) do
        fetch_name(session)
    end

    ensure_blink()
end

--- Coalesced live redraw; no-op unless a list window is visible.
function M.request_refresh()
    if refresh_scheduled then
        return
    end
    refresh_scheduled = true
    vim.schedule(function()
        refresh_scheduled = false
        if any_win_visible() then
            M._render()
        end
    end)
end

-- Buffer & windows ------------------------------------------------------------

local function jump_under_cursor()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local row = rows[lnum]
    if not row or not vim.api.nvim_tabpage_is_valid(row.tab) then
        return
    end
    local Sessions = require("pi.sessions.manager")
    for _, session in ipairs(Sessions.list()) do
        if session.tab == row.tab then
            vim.api.nvim_set_current_tabpage(row.tab)
            session.chat:ensure_shown_and_focus_prompt()
            return
        end
    end
end

---@return integer
local function ensure_buf()
    if buf and vim.api.nvim_buf_is_valid(buf) then
        return buf
    end
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "pi://sessions")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].buflisted = false
    vim.bo[buf].filetype = Ft.sessions
    vim.bo[buf].modifiable = false

    local map_opts = { buffer = buf, nowait = true }
    vim.keymap.set("n", "<CR>", jump_under_cursor, vim.tbl_extend("force", map_opts, { desc = "Open this session" }))
    vim.keymap.set("n", "o", jump_under_cursor, vim.tbl_extend("force", map_opts, { desc = "Open this session" }))
    vim.keymap.set("n", "r", function()
        name_cache = setmetatable({}, { __mode = "k" })
        M._render()
    end, vim.tbl_extend("force", map_opts, { desc = "Refresh session list" }))
    vim.keymap.set("n", "q", function()
        M.close()
    end, vim.tbl_extend("force", map_opts, { desc = "Close session list" }))

    return buf
end

--- Resolve a dimension (columns/lines) from a config value; values < 1 are
--- fractions of the available space.
---@param value number
---@param available integer
---@return integer
local function resolve_dimension(value, available)
    if value < 1 then
        return math.max(1, math.floor(available * value))
    end
    return math.max(1, math.floor(value))
end

---@param win integer
local function set_list_win_opts(win)
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].foldenable = false
    vim.wo[win].list = false
    vim.wo[win].spell = false
    vim.wo[win].cursorline = true
    vim.wo[win].winfixbuf = true
end

---@param b integer
---@return integer
local function open_side_win(b)
    local cfg = Config.options.sessions_list
    local position = cfg.position or "left"
    local cmd
    if position == "right" then
        cmd = "botright " .. cfg.width .. "vsplit"
    elseif position == "top" then
        cmd = "topleft " .. cfg.height .. "split"
    elseif position == "bottom" then
        cmd = "botright " .. cfg.height .. "split"
    else
        cmd = "topleft " .. cfg.width .. "vsplit"
    end
    vim.cmd(cmd)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, b)
    set_list_win_opts(win)
    if position == "top" or position == "bottom" then
        vim.wo[win].winfixheight = true
    else
        vim.wo[win].winfixwidth = true
    end
    return win
end

---@param b integer
---@return integer
local function open_float_win(b)
    local cfg = Config.options.sessions_list.float
    local width = resolve_dimension(cfg.width, vim.o.columns)
    local height = resolve_dimension(cfg.height, vim.o.lines - vim.o.cmdheight - 1)
    local col = math.floor((vim.o.columns - width) / 2)
    local row = math.floor((vim.o.lines - vim.o.cmdheight - 1 - height) / 2)
    local win = vim.api.nvim_open_win(b, true, {
        relative = "editor",
        width = width,
        height = height,
        col = col,
        row = math.max(0, row),
        style = "minimal",
        border = cfg.border or "rounded",
        title = " sessions ",
        title_pos = "center",
    })
    set_list_win_opts(win)
    vim.wo[win].winhighlight = Highlights.SESSIONS_LIST_WINHIGHLIGHT
    return win
end

--- Layout mode for the list window: follow the current tab's chat layout so
--- the list feels consistent with how the chat is shown there, falling back
--- to the configured default layout mode.
---@return pi.LayoutMode
local function resolve_mode()
    local Sessions = require("pi.sessions.manager")
    local session = Sessions.get()
    if session then
        return session.chat:layout()
    end
    return Config.resolve_default_layout_mode()
end

---@param tab pi.TabId
---@return integer?
local function win_for(tab)
    local win = wins[tab]
    if win and vim.api.nvim_win_is_valid(win) then
        return win
    end
    wins[tab] = nil
    return nil
end

--- Open (or focus) the sessions list in the current tab.
function M.open()
    local tab = current_tab()
    local existing = win_for(tab)
    if existing then
        vim.api.nvim_set_current_win(existing)
        return
    end

    local b = ensure_buf()
    local win
    if resolve_mode() == "float" then
        win = open_float_win(b)
    else
        win = open_side_win(b)
    end
    wins[tab] = win
    M._render()
end

--- Close the sessions list window in the current tab (no-op when absent).
function M.close()
    local tab = current_tab()
    local win = win_for(tab)
    if not win then
        return
    end
    wins[tab] = nil
    if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, false)
    end
end

--- Toggle the sessions list in the current tab.
function M.toggle()
    if win_for(current_tab()) then
        M.close()
    else
        M.open()
    end
end

--- Test hook: resolved display name for a session (nil while fetching).
---@param session pi.Session
---@return string?
function M._name_of(session)
    return resolve_name(session)
end

--- Test hook: drop all module state.
function M._reset()
    stop_blink()
    blink_tick = 0
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    buf = nil
    wins = {}
    rows = {}
    name_cache = setmetatable({}, { __mode = "k" })
    refresh_scheduled = false
end

return M
