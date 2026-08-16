local Config = require("agent-workbench.config")
local Chat = require("agent-workbench.ui.chat")

Config.setup({})

local function setup_chat(id)
    local chat = Chat.new(vim.api.nvim_get_current_tabpage(), "buffer", {
        send = function()
            return true
        end,
    }, "agent://activity-output/" .. id, id)
    local history = chat:history()
    vim.api.nvim_win_set_buf(0, history:buf())
    history:set_win(0)
    return chat, history
end

local function fold_row(history, block)
    return history:_extmark_row(block.anchor) + 1
end

describe("agent activity and output folds", function()
    local original_notify

    before_each(function()
        Config.options.render.engine = "builtin"
        original_notify = vim.notify
    end)

    after_each(function()
        vim.notify = original_notify
    end)

    it("classifies tool prose as Activity and final prose as Output", function()
        local chat, history = setup_chat(981)
        chat:on_agent_start(1)
        chat:on_message_start({ message = { role = "assistant", timestamp = 2 } })
        chat:on_text_delta("Inspecting")
        chat:on_tool_start("read", "t1", { path = "README.md" })
        vim.wait(80)
        chat:on_tool_end("read", "t1", { content = { { type = "text", text = "done" } } }, false)
        chat:on_message_end({ message = { role = "assistant", stopReason = "toolUse" } })
        chat:on_message_start({ message = { role = "assistant", timestamp = 3 } })
        chat:on_text_delta("Final result")
        chat:on_message_end({ message = { role = "assistant", stopReason = "stop" } })
        chat:on_agent_end()
        vim.wait(200)

        assert.are.equal(2, #history._message_blocks)
        assert.are.equal("activity", history._message_blocks[1].section)
        assert.are.equal("output", history._message_blocks[2].section)
        assert.are.equal(
            fold_row(history, history._message_blocks[1]),
            vim.fn.foldclosed(fold_row(history, history._message_blocks[1]))
        )
        assert.are.equal(-1, vim.fn.foldclosed(fold_row(history, history._message_blocks[2])))
        vim.api.nvim_buf_delete(history:buf(), { force = true })
    end)

    it("auto-dismisses the completion notification", function()
        local notification
        vim.notify = function(message, level, opts)
            notification = { message = message, level = level, opts = opts }
        end

        local chat, history = setup_chat(983)
        chat:on_agent_end()

        assert.are.equal("π │ Agent finished - waiting for your input", notification.message)
        assert.are.equal(vim.log.levels.INFO, notification.level)
        assert.are.equal(3000, notification.opts.timeout)
        assert.is_nil(notification.opts.id)
        vim.api.nvim_buf_delete(history:buf(), { force = true })
    end)

    it("closes tool-only and thinking-only Activity", function()
        for index, kind in ipairs({ "tool", "thinking" }) do
            local chat, history = setup_chat(981 + index)
            chat:on_agent_start(1)
            if kind == "tool" then
                chat:on_tool_start("read", "t" .. index, { path = "README.md" })
                chat:on_tool_end("read", "t" .. index, { content = { { type = "text", text = "done" } } }, false)
            else
                chat:on_thinking_start()
                chat:on_thinking_delta("Considering")
                chat:on_thinking_end()
            end
            chat:on_agent_end()
            vim.wait(160)

            local block = history._message_blocks[1]
            assert.are.equal("activity", block.section)
            assert.are.equal(fold_row(history, block), vim.fn.foldclosed(fold_row(history, block)))
            vim.api.nvim_buf_delete(history:buf(), { force = true })
        end
    end)
end)
