local Chat = require("agent-workbench.ui.chat.init")
local Config = require("agent-workbench.config")

local draft_enabled

local function new_chat()
    Config.options.prompt.draft.enabled = false
    local sent = {}
    local chat = Chat.new(vim.api.nvim_get_current_tabpage(), "buffer", {
        send = function(command)
            sent[#sent + 1] = command
            return true
        end,
    }, nil, 991)
    chat:show()
    vim.wait(30)
    return chat, sent
end

local function delete_chat(chat)
    chat:hide()
    for _, buf in ipairs({ chat:history_buf(), chat:prompt_buf(), chat:attachments_buf() }) do
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end
end

describe("prompt request mode", function()
    before_each(function()
        draft_enabled = Config.options.prompt.draft.enabled
    end)

    after_each(function()
        Config.options.prompt.draft.enabled = draft_enabled
    end)

    it("renders session-local select, preserves draft, and confirms selection", function()
        local chat, sent = new_chat()
        local prompt = chat._prompt
        vim.api.nvim_buf_set_lines(prompt:buf(), 0, -1, false, { "unfinished draft" })
        vim.api.nvim_win_set_cursor(prompt:win(), { 1, 8 })
        local resolved

        assert.is_true(chat:present_prompt_request({
            id = "choice-1",
            kind = "select",
            title = "Choose approach",
            options = { "Minimal fix", "Full refactor" },
            selected = 1,
            callback = function(value)
                resolved = value
            end,
        }))

        assert.are.equal("request", prompt:mode())
        assert.are.equal("unfinished draft", prompt:text())
        assert.is_false(vim.bo[prompt:buf()].modifiable)
        local lines = vim.api.nvim_buf_get_lines(prompt:buf(), 0, -1, false)
        assert.are.equal("Choose approach", lines[1])
        assert.are.equal("  › Minimal fix", lines[3])
        assert.is_truthy(vim.wo[prompt:win()].winbar:find("CHOOSE", 1, true))

        prompt:move_request_selection(1)
        chat:submit()

        assert.are.equal("Full refactor", resolved)
        assert.are.equal("compose", prompt:mode())
        assert.are.equal("unfinished draft", prompt:text())
        assert.is_true(vim.bo[prompt:buf()].modifiable)
        assert.are.equal(0, #sent, "request response must not become a prompt")
        delete_chat(chat)
    end)

    it("drains queued requests for one session in FIFO order", function()
        local chat, sent = new_chat()
        local session = {
            tab = vim.api.nvim_get_current_tabpage(),
            chat = chat,
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(_, command)
                    sent[#sent + 1] = command
                end,
            },
            attention = { pending = {} },
        }
        local original_manager = package.loaded["agent-workbench.sessions.manager"]
        package.loaded["agent-workbench.sessions.manager"] = {
            list = function()
                return { session }
            end,
            get = function()
                return session
            end,
            get_for_tab = function()
                return session
            end,
            is_current = function()
                return true
            end,
        }
        package.loaded["agent-workbench.attention"] = nil
        local Attention = require("agent-workbench.attention")

        assert.is_true(Attention.present(session, {
            method = "select",
            id = "first",
            title = "First",
            options = { "A", "B" },
        }))
        assert.is_true(Attention.present(session, {
            method = "confirm",
            id = "second",
            title = "Second",
        }))
        assert.are.equal(1, #session.attention.pending)

        chat._prompt:confirm_request()
        vim.wait(50)
        assert.are.equal("second", chat._prompt._request.id)
        chat._prompt:cancel_request()
        vim.wait(20)

        assert.are.equal("A", sent[1].value)
        assert.are.equal(true, sent[2].cancelled)
        package.loaded["agent-workbench.sessions.manager"] = original_manager
        package.loaded["agent-workbench.attention"] = nil
        delete_chat(chat)
    end)

    it("keeps Esc non-destructive and uses explicit cancellation", function()
        local chat = new_chat()
        local prompt = chat._prompt
        local resolved = "unset"
        chat:present_prompt_request({
            id = "confirm-1",
            kind = "confirm",
            title = "Proceed?",
            message = "Apply changes",
            options = { "Yes", "No" },
            selected = 1,
            callback = function(value)
                resolved = value
            end,
        })

        vim.api.nvim_set_current_win(prompt:win())
        vim.api.nvim_input(vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
        vim.wait(30)
        assert.are.equal("request", prompt:mode())
        assert.are.equal("unset", resolved)

        prompt:cancel_request()
        assert.is_nil(resolved)
        assert.are.equal("compose", prompt:mode())
        delete_chat(chat)
    end)
end)
