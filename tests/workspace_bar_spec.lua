local Config = require("pi.config")
local WorkspaceBar = require("pi.ui.workspaces")

Config.setup({})

describe("workspace bar", function()
    local start_tab
    local start_cwd
    local start_tabline
    local start_showtabline
    local dirs
    local original_sessions
    local original_attention
    local original_bufferline
    local original_bufferline_config

    before_each(function()
        start_tab = vim.api.nvim_get_current_tabpage()
        start_cwd = vim.fn.getcwd()
        start_tabline = vim.o.tabline
        start_showtabline = vim.o.showtabline
        dirs = { vim.fn.tempname(), vim.fn.tempname() }
        vim.fn.mkdir(dirs[1], "p")
        vim.fn.mkdir(dirs[2], "p")
        dirs[1] = assert(vim.uv.fs_realpath(dirs[1]))
        dirs[2] = assert(vim.uv.fs_realpath(dirs[2]))
        vim.cmd("tcd " .. vim.fn.fnameescape(dirs[1]))

        original_sessions = package.loaded["pi.sessions.manager"]
        original_attention = package.loaded["pi.attention"]
        original_bufferline = rawget(_G, "nvim_bufferline")
        original_bufferline_config = package.loaded["bufferline.config"]
        package.loaded["pi.sessions.manager"] = {
            list = function()
                return {}
            end,
        }
        package.loaded["pi.attention"] = {
            count_for_session = function()
                return 0
            end,
        }
    end)

    after_each(function()
        package.loaded["pi.sessions.manager"] = original_sessions
        package.loaded["pi.attention"] = original_attention
        rawset(_G, "nvim_bufferline", original_bufferline)
        WorkspaceBar._reset()
        package.loaded["bufferline.config"] = original_bufferline_config
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            if tab ~= start_tab and vim.api.nvim_tabpage_is_valid(tab) then
                vim.api.nvim_set_current_tabpage(tab)
                vim.cmd("tabclose!")
            end
        end
        vim.api.nvim_set_current_tabpage(start_tab)
        vim.cmd("tcd " .. vim.fn.fnameescape(start_cwd))
        vim.o.tabline = start_tabline
        vim.o.showtabline = start_showtabline
        for _, dir in ipairs(dirs) do
            vim.fn.delete(dir, "rf")
        end
        Config.setup({})
    end)

    it("lists tab-local cwd workspaces in tabline order", function()
        vim.cmd("tabnew")
        local second_tab = vim.api.nvim_get_current_tabpage()
        vim.cmd("tcd " .. vim.fn.fnameescape(dirs[2]))

        local rows = WorkspaceBar.list()
        assert.are.equal(2, #rows)
        assert.are.equal(start_tab, rows[1].tab)
        assert.are.equal(dirs[1], rows[1].cwd)
        assert.are.equal(second_tab, rows[2].tab)
        assert.are.equal(dirs[2], rows[2].cwd)
    end)

    it("aggregates sessions by workspace cwd and renders clickable tabs", function()
        vim.cmd("tabnew")
        vim.cmd("tcd " .. vim.fn.fnameescape(dirs[2]))
        package.loaded["pi.sessions.manager"] = {
            list = function()
                return {
                    {
                        cwd = dirs[1],
                        chat = {
                            is_streaming = function()
                                return true
                            end,
                            is_compacting = function()
                                return false
                            end,
                        },
                    },
                    {
                        cwd = dirs[1],
                        chat = {
                            is_streaming = function()
                                return false
                            end,
                            is_compacting = function()
                                return false
                            end,
                        },
                    },
                }
            end,
        }

        local rows = WorkspaceBar.list()
        assert.are.equal(2, rows[1].sessions)
        assert.are.equal("busy", rows[1].status)
        assert.are.equal(0, rows[2].sessions)
        assert.is_truthy(WorkspaceBar.tabline():find("%%1T", 1, false))
        assert.is_truthy(WorkspaceBar.tabline():find(" 2 ●", 1, true))
    end)

    it("keeps session counts with their creating workspace when cwd matches", function()
        vim.cmd("tabnew")
        local second_tab = vim.api.nvim_get_current_tabpage()
        vim.cmd("tcd " .. vim.fn.fnameescape(dirs[1]))
        package.loaded["pi.sessions.manager"] = {
            list = function()
                return {
                    {
                        workspace_tab = second_tab,
                        cwd = dirs[1],
                        chat = {
                            is_streaming = function()
                                return false
                            end,
                            is_compacting = function()
                                return false
                            end,
                        },
                    },
                }
            end,
        }

        local rows = WorkspaceBar.list()
        assert.are.equal(0, rows[1].sessions)
        assert.are.equal(1, rows[2].sessions)
    end)

    it("switches tabs through the workspace picker", function()
        vim.cmd("tabnew")
        local second_tab = vim.api.nvim_get_current_tabpage()
        vim.cmd("tcd " .. vim.fn.fnameescape(dirs[2]))
        vim.api.nvim_set_current_tabpage(start_tab)

        local original_select = vim.ui.select
        vim.ui.select = function(items, _, callback)
            callback(items[2])
        end
        WorkspaceBar.select()
        vim.ui.select = original_select

        assert.are.equal(second_tab, vim.api.nvim_get_current_tabpage())
    end)

    it("creates a workspace from a selected directory", function()
        local original_input = vim.ui.input
        vim.ui.input = function(options, callback)
            assert.are.equal("dir", options.completion)
            assert.are.equal(dirs[1], options.default)
            callback(dirs[2])
        end

        WorkspaceBar.create()
        vim.ui.input = original_input

        assert.are.equal(2, #vim.api.nvim_list_tabpages())
        assert.are.equal(dirs[2], require("pi.workspace").cwd(vim.api.nvim_get_current_tabpage()))
    end)

    it("does not create a workspace when path selection is cancelled or invalid", function()
        local original_input = vim.ui.input
        local original_notify = package.loaded["pi.notify"]
        local error_message
        package.loaded["pi.notify"] = {
            error = function(message)
                error_message = message
            end,
        }
        vim.ui.input = function(_, callback)
            callback(nil)
        end
        WorkspaceBar.create()
        assert.are.equal(1, #vim.api.nvim_list_tabpages())

        vim.ui.input = function(_, callback)
            callback(dirs[1] .. "/missing")
        end
        WorkspaceBar.create()
        vim.ui.input = original_input
        package.loaded["pi.notify"] = original_notify

        assert.are.equal(1, #vim.api.nvim_list_tabpages())
        assert.is_truthy(error_message:find("Workspace path is not a directory", 1, true))
    end)

    it("yields tabline visibility when bufferline loads later", function()
        Config.setup({ workspace_bar = { enabled = true, show = "multiple" } })
        vim.o.tabline = ""
        WorkspaceBar.setup()
        assert.are.equal("%!v:lua.require'pi.ui.workspaces'.tabline()", vim.o.tabline)

        rawset(_G, "nvim_bufferline", function()
            return ""
        end)
        package.loaded["bufferline.config"] = { options = {} }
        vim.o.tabline = "%!v:lua.nvim_bufferline()"
        vim.o.showtabline = 2

        WorkspaceBar.refresh()

        assert.are.equal("%!v:lua.nvim_bufferline()", vim.o.tabline)
        assert.are.equal(2, vim.o.showtabline)
    end)

    it("adapts bufferline before its global renderer is registered", function()
        rawset(_G, "nvim_bufferline", nil)
        local bufferline_config = { options = { show_tab_indicators = true } }
        package.loaded["bufferline.config"] = bufferline_config
        vim.o.tabline = "%!v:lua.my_bufferline_renderer()"

        WorkspaceBar.setup()

        assert.is_false(bufferline_config.options.show_tab_indicators)
        assert.are.equal("function", type(bufferline_config.options.custom_areas.right))
    end)

    it("reapplies integration after bufferline replaces its options", function()
        rawset(_G, "nvim_bufferline", function()
            return ""
        end)
        local bufferline_config = { options = { show_tab_indicators = true } }
        package.loaded["bufferline.config"] = bufferline_config
        vim.o.tabline = "%!v:lua.nvim_bufferline()"
        WorkspaceBar.setup()

        bufferline_config.options = { show_tab_indicators = true }
        WorkspaceBar.refresh()

        assert.is_false(bufferline_config.options.show_tab_indicators)
        assert.are.equal("function", type(bufferline_config.options.custom_areas.right))
    end)

    it("appends clickable workspaces to bufferline's right custom area", function()
        vim.cmd("tabnew")
        vim.cmd("tcd " .. vim.fn.fnameescape(dirs[2]))
        rawset(_G, "nvim_bufferline", function()
            return ""
        end)
        local original_right = function()
            return { { text = " existing ", link = "BufferLineFill" } }
        end
        local original_areas = { right = original_right }
        local bufferline_config = { options = { custom_areas = original_areas, show_tab_indicators = true } }
        package.loaded["bufferline.config"] = bufferline_config
        vim.o.tabline = "%!v:lua.nvim_bufferline()"

        WorkspaceBar.setup()

        assert.are.equal("%!v:lua.nvim_bufferline()", vim.o.tabline)
        assert.is_false(bufferline_config.options.show_tab_indicators)
        local area = bufferline_config.options.custom_areas.right()
        assert.are.equal(" existing ", area[1].text)
        assert.is_truthy(area[2].text:find("%1T", 1, true))
        assert.is_truthy(area[2].text:find(vim.fs.basename(dirs[1]), 1, true))
        assert.is_falsy(area[2].text:find(dirs[1], 1, true))
        assert.is_truthy(area[3].text:find("%2T", 1, true))
        assert.is_truthy(area[3].text:find(vim.fs.basename(dirs[2]), 1, true))

        WorkspaceBar._reset()
        assert.are.equal(original_areas, bufferline_config.options.custom_areas)
        assert.is_true(bufferline_config.options.show_tab_indicators)
    end)

    it("supports path, index, and custom workspace labels", function()
        Config.setup({
            workspace_bar = {
                label = "path",
                show_index = true,
                session_count = false,
                status = false,
            },
        })
        local path = WorkspaceBar.tabline()
        assert.is_truthy(path:find(" 1 " .. dirs[1] .. " ", 1, true))

        Config.setup({
            workspace_bar = {
                label = function(row)
                    return "workspace:" .. row.name
                end,
                show_index = false,
                session_count = false,
                status = false,
            },
        })
        local custom = WorkspaceBar.tabline()
        assert.is_truthy(custom:find(" workspace:" .. vim.fs.basename(dirs[1]) .. " ", 1, true))
    end)

    it("shows session count and busy state in bufferline's workspace area", function()
        rawset(_G, "nvim_bufferline", function()
            return ""
        end)
        local bufferline_config = { options = {} }
        package.loaded["bufferline.config"] = bufferline_config
        vim.o.tabline = "%!v:lua.nvim_bufferline()"
        package.loaded["pi.sessions.manager"] = {
            list = function()
                return {
                    {
                        workspace_tab = start_tab,
                        cwd = dirs[1],
                        chat = {
                            is_streaming = function()
                                return true
                            end,
                            is_compacting = function()
                                return false
                            end,
                        },
                    },
                }
            end,
        }

        WorkspaceBar.setup()
        local area = bufferline_config.options.custom_areas.right()
        assert.is_truthy(area[1].text:find(" 1 ●", 1, true))
    end)

    it("does not replace another custom tabline", function()
        vim.o.tabline = "custom"
        WorkspaceBar.setup()
        assert.are.equal("custom", vim.o.tabline)
    end)
end)
