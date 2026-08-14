-- Unit tests for pi.ui.render engine resolution (pure config logic, no plugin).

local Config = require("pi.config")
local Render = require("pi.ui.render")

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
    local original_buf
    local history_buf

    before_each(function()
        original_markview = package.loaded.markview
        original_buf = vim.api.nvim_get_current_buf()
        Config.options.render = { engine = "markview" }
    end)

    after_each(function()
        if original_buf and vim.api.nvim_buf_is_valid(original_buf) then
            vim.api.nvim_win_set_buf(0, original_buf)
        end
        if history_buf and vim.api.nvim_buf_is_valid(history_buf) then
            vim.api.nvim_buf_delete(history_buf, { force = true })
        end
        package.loaded.markview = original_markview
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
