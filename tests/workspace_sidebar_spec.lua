local Config = require("pi.config")
local Sidebar = require("pi.ui.workspace_sidebar")
local SessionsUi = require("pi.ui.sessions")

Config.setup({})

describe("workspace sidebar", function()
    local start_tab
    local second_tab
    local start_cwd
    local dirs
    local original_workspaces
    local original_sessions
    local original_attention
    local original_workspace_buffers
    local original_devicons
    local original_confirm
    local activated
    local focused_session
    local created_session
    local created_workspace

    local function session(id, tab, state)
        return {
            id = id,
            workspace_tab = tab,
            cwd = dirs[tab == start_tab and 1 or 2],
            rpc = {
                is_running = function()
                    return state ~= "exited"
                end,
            },
            chat = {
                is_streaming = function()
                    return state == "busy"
                end,
                is_compacting = function()
                    return state == "compacting"
                end,
                focus_for_session_entry = function()
                    focused_session = id
                end,
            },
        }
    end

    local function callback_for(buf, lhs)
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            if map.lhs == lhs then
                return map.callback
            end
        end
        error("missing mapping: " .. lhs)
    end

    before_each(function()
        start_tab = vim.api.nvim_get_current_tabpage()
        start_cwd = vim.fn.getcwd()
        dirs = { vim.fn.tempname(), vim.fn.tempname() }
        vim.fn.mkdir(dirs[1], "p")
        vim.fn.mkdir(dirs[2], "p")
        dirs[1] = assert(vim.uv.fs_realpath(dirs[1]))
        dirs[2] = assert(vim.uv.fs_realpath(dirs[2]))
        vim.cmd("tcd " .. vim.fn.fnameescape(dirs[1]))
        vim.cmd("tabnew")
        second_tab = vim.api.nvim_get_current_tabpage()
        vim.cmd("tcd " .. vim.fn.fnameescape(dirs[2]))
        vim.api.nvim_set_current_tabpage(start_tab)

        original_workspaces = package.loaded["pi.ui.workspaces"]
        original_sessions = package.loaded["pi.sessions.manager"]
        original_attention = package.loaded["pi.attention"]
        original_workspace_buffers = package.loaded["pi.workspace_buffers"]
        original_devicons = package.loaded["nvim-web-devicons"]
        original_confirm = require("pi.ui.dialog").confirm
        local sessions = { session(11, start_tab, "busy"), session(22, second_tab, "idle") }
        SessionsUi.on_session_info_changed(sessions[1], "Build authentication flow")
        SessionsUi.on_session_info_changed(sessions[2], "Review release")
        package.loaded["pi.ui.workspaces"] = {
            list = function()
                return {
                    {
                        tab = start_tab,
                        index = 1,
                        cwd = dirs[1],
                        name = vim.fs.basename(dirs[1]),
                        sessions = 1,
                        status = "busy",
                    },
                    {
                        tab = second_tab,
                        index = 2,
                        cwd = dirs[2],
                        name = vim.fs.basename(dirs[2]),
                        sessions = 1,
                        status = "idle",
                    },
                }
            end,
            create = function()
                created_workspace = true
            end,
        }
        package.loaded["pi.sessions.manager"] = {
            list = function()
                return sessions
            end,
            activate = function(value)
                activated = value
            end,
            new_session = function()
                created_session = vim.api.nvim_get_current_tabpage()
            end,
        }
        package.loaded["pi.attention"] = {
            count_for_session = function()
                return 0
            end,
        }
        package.loaded["pi.workspace_buffers"] = {
            list = function()
                return {}
            end,
        }
        Config.setup({ workspace_sidebar = { position = "right", width = 32 } })
    end)

    after_each(function()
        Sidebar._reset()
        package.loaded["pi.ui.workspaces"] = original_workspaces
        package.loaded["pi.sessions.manager"] = original_sessions
        package.loaded["pi.attention"] = original_attention
        package.loaded["pi.workspace_buffers"] = original_workspace_buffers
        package.loaded["nvim-web-devicons"] = original_devicons
        require("pi.ui.dialog").confirm = original_confirm
        if vim.api.nvim_tabpage_is_valid(second_tab) and #vim.api.nvim_list_tabpages() > 1 then
            vim.api.nvim_set_current_tabpage(second_tab)
            vim.cmd("tabclose!")
        end
        if vim.api.nvim_tabpage_is_valid(start_tab) then
            vim.api.nvim_set_current_tabpage(start_tab)
        end
        vim.cmd("tcd " .. vim.fn.fnameescape(start_cwd))
        for _, dir in ipairs(dirs) do
            vim.fn.delete(dir, "rf")
        end
        Config.setup({})
        activated = nil
        focused_session = nil
        created_session = nil
        created_workspace = nil
    end)

    it("renders compact tree-style workspace rows", function()
        Sidebar.open()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

        assert.are.equal(32, vim.api.nvim_win_get_width(win))
        assert.are.equal(2, #lines)
        assert.are.equal(" 󰙅 " .. vim.fn.fnamemodify(dirs[1], ":~"), lines[1])
        assert.are.equal(" 󰙅 " .. vim.fn.fnamemodify(dirs[2], ":~"), lines[2])
        assert.are.equal("pi-workspaces", vim.bo[buf].filetype)
    end)

    it("expands sessions and activates one under the cursor", function()
        Sidebar.open()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        callback_for(buf, "<Tab>")()

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal(" 󰙅 " .. vim.fn.fnamemodify(dirs[1], ":~"), lines[1])
        assert.are.equal("  󰔟 Build authentic…", lines[2])
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
        callback_for(buf, "<CR>")()
        assert.are.equal(11, activated.id)
        assert.are.equal(11, focused_session)
    end)

    it("opens from a History-only workspace without creating another window", function()
        local history = vim.api.nvim_create_buf(true, false)
        vim.bo[history].filetype = "pi-history"
        vim.api.nvim_set_current_buf(history)
        Sidebar.open()
        local sidebar_win = vim.api.nvim_get_current_win()
        local sidebar_buf = vim.api.nvim_win_get_buf(sidebar_win)
        callback_for(sidebar_buf, "l")()
        vim.api.nvim_win_set_cursor(sidebar_win, { 2, 0 })
        local windows_before = #vim.api.nvim_tabpage_list_wins(start_tab)

        callback_for(sidebar_buf, "l")()

        assert.are.equal(windows_before, #vim.api.nvim_tabpage_list_wins(start_tab))
        assert.are.equal(11, activated.id)
        assert.are.equal(11, focused_session)
        vim.api.nvim_buf_delete(history, { force = true })
    end)

    it("renders session and ordinary buffers in one workspace tree", function()
        local history = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(history, dirs[1] .. "/session-history")
        vim.bo[history].filetype = "pi-history"
        vim.api.nvim_set_current_buf(history)
        local file = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(file, dirs[1] .. "/offer-letter.md")
        package.loaded["pi.workspace_buffers"] = {
            list = function(tab)
                return tab == start_tab and { file } or {}
            end,
        }
        package.loaded["nvim-web-devicons"] = {
            get_icon = function()
                return "󰍔", "TestMarkdownIcon"
            end,
        }
        Sidebar.open()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        callback_for(buf, "l")()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal("  󰔟 Build authentic…", lines[2])
        assert.are.equal("  󰍔 offer-letter.md", lines[3])
        local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { 2, 0 }, { 2, -1 }, { details = true })
        assert.is_true(vim.iter(marks):any(function(mark)
            return mark[4].hl_group == "TestMarkdownIcon"
        end))

        vim.api.nvim_win_set_cursor(win, { 3, 0 })
        local windows_before = #vim.api.nvim_tabpage_list_wins(start_tab)
        callback_for(buf, "<CR>")()
        assert.are.equal(file, vim.api.nvim_get_current_buf())
        assert.are.equal(windows_before, #vim.api.nvim_tabpage_list_wins(start_tab))
        vim.api.nvim_buf_delete(history, { force = true })
        vim.api.nvim_buf_delete(file, { force = true })
    end)

    it("toggles workspaces with h and l while keeping session actions directional", function()
        Sidebar.open()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)

        callback_for(buf, "l")()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal(" 󰙅 " .. vim.fn.fnamemodify(dirs[1], ":~"), lines[1])

        callback_for(buf, "l")()
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal(" 󰙅 " .. vim.fn.fnamemodify(dirs[1], ":~"), lines[1])

        callback_for(buf, "h")()
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal(" 󰙅 " .. vim.fn.fnamemodify(dirs[1], ":~"), lines[1])

        callback_for(buf, "h")()
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal(" 󰙅 " .. vim.fn.fnamemodify(dirs[1], ":~"), lines[1])

        callback_for(buf, "e")()
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
        callback_for(buf, "h")()
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal(1, vim.api.nvim_win_get_cursor(win)[1])
        assert.are.equal(" 󰙅 " .. vim.fn.fnamemodify(dirs[1], ":~"), lines[1])

        callback_for(buf, "e")()
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
        callback_for(buf, "l")()
        assert.are.equal(11, activated.id)
    end)

    it("shows attention before busy session state", function()
        package.loaded["pi.attention"].count_for_session = function(value)
            return value.id == 11 and 1 or 0
        end
        Sidebar.open()
        local buf = vim.api.nvim_get_current_buf()
        callback_for(buf, "l")()

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal("   Build authentic…", lines[2])
        local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { 1, 0 }, { 1, -1 }, { details = true })
        assert.are.equal("attention", marks[1][4].virt_text[1][1])
    end)

    it("confirms before deleting a session but deletes ordinary buffers directly", function()
        local session_buf = vim.api.nvim_create_buf(true, false)
        package.loaded["pi.sessions.manager"].list()[1].history_buf = session_buf
        Sidebar.open()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        callback_for(buf, "l")()
        local confirmed
        require("pi.ui.dialog").confirm = function(opts, callback)
            confirmed = opts.title
            callback(false)
        end
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
        callback_for(buf, "d")()
        assert.are.equal("Stop session and delete buffer", confirmed)
        vim.api.nvim_buf_delete(session_buf, { force = true })

        local file = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(file, dirs[1] .. "/delete-me.txt")
        package.loaded["pi.workspace_buffers"] = {
            list = function(tab)
                return tab == start_tab and { file } or {}
            end,
        }
        Sidebar._render()
        vim.api.nvim_win_set_cursor(win, { 3, 0 })
        callback_for(buf, "d")()
        assert.is_false(vim.api.nvim_buf_is_valid(file))
    end)

    it("shows session titles, state icons, and full running state", function()
        Sidebar.open()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        callback_for(buf, "l")()

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal("  󰔟 Build authentic…", lines[2])
        local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { 1, 0 }, { 1, -1 }, { details = true })
        assert.are.equal("running", marks[1][4].virt_text[1][1])

        vim.api.nvim_win_set_cursor(win, { 3, 0 })
        callback_for(buf, "l")()
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal("  󰄬 Review release", lines[4])
    end)

    it("creates sessions and workspaces with tree-style keys", function()
        Sidebar.open()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
        callback_for(buf, "a")()
        assert.are.equal(second_tab, created_session)
        callback_for(buf, "A")()
        assert.is_true(created_workspace)
    end)

    it("toggles a help overlay with question mark and escape", function()
        Sidebar.open()
        local buf = vim.api.nvim_get_current_buf()
        local before = #vim.api.nvim_list_wins()
        callback_for(buf, "?")()
        assert.are.equal(before + 1, #vim.api.nvim_list_wins())
        callback_for(buf, "<Esc>")()
        assert.are.equal(before, #vim.api.nvim_list_wins())
    end)

    it("switches workspace and toggles the sidebar closed", function()
        Sidebar.open()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
        callback_for(buf, "<CR>")()
        assert.are.equal(second_tab, vim.api.nvim_get_current_tabpage())

        vim.api.nvim_set_current_tabpage(start_tab)
        Sidebar.toggle()
        assert.is_false(vim.api.nvim_win_is_valid(win))
    end)

    it("switches to a session's workspace before activation", function()
        Sidebar.open()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
        callback_for(buf, "<Tab>")()
        vim.api.nvim_win_set_cursor(win, { 3, 0 })
        callback_for(buf, "<CR>")()

        assert.are.equal(second_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(22, activated.id)
    end)
end)
