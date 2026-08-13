--- Collapsible workspace explorer backed by a native scratch buffer and split.

local M = {}

local Config = require("pi.config")
local Ft = require("pi.filetypes")
local Highlights = require("pi.ui.highlights")
local SessionsUi = require("pi.ui.sessions")

local ns = vim.api.nvim_create_namespace("pi-workspace-sidebar")
local buf
---@type table<pi.TabId, integer>
local wins = {}
---@type table<pi.TabId, boolean>
local expanded = {}
---@type table<integer, {
--- kind: "workspace"|"session"|"buffer",
--- workspace?: pi.WorkspaceRow,
--- session?: pi.Session,
--- buf?: integer,
---}>
local line_items = {}
local refresh_scheduled = false
---@type table<integer, integer>
local help_wins = {}

---@type [string, string][]
local HELP_ENTRIES = {
    { "<CR>", "Switch workspace or open item" },
    { "h / l", "Toggle workspace; collapse/open item" },
    { "e, <Tab>", "Toggle workspace" },
    { "d", "Delete buffer" },
    { "a", "Create session in workspace" },
    { "A", "Create workspace" },
    { "o", "Open and close sidebar" },
    { "R", "Refresh workspaces and titles" },
    { "q", "Close sidebar" },
    { "?", "Toggle this help" },
}

---@return pi.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
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

---@return boolean
local function any_win_visible()
    for tab in pairs(wins) do
        if win_for(tab) then
            return true
        end
    end
    return false
end

