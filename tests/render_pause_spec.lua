local Config = require("agent-workbench.config")
local Render = require("agent-workbench.ui.render")

describe("render pause/resume", function()
    after_each(function()
        Config.options.render = { markdown = { enabled = true, debounce_ms = 30, features = {}, symbols = {} } }
        Render._reset()
    end)

    it("defaults to the isolated Markdown renderer", function()
        Config.options.render = { markdown = { enabled = true } }
        assert.equals("markdown", Render.engine())
    end)

    it("pause/resume are safe when Markdown rendering is disabled", function()
        Config.options.render = { markdown = { enabled = false } }
        local buf = vim.api.nvim_create_buf(false, true)
        assert.has_no.errors(function()
            Render.pause_history(buf)
            Render.resume_history(buf)
        end)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("removed engines degrade to raw text without throwing", function()
        for _, engine in ipairs({ "builtin", "render-markdown" }) do
            Config.options.render = { engine = engine, markdown = { enabled = true } }
            local buf = vim.api.nvim_create_buf(false, true)
            assert.are.equal("raw", Render.engine())
            assert.has_no.errors(function()
                Render.pause_history(buf)
                Render.resume_history(buf)
            end)
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end)

    it("pause/resume ignore an invalid buffer", function()
        assert.has_no.errors(function()
            Render.pause_history(999999)
            Render.resume_history(999999)
        end)
    end)
end)
