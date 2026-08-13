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
        assert.are.equal(
            "agent://project/session-123/transcript",
            Workspace.uri("/tmp/project", "/tmp/session-123.jsonl", 7)
        )
        assert.are.equal("agent://project/new-7/transcript", Workspace.uri("/tmp/project", nil, 7))
        local project, session, resource = Workspace.parse("agent://project/session-123/transcript")
        assert.are.same({ "project", "session-123", "transcript" }, { project, session, resource })
    end)

    it("uses a listed virtual history buffer with stable identity", function()
        Config.options.render.engine = "builtin"
        local history = History.new(vim.api.nvim_get_current_tabpage(), "agent://project/new-1")
        local buf = history:buf()

        assert.is_true(vim.bo[buf].buflisted)
        assert.are.equal("nofile", vim.bo[buf].buftype)
        assert.are.equal(
            vim.fn.getcwd() .. "/π session " .. vim.api.nvim_get_current_tabpage(),
            vim.api.nvim_buf_get_name(buf)
        )
        assert.are.equal(buf, Workspace.buffer("agent://project/new-1"))

        history:set_name("agent://project/session-123")
        assert.are.equal(
            vim.fn.getcwd() .. "/π session " .. vim.api.nvim_get_current_tabpage(),
            vim.api.nvim_buf_get_name(buf)
        )
        assert.is_nil(Workspace.buffer("agent://project/new-1"))
        assert.are.equal(buf, Workspace.buffer("agent://project/session-123"))

        vim.api.nvim_buf_delete(buf, { force = true })
        assert.is_nil(Workspace.buffer("agent://project/session-123"))
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
        assert.are.equal(-1, vim.fn.foldclosed(assistant_row), "completed output stays open")

        history:add_user_message("next question", 1786438921000)
        vim.wait(100)
        local next_user_row = history:_extmark_row(history._message_blocks[3].anchor) + 1
        assert.are.equal(-1, vim.fn.foldclosed(assistant_row), "recent output stays open after submit")
        assert.are.equal(-1, vim.fn.foldclosed(next_user_row), "new user message remains open")

        vim.cmd("belowright 1new")
        local other_win = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(history:win())
        vim.wait(20)
        assert.are.equal(-1, vim.fn.foldclosed(next_user_row), "focus changes preserve fold state")
        vim.api.nvim_win_close(other_win, true)

        local boundary_marks = vim.api.nvim_buf_get_extmarks(
            history:buf(),
            history:ns(),
            { next_user_row - 1, 0 },
            { next_user_row - 1, -1 },
            { details = true }
        )
        local boundary
        for _, mark in ipairs(boundary_marks) do
            if mark[4].virt_lines_above then
                boundary = mark[4].virt_lines
                break
            end
        end
        assert.is_not_nil(boundary, "turn boundary stays outside adjacent folds")
        assert.are.equal("  " .. string.rep("─", 32), boundary[1][1][1])
        assert.are.equal("PiBusyTime", boundary[1][1][2])

        history:clear()
        assert.are.equal(0, #history._message_blocks)
        vim.api.nvim_buf_delete(history:buf(), { force = true })
    end)

    it("folds agent activity while retaining two recent outputs", function()
        Config.options.render.engine = "builtin"
        local history = History.new(vim.api.nvim_get_current_tabpage(), "agent://project/activity/transcript")
        vim.api.nvim_win_set_buf(0, history:buf())
        history:set_win(0)

        history:add_user_message("first", 1786438920000)
        history:on_agent_start(1786438920001, "activity")
        history:on_text_delta("Planning")
        history:on_agent_start(1786438920002, "output", true)
        history:on_text_delta("First result")
        history:on_agent_end(nil, { force_completion = true })
        vim.wait(120)

        local activity = history._message_blocks[2]
        local first_output = history._message_blocks[3]
        local activity_row = history:_extmark_row(activity.anchor) + 1
        local first_output_row = history:_extmark_row(first_output.anchor) + 1
        assert.are.equal("activity", activity.section)
        assert.are.equal("output", first_output.section)
        assert.are.equal(activity_row, vim.fn.foldclosed(activity_row), "completed activity closes")
        assert.are.equal(-1, vim.fn.foldclosed(first_output_row), "completed output stays open")

        for turn = 2, 3 do
            history:add_user_message("question " .. turn, 1786438921000 + turn)
            history:on_agent_start(1786438922000 + turn, "output")
            history:on_text_delta("result " .. turn)
            history:on_agent_end(nil, { force_completion = true })
            vim.wait(80)
        end
        history:add_user_message("fourth", 1786438930000)
        vim.wait(100)

        local second_output_row = history:_extmark_row(history._message_blocks[5].anchor) + 1
        local third_output_row = history:_extmark_row(history._message_blocks[7].anchor) + 1
        assert.are.equal(first_output_row, vim.fn.foldclosed(first_output_row), "older output ages closed")
        assert.are.equal(-1, vim.fn.foldclosed(second_output_row), "second-latest output stays open")
        assert.are.equal(-1, vim.fn.foldclosed(third_output_row), "latest output stays open")

        vim.api.nvim_win_set_cursor(0, { first_output_row, 0 })
        vim.cmd("silent! normal! zo")
        history:add_user_message("fifth", 1786438931000)
        vim.wait(100)
        assert.are.equal(-1, vim.fn.foldclosed(first_output_row), "manual output reopen remains respected")

        vim.api.nvim_buf_delete(history:buf(), { force = true })
    end)

    it("opens over a scratch buffer whose wipe autocmd raises E367", function()
        local Attachments = require("pi.ui.chat.attachments")
        local Prompt = require("pi.ui.chat.prompt")
        local Layout = require("pi.ui.chat.layout")
        local attachments = Attachments.new()
        local history = History.new(vim.api.nvim_get_current_tabpage(), "agent://project/dashboard/transcript")
        local prompt = Prompt.new(vim.api.nvim_get_current_tabpage(), attachments)
        local layout = Layout.new("buffer", history, prompt, attachments)
        local dashboard = vim.api.nvim_create_buf(false, true)
        vim.bo[dashboard].bufhidden = "wipe"
        vim.api.nvim_set_current_buf(dashboard)
        local group = vim.api.nvim_create_augroup("PiDashboardCompatTest", { clear = true })
        vim.api.nvim_create_autocmd("BufWipeout", {
            group = group,
            buffer = dashboard,
            callback = function()
                vim.api.nvim_del_augroup_by_id(group)
                vim.api.nvim_del_augroup_by_id(group)
            end,
        })

        assert.is_true(layout:show())
        assert.are.equal(history:buf(), vim.api.nvim_win_get_buf(layout:history_win()))

        layout:hide()
        for _, buf in ipairs({ history:buf(), prompt:buf(), attachments:buf() }) do
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
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
        vim.wo.number = false
        vim.wo.relativenumber = true
        vim.cmd("setglobal number relativenumber")

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
        local prompt_win = layout:prompt_win()
        assert.is_not_nil(prompt_win)
        assert.are.equal(8, vim.api.nvim_win_get_height(prompt_win))
        prompt:resize()
        assert.are.equal(8, vim.api.nvim_win_get_height(prompt_win))
        assert.is_truthy(vim.wo[prompt_win].winbar:find("󰍩 PROMPT", 1, true))
        assert.is_truthy(vim.wo[prompt_win].winbar:find("idle", 1, true))
        assert.are.equal(0, prompt:statusline():virt_line_count())

        assert.are.equal("v:lua.require'pi.completion.omnifunc'.completefunc", vim.bo[prompt:buf()].omnifunc)
        assert.are.equal("v:lua.require'pi.completion.omnifunc'.completefunc", vim.bo[prompt:buf()].completefunc)
        local commands = require("pi.cache.commands")
        commands.set({ { name = "review", description = "Review changes", source = "extension" } })
        local omnifunc = require("pi.completion.omnifunc").completefunc
        vim.api.nvim_buf_set_lines(prompt:buf(), 0, -1, false, { "/rev" })
        vim.api.nvim_set_current_win(prompt_win)
        vim.api.nvim_win_set_cursor(prompt_win, { 1, 4 })
        assert.are.equal(0, omnifunc(1, ""))
        assert.are.equal("/review", omnifunc(0, "/rev")[1].word)
        commands.invalidate()

        prompt:statusline():update_state({
            model = { id = "test-model", contextWindow = 200000, reasoning = true },
            thinkingLevel = "high",
        })
        prompt:statusline():add_usage({ input = 1000, output = 100 })
        prompt:statusline():set_busy({ frame = "x", text = "Working", elapsed = "", thinking = false })
        local prompt_winbar = vim.wo[prompt_win].winbar
        assert.is_truthy(prompt_winbar:find("running", 1, true))
        assert.is_truthy(prompt_winbar:find("model: test-model", 1, true))
        assert.is_truthy(prompt_winbar:find("think: high", 1, true))
        assert.is_truthy(prompt_winbar:find("ctx:", 1, true))
        assert.are.equal(0, prompt:statusline():virt_line_count())

        layout:hide()
        assert.are.equal(original, vim.api.nvim_get_current_buf())
        assert.is_false(vim.wo.number)
        assert.is_true(vim.wo.relativenumber)

        vim.api.nvim_buf_delete(history:buf(), { force = true })
        vim.api.nvim_buf_delete(prompt:buf(), { force = true })
        vim.api.nvim_buf_delete(attachments:buf(), { force = true })
    end)
end)