---@param workspace pi.WorkspaceRow
---@return pi.Session[]
local function sessions_for(workspace)
    local result = {} ---@type pi.Session[]
    for _, session in ipairs(require("pi.sessions.manager").list()) do
        if session.workspace_tab == workspace.tab or session.workspace_tab == nil and session.cwd == workspace.cwd then
            result[#result + 1] = session
        end
    end
    table.sort(result, function(a, b)
        return a.id < b.id
    end)
    return result
end

---@param workspace pi.WorkspaceRow
---@param sessions pi.Session[]
---@return integer[]
local function buffers_for(workspace, sessions)
    local session_buffers = {}
    for _, session in ipairs(sessions) do
        if session.history_buf then
            session_buffers[session.history_buf] = true
        end
    end
    local result = {}
    for _, candidate in ipairs(require("pi.workspace_buffers").list(workspace.tab)) do
        if not session_buffers[candidate] and vim.api.nvim_buf_is_valid(candidate) and vim.bo[candidate].buflisted then
            result[#result + 1] = candidate
        end
    end
    table.sort(result, function(a, b)
        local a_name = vim.api.nvim_buf_get_name(a)
        local b_name = vim.api.nvim_buf_get_name(b)
        return a_name == b_name and a < b or a_name < b_name
    end)
    return result
end

---@param target integer
---@return string
local function buffer_title(target)
    local name = vim.api.nvim_buf_get_name(target)
    local title = name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":t")
    local max_chars = math.max(12, (Config.options.workspace_sidebar.width or 38) - 8)
    if vim.fn.strchars(title) > max_chars then
        return vim.fn.strcharpart(title, 0, max_chars - 1) .. "…"
    end
    return title
end

---@param target integer
---@return string, string?
local function buffer_icon(target)
    local name = vim.api.nvim_buf_get_name(target)
    if name ~= "" then
        local ok, devicons = pcall(require, "nvim-web-devicons")
        if ok then
            local filename = vim.fn.fnamemodify(name, ":t")
            local extension = vim.fn.fnamemodify(filename, ":e")
            local icon, highlight = devicons.get_icon(filename, extension, { default = true })
            if icon then
                return icon, highlight
            end
        end
    end
    return "󰈔", nil
end

---@param target integer
---@return string
local function buffer_status(target)
    if vim.bo[target].modified then
        return "modified"
    end
    if vim.bo[target].readonly then
        return "readonly"
    end
    return ""
end

---@param session pi.Session
---@return string
local function session_status(session)
    if not session.rpc:is_running() then
        return "exited"
    end
    if session.chat:is_compacting() then
        return "compacting"
    end
    if session.chat:is_streaming() then
        return "busy"
    end
    if require("pi.attention").count_for_session(session) > 0 then
        return "attention"
    end
    return "idle"
end

---@param status string
---@return string
local function session_icon(status)
    if status == "busy" then
        return "󰔟"
    end
    if status == "compacting" then
        return "󰏗"
    end
    if status == "attention" then
        return ""
    end
    if status == "exited" then
        return "󰅖"
    end
    return "󰄬"
end

---@param status string
---@return string
local function status_marker(status)
    if status == "attention" then
        return "!"
    end
    if status == "busy" or status == "compacting" then
        return "●"
    end
    if status == "exited" then
        return "×"
    end
    return ""
end

---@param status string
---@return string
local function status_label(status)
    if status == "busy" then
        return "running"
    end
    if status == "exited" then
        return "stopped"
    end
    return status
end

---@param session pi.Session
---@return string
local function session_title(session)
    local title = SessionsUi._name_of(session)
    if title == nil then
        SessionsUi._fetch_name(session)
    end
    if not title or title == "" or title == "(unnamed)" then
        return "session " .. session.id
    end
    local max_chars = math.max(12, (Config.options.workspace_sidebar.width or 38) - 16)
    if vim.fn.strchars(title) > max_chars then
        return vim.fn.strcharpart(title, 0, max_chars - 1) .. "…"
    end
    return title
end

---@param tab pi.TabId
local function switch_workspace(tab)
    if vim.api.nvim_tabpage_is_valid(tab) then
        vim.api.nvim_set_current_tabpage(tab)
    end
end

---@return table?
local function item_under_cursor()
    return line_items[vim.api.nvim_win_get_cursor(0)[1]]
end

local function toggle_under_cursor()
    local item = item_under_cursor()
    if not item or item.kind ~= "workspace" or not item.workspace then
        return
    end
    expanded[item.workspace.tab] = not expanded[item.workspace.tab]
    M._render()
end

local function close_under_cursor()
    local item = item_under_cursor()
    if not item or not item.workspace then
        return
    end
    if item.kind == "workspace" then
        toggle_under_cursor()
        return
    end
    local tab = item.workspace.tab
    if expanded[tab] ~= true then
        return
    end
    local parent_line = vim.api.nvim_win_get_cursor(0)[1]
    while parent_line > 1 do
        parent_line = parent_line - 1
        local parent = line_items[parent_line]
        if parent and parent.kind == "workspace" and parent.workspace and parent.workspace.tab == tab then
            break
        end
    end
    expanded[tab] = false
    M._render()
    pcall(vim.api.nvim_win_set_cursor, 0, { parent_line, 0 })
end

local function is_pi_panel(filetype)
    return filetype == Ft.history or filetype == Ft.prompt or filetype == Ft.attachments or filetype == Ft.workspaces
end

---@param tab pi.TabId
---@return integer
local function focus_editor(tab)
    local sidebar = win_for(tab)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local config = vim.api.nvim_win_get_config(win)
        local target_buf = vim.api.nvim_win_get_buf(win)
        if
            win ~= sidebar
            and config.relative == ""
            and not vim.wo[win].winfixbuf
            and not is_pi_panel(vim.bo[target_buf].filetype)
        then
            vim.api.nvim_set_current_win(win)
            return win
        end
    end
    vim.cmd("leftabove new")
    return vim.api.nvim_get_current_win()
end

local function open_under_cursor_tree()
    local item = item_under_cursor()
    if not item then
        return
    end
    if item.kind == "session" and item.session then
        local tab = item.workspace and item.workspace.tab or current_tab()
        switch_workspace(tab)
        focus_editor(tab)
        require("pi.sessions.manager").activate(item.session)
        return
    end
    if item.kind == "buffer" and item.buf and item.workspace then
        switch_workspace(item.workspace.tab)
        local editor = focus_editor(item.workspace.tab)
        vim.api.nvim_win_set_buf(editor, item.buf)
        return
    end
    if item.workspace then
        toggle_under_cursor()
    end
end

---@param close_after boolean
local function open_under_cursor(close_after)
    local item = item_under_cursor()
    if not item then
        return
    end
    if item.kind == "session" and item.session then
        local tab = item.workspace and item.workspace.tab or current_tab()
        if close_after then
            M.close()
        end
        switch_workspace(tab)
        focus_editor(tab)
        require("pi.sessions.manager").activate(item.session)
        return
    end
    if item.kind == "buffer" and item.buf and item.workspace then
        local tab = item.workspace.tab
        if close_after then
            M.close()
        end
        switch_workspace(tab)
        local editor = focus_editor(tab)
        vim.api.nvim_win_set_buf(editor, item.buf)
        return
    end
    if item.workspace then
        local tab = item.workspace.tab
        if close_after then
            M.close()
        end
        switch_workspace(tab)
    end
end

---@param list_win integer
local function close_help(list_win)
    local help = help_wins[list_win]
    if help and vim.api.nvim_win_is_valid(help) then
        pcall(vim.api.nvim_win_close, help, true)
    end
    help_wins[list_win] = nil
end

---@param list_win integer
local function toggle_help(list_win)
    local existing = help_wins[list_win]
    if existing and vim.api.nvim_win_is_valid(existing) then
        close_help(list_win)
        return
    end
    if not vim.api.nvim_win_is_valid(list_win) then
        return
    end

    local key_width = 0
    local width = 0
    local lines = {} ---@type string[]
    for _, entry in ipairs(HELP_ENTRIES) do
        key_width = math.max(key_width, vim.fn.strdisplaywidth(entry[1]))
    end
    for _, entry in ipairs(HELP_ENTRIES) do
        local line = string.format("%-" .. key_width .. "s  %s", entry[1], entry[2])
        lines[#lines + 1] = line
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = width + 2

    local help_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, lines)
    vim.bo[help_buf].buftype = "nofile"
    vim.bo[help_buf].bufhidden = "wipe"
    vim.bo[help_buf].filetype = Ft.dialog
    local editor_height = vim.o.lines - vim.o.cmdheight
    local help = vim.api.nvim_open_win(help_buf, false, {
        relative = "editor",
        row = math.floor((editor_height - #lines) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        width = width,
        height = #lines,
        style = "minimal",
        border = Config.options.dialog.border,
        title = " workspace explorer ",
        title_pos = "center",
        focusable = false,
    })
    vim.wo[help].winhighlight = Highlights.DIALOG_WINHIGHLIGHT
    help_wins[list_win] = help
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(list_win),
        once = true,
        callback = function()
            close_help(list_win)
        end,
    })
end

local function create_session_under_cursor()
    local item = item_under_cursor()
    if not item or not item.workspace then
        return
    end
    switch_workspace(item.workspace.tab)
    require("pi.sessions.manager").new_session()
end

local function delete_under_cursor()
    local item = item_under_cursor()
    if not item then
        return
    end
    local target = item.kind == "session" and item.session and item.session.history_buf or item.buf
    if not target or not vim.api.nvim_buf_is_valid(target) then
        return
    end
    local ok, err = pcall(vim.api.nvim_buf_delete, target, { force = false })
    if not ok then
        require("pi.notify").warn(tostring(err))
        return
    end
    M._render()
end

local function refresh()
    for _, session in ipairs(require("pi.sessions.manager").list()) do
        SessionsUi.invalidate(session)
    end
    M._render()
end

---@return integer
local function ensure_buf()
    if buf and vim.api.nvim_buf_is_valid(buf) then
        return buf
    end
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = Ft.workspaces
    vim.api.nvim_buf_set_name(buf, "π-workspaces")

    local opts = { buffer = buf, nowait = true }
    vim.keymap.set("n", "<CR>", function()
        open_under_cursor(false)
    end, vim.tbl_extend("force", opts, { desc = "Switch workspace or open item" }))
    vim.keymap.set("n", "o", function()
        open_under_cursor(true)
    end, vim.tbl_extend("force", opts, { desc = "Switch and close workspace sidebar" }))
    vim.keymap.set(
        "n",
        "<Tab>",
        toggle_under_cursor,
        vim.tbl_extend("force", opts, { desc = "Toggle workspace items" })
    )
    vim.keymap.set(
        "n",
        "h",
        close_under_cursor,
        vim.tbl_extend("force", opts, { desc = "Toggle workspace or collapse item" })
    )
    vim.keymap.set(
        "n",
        "l",
        open_under_cursor_tree,
        vim.tbl_extend("force", opts, { desc = "Toggle workspace or open item" })
    )
    vim.keymap.set("n", "e", toggle_under_cursor, vim.tbl_extend("force", opts, { desc = "Toggle workspace" }))
    vim.keymap.set("n", "d", delete_under_cursor, vim.tbl_extend("force", opts, { desc = "Delete buffer" }))
    vim.keymap.set("n", "R", refresh, vim.tbl_extend("force", opts, { desc = "Refresh workspaces" }))
    vim.keymap.set("n", "a", create_session_under_cursor, vim.tbl_extend("force", opts, { desc = "Create session" }))
    vim.keymap.set("n", "A", function()
        require("pi.ui.workspaces").create()
    end, vim.tbl_extend("force", opts, { desc = "Create workspace" }))
    vim.keymap.set("n", "?", function()
        toggle_help(vim.api.nvim_get_current_win())
    end, vim.tbl_extend("force", opts, { desc = "Toggle help" }))
    vim.keymap.set("n", "<Esc>", function()
        close_help(vim.api.nvim_get_current_win())
    end, vim.tbl_extend("force", opts, { desc = "Close help" }))
    vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "Close workspace sidebar" }))
    return buf
