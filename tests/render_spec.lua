-- Unit tests for pi.ui.render engine resolution (pure config logic, no plugin).

local Config = require("agent-workbench.config")
local Render = require("agent-workbench.ui.render")

describe("render engine resolution", function()
    after_each(function()
        -- restore the default so tests don't leak state
        Config.options.render = { engine = "builtin" }
        Render._reset()
    end)

    it("defaults to builtin", function()
        Config.options.render = nil
        assert.are.equal("builtin", Render.engine())
    end)

    it("reads an explicit engine", function()
        Config.options.render = { engine = "render-markdown" }
        assert.are.equal("render-markdown", Render.engine())
    end)

    it("treats a missing engine key as builtin", function()
        Config.options.render = {}
        assert.are.equal("builtin", Render.engine())
    end)
end)

describe("markview history visibility", function()
    local original_markview
    local original_markview_spec
    local original_buf
    local history_buf

    before_each(function()
        original_markview = package.loaded.markview
        original_markview_spec = package.loaded["markview.spec"]
        original_buf = vim.api.nvim_get_current_buf()
        Config.options.render = { engine = "markview", markview = {} }
    end)

    after_each(function()
        if original_buf and vim.api.nvim_buf_is_valid(original_buf) then
            vim.api.nvim_win_set_buf(0, original_buf)
        end
        if history_buf and vim.api.nvim_buf_is_valid(history_buf) then
            vim.api.nvim_buf_delete(history_buf, { force = true })
        end
        package.loaded.markview = original_markview
        package.loaded["markview.spec"] = original_markview_spec
        Config.options.render = { engine = "builtin" }
        Render._reset()
    end)

    it("renders only after a hidden History buffer becomes visible", function()
        local renders = 0
        package.loaded.markview = {
            clear = function() end,
            render = function()
                renders = renders + 1
            end,
        }
        history_buf = vim.api.nvim_create_buf(true, true)

        Render.attach_history(history_buf)
        Render.refresh_history(history_buf)
        vim.wait(20)
        assert.are.equal(0, renders)

        vim.api.nvim_win_set_buf(0, history_buf)
        vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = history_buf })
        vim.wait(20)
        assert.are.equal(1, renders)

        vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = history_buf })
        vim.wait(20)
        assert.are.equal(1, renders, "unchanged History must keep its cached render")

        vim.bo[history_buf].modifiable = true
        vim.api.nvim_buf_set_lines(history_buf, 0, -1, false, { "changed" })
        vim.bo[history_buf].modifiable = false
        Render.refresh_history(history_buf)
        vim.wait(20)
        assert.are.equal(2, renders)

        vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = history_buf })
        vim.wait(20)
        assert.are.equal(2, renders, "re-entry must not render unchanged History again")
    end)

    it("defers rendering when replay resumes", function()
        local renders = 0
        package.loaded.markview = {
            clear = function() end,
            render = function()
                renders = renders + 1
            end,
        }
        history_buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_win_set_buf(0, history_buf)

        Render.attach_history(history_buf)
        vim.wait(20)
        assert.are.equal(1, renders)

        Render.pause_history(history_buf)
        vim.bo[history_buf].modifiable = true
        vim.api.nvim_buf_set_lines(history_buf, 0, -1, false, { "complete replay" })
        vim.bo[history_buf].modifiable = false
        Render.refresh_history(history_buf)
        Render.resume_history(history_buf)
        assert.are.equal(1, renders, "resume must not block on Markdown rendering")
        vim.wait(20)
        assert.are.equal(2, renders)
    end)

    it("defers rendering in a background tab until that workspace is current", function()
        local renders = 0
        package.loaded.markview = {
            clear = function() end,
            render = function()
                renders = renders + 1
            end,
        }
        history_buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_win_set_buf(0, history_buf)
        local owner_tab = vim.api.nvim_get_current_tabpage()

        Render.attach_history(history_buf)
        vim.wait(20)
        assert.are.equal(1, renders)

        vim.cmd("tabnew")
        local foreground_tab = vim.api.nvim_get_current_tabpage()
        vim.bo[history_buf].modifiable = true
        vim.api.nvim_buf_set_lines(history_buf, 0, -1, false, { "background change" })
        vim.bo[history_buf].modifiable = false
        Render.refresh_history(history_buf)
        vim.wait(20)
        assert.are.equal(1, renders)

        vim.api.nvim_set_current_tabpage(owner_tab)
        Render.refresh_history(history_buf)
        vim.wait(20)
        assert.are.equal(2, renders)

        vim.api.nvim_set_current_tabpage(foreground_tab)
        vim.cmd("tabclose!")
        vim.api.nvim_set_current_tabpage(owner_tab)
    end)

    it("uses Markview's global config by default and debounces cursor movement", function()
        local renders = 0
        local render_arg_count
        package.loaded.markview = {
            clear = function() end,
            render = function(_, ...)
                renders = renders + 1
                render_arg_count = select("#", ...)
            end,
        }
        history_buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_win_set_buf(0, history_buf)

        Render.attach_history(history_buf)
        vim.wait(20)
        assert.are.equal(1, renders)
        assert.are.equal(0, render_arg_count, "no state or config override should bypass Markview globals")

        for _ = 1, 3 do
            vim.api.nvim_exec_autocmds("CursorMoved", { buffer = history_buf })
        end
        vim.wait(10)
        assert.are.equal(1, renders)
        assert.is_true(vim.wait(100, function()
            return renders == 2
        end))

        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = history_buf })
        vim.api.nvim_win_set_buf(0, original_buf)
        vim.wait(50)
        assert.are.equal(2, renders, "hidden History must drop a pending cursor render")
    end)

    it("applies Markview's global preview callbacks to History windows", function()
        local global_config = {
            preview = {
                enable = true,
                enable_hybrid_mode = true,
                callbacks = {
                    on_enable = function(_, windows)
                        vim.wo[windows[1]].conceallevel = 3
                    end,
                    on_hybrid_enable = function(_, windows)
                        vim.wo[windows[1]].concealcursor = "c"
                    end,
                },
            },
        }
        package.loaded["markview.spec"] = {
            config = global_config,
            get = function(keys, opts)
                local value = global_config
                for _, key in ipairs(keys) do
                    value = type(value) == "table" and value[key] or nil
                end
                return value == nil and opts.fallback or value
            end,
        }
        package.loaded.markview = {
            clear = function() end,
            render = function() end,
        }
        history_buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_win_set_buf(0, history_buf)
        vim.wo[0].conceallevel = 2
        vim.wo[0].concealcursor = "nvic"

        Render.configure_history_window(history_buf, 0)

        assert.are.equal(3, vim.wo[0].conceallevel)
        assert.are.equal("c", vim.wo[0].concealcursor)
    end)

    it("deep-merges History overrides over Markview's global config", function()
        local global_config = {
            preview = {
                enable = true,
                hybrid_modes = { "i" },
                linewise_hybrid_mode = false,
            },
            markdown = {
                headings = { enable = true, shift_width = 1 },
            },
        }
        package.loaded["markview.spec"] = { config = global_config }
        Config.options.render.markview = {
            preview = {
                hybrid_modes = { "n", "no", "c" },
                linewise_hybrid_mode = true,
            },
            markdown = {
                headings = { shift_width = 2 },
            },
        }

        local render_state
        local render_config
        package.loaded.markview = {
            clear = function() end,
            render = function(_, state, config)
                render_state = state
                render_config = config
            end,
        }
        history_buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_win_set_buf(0, history_buf)

        Render.attach_history(history_buf)
        vim.wait(20)

        assert.is_nil(render_state)
        assert.are.same({
            preview = {
                enable = true,
                hybrid_modes = { "n", "no", "c" },
                linewise_hybrid_mode = true,
            },
            markdown = {
                headings = { enable = true, shift_width = 2 },
            },
        }, render_config)
        assert.are.same({ "i" }, global_config.preview.hybrid_modes, "global Markview config must remain unchanged")
        assert.is_false(global_config.preview.linewise_hybrid_mode)
        assert.are.equal(1, global_config.markdown.headings.shift_width)
    end)

    it("retries an unchanged History after markview clear fails", function()
        local clears = 0
        local renders = 0
        package.loaded.markview = {
            clear = function()
                clears = clears + 1
                if clears == 1 then
                    error("clear failed")
                end
            end,
            render = function()
                renders = renders + 1
            end,
        }
        history_buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_win_set_buf(0, history_buf)

        Render.attach_history(history_buf)
        vim.wait(20)
        assert.are.equal(1, renders)
        assert.is_false(vim.b[history_buf].pi_markview)

        vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = history_buf })
        vim.wait(20)
        assert.are.equal(2, renders)
        assert.is_true(vim.b[history_buf].pi_markview)

        vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = history_buf })
        vim.wait(20)
        assert.are.equal(2, renders)
    end)
end)
