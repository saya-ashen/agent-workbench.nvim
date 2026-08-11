local Workspace = require("pi.workspace")
local Config = require("pi.config")
local History = require("pi.ui.chat.history")

Config.setup({})

describe("agent workspace", function()
    it("uses buffer layout and markview by default", function()
        assert.are.equal("buffer", Config.resolve_default_layout_mode())
        assert.are.equal("markview", require("pi.ui.render").engine())
    end)

    it("builds stable session URIs", function()
        assert.are.equal("agent://project/session-123/transcript", Workspace.uri("/tmp/project", "/tmp/session-123.jsonl", 7))
        assert.are.equal("agent://project/new-7/transcript", Workspace.uri("/tmp/project", nil, 7))
        local project, session, resource = Workspace.parse("agent://project/session-123/transcript")
        assert.are.same({ "project", "session-123", "transcript" }, { project, session, resource })
    end)

    it("uses a listed history buffer with stable identity", function()
        Config.options.render.engine = "builtin"
        local history = History.new(vim.api.nvim_get_current_tabpage(), "agent://project/new-1")
        local buf = history:buf()

        assert.is_true(vim.bo[buf].buflisted)
        assert.are.equal("nofile", vim.bo[buf].buftype)
        assert.are.equal("agent://project/new-1", vim.api.nvim_buf_get_name(buf))

        history:set_name("agent://project/session-123")
        assert.are.equal("agent://project/session-123", vim.api.nvim_buf_get_name(buf))

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("folds user and assistant messages from their timestamp headers", function()
        Config.options.render.engine = "builtin"
        local history = History.new(vim.api.nvim_get_current_tabpage(), "agent://project/folds/transcript")
        vim.api.nvim_win_set_buf(0, history:buf())
        history:set_win(0)

        history:add_user_message("question one\nquestion two", 1786438920000)
        history:on_agent_start(1786438920000)
        history:on_text_delta("answer one\nanswer two")
        history:on_agent_end()
        vim.wait(200)

        assert.are.equal(2, #history._message_blocks)
        local user_row = history:_extmark_row(history._message_blocks[1].anchor) + 1
        local assistant_row = history:_extmark_row(history._message_blocks[2].anchor) + 1
        assert.are.equal(">1", History.nvim_foldexpr(user_row))
        assert.are.equal(1, History.nvim_foldexpr(user_row + 1))
        assert.are.equal(">1", History.nvim_foldexpr(assistant_row))

        history:clear()
        assert.are.equal(0, #history._message_blocks)
        vim.api.nvim_buf_delete(history:buf(), { force = true })
    end)

    it("restores editor buffer after hiding buffer layout", function()
        local Attachments = require("pi.ui.chat.attachments")
        local Prompt = require("pi.ui.chat.prompt")
        local Layout = require("pi.ui.chat.layout")
        local attachments = Attachments.new()
        local history = History.new(vim.api.nvim_get_current_tabpage(), "agent://project/new-2/transcript")
        history:_with_modifiable(function()
            vim.api.nvim_buf_set_lines(history:buf(), 0, -1, false, { "header", "body", "end" })
        end)
        history._startup_block_line_count = 3
        local prompt = Prompt.new(vim.api.nvim_get_current_tabpage(), attachments)
        local layout = Layout.new("buffer", history, prompt, attachments)
        local original = vim.api.nvim_get_current_buf()
        vim.go.number = true
        vim.go.relativenumber = true
        vim.wo.number = false
        vim.wo.relativenumber = true

        assert.is_true(layout:show())
        local history_win = layout:history_win()
        assert.are.equal(history:buf(), vim.api.nvim_win_get_buf(history_win))
        assert.is_true(vim.wo[history_win].number)
        assert.is_true(vim.wo[history_win].relativenumber)
        assert.are.equal("expr", vim.wo[history_win].foldmethod)
        assert.are.equal("1", vim.wo[history_win].foldcolumn)
        vim.api.nvim_set_current_win(history_win)
        assert.are.equal(">1", History.nvim_foldexpr(1))
        assert.are.equal(1, History.nvim_foldexpr(2))
        assert.are.equal("<1", History.nvim_foldexpr(3))
        assert.is_not_nil(layout:prompt_win())

        layout:hide()
        assert.are.equal(original, vim.api.nvim_get_current_buf())
        assert.is_false(vim.wo.number)
        assert.is_true(vim.wo.relativenumber)

        vim.api.nvim_buf_delete(history:buf(), { force = true })
        vim.api.nvim_buf_delete(prompt:buf(), { force = true })
        vim.api.nvim_buf_delete(attachments:buf(), { force = true })
    end)
end)