end

---@param win integer
local function set_win_opts(win)
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].list = false
    vim.wo[win].spell = false
    vim.wo[win].cursorline = true
    vim.wo[win].winfixbuf = true
    vim.wo[win].winfixwidth = true
    vim.wo[win].winbar = " Workspaces "
end

function M._render()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local lines = {} ---@type string[]
    local highlights = {} ---@type {
    --- line: integer,
    --- start_col: integer,
    --- end_col: integer,
    --- group: string,
    --- suffix?: string,
    ---}[]
    line_items = {}
    local current = current_tab()

    for _, workspace in ipairs(require("pi.ui.workspaces").list()) do
        local sessions = sessions_for(workspace)
        local open = expanded[workspace.tab] == true
        local marker = status_marker(workspace.status)
        local count = workspace.sessions == 0 and "" or tostring(workspace.sessions)
        local suffix = marker == "" and count or (count == "" and marker or (count .. " " .. marker))
        local prefix = open and " 󰙅 " or " 󰙅 "
        lines[#lines + 1] = prefix .. vim.fn.fnamemodify(workspace.cwd, ":~")
        line_items[#lines] = { kind = "workspace", workspace = workspace }
        highlights[#highlights + 1] = {
            line = #lines - 1,
            start_col = 0,
            end_col = #lines[#lines],
            group = workspace.tab == current and "PiSessionsListCurrent" or "Title",
            suffix = suffix,
        }

        if open then
            for _, session in ipairs(sessions) do
                local status = session_status(session)
                local title = session_title(session)
                local icon = session_icon(status)
                lines[#lines + 1] = "  " .. icon .. " " .. title
                line_items[#lines] = { kind = "session", workspace = workspace, session = session }
                highlights[#highlights + 1] = {
                    line = #lines - 1,
                    start_col = 2,
                    end_col = #lines[#lines],
                    group = status == "attention" and "PiStatusLineAttention"
                        or (status == "busy" and "PiSessionsListBusy"
                            or (status == "compacting" and "PiSessionsListCompacting"
                                or (status == "exited" and "PiSessionsListExited" or "PiSessionsListIdle"))),
                    suffix = status_label(status),
                }
            end
            for _, target in ipairs(buffers_for(workspace, sessions)) do
                local title = buffer_title(target)
                local status = buffer_status(target)
                local icon, icon_highlight = buffer_icon(target)
                lines[#lines + 1] = "  " .. icon .. " " .. title
                line_items[#lines] = { kind = "buffer", workspace = workspace, buf = target }
                highlights[#highlights + 1] = {
                    line = #lines - 1,
                    start_col = 2,
                    end_col = #lines[#lines],
                    group = target == vim.api.nvim_get_current_buf() and "PiSessionsListCurrent" or "Normal",
                    suffix = status,
                }
                if icon_highlight then
                    highlights[#highlights + 1] = {
                        line = #lines - 1,
                        start_col = 2,
                        end_col = 2 + #icon,
                        group = icon_highlight,
                    }
                end
            end
        end
    end
    if #lines == 0 then
        lines = { "  (no workspaces)" }
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, hl in ipairs(highlights) do
        local opts = {
            end_col = hl.end_col,
            hl_group = hl.group,
        }
        if hl.suffix and hl.suffix ~= "" then
            opts.virt_text = { { hl.suffix, "Comment" } }
            opts.virt_text_pos = "right_align"
        end
        vim.api.nvim_buf_set_extmark(buf, ns, hl.line, hl.start_col, opts)
    end
    vim.bo[buf].modifiable = false
end

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

function M.setup()
    local group = vim.api.nvim_create_augroup("PiWorkspaceSidebar", { clear = true })
    vim.api.nvim_create_autocmd(
        { "BufAdd", "BufDelete", "BufEnter", "BufModifiedSet", "BufWipeout", "TabEnter", "TabClosed", "DirChanged" },
        {
            group = group,
            callback = M.request_refresh,
        }
    )
end

function M.open()
    local tab = current_tab()
    local existing = win_for(tab)
    if existing then
        vim.api.nvim_set_current_win(existing)
        return
    end
    local cfg = Config.options.workspace_sidebar
    local cmd = cfg.position == "left" and "topleft" or "botright"
    vim.cmd(("%s %dvsplit"):format(cmd, cfg.width))
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, ensure_buf())
    set_win_opts(win)
    wins[tab] = win
    M._render()
end

function M.close()
    local tab = current_tab()
    local win = win_for(tab)
    if not win then
        return
    end
    close_help(win)
    wins[tab] = nil
    pcall(vim.api.nvim_win_close, win, false)
end

function M.toggle()
    if win_for(current_tab()) then
        M.close()
    else
        M.open()
    end
end

function M._reset()
    for _, win in pairs(wins) do
        close_help(win)
        if vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    buf = nil
    wins = {}
    expanded = {}
    line_items = {}
    help_wins = {}
    refresh_scheduled = false
end

return M
