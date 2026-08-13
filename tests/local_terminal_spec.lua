local Chat = require("pi.ui.chat.init")
local Config = require("pi.config")

local draft_enabled

local function new_chat()
    Config.options.prompt.draft.enabled = false
    local sent = {}
    local callbacks = {}
    local chat = Chat.new(vim.api.nvim_get_current_tabpage(), "buffer", {
        send = function(command, callback)
            sent[#sent + 1] = command
            callbacks[#callbacks + 1] = callback
            return true
        end,
    }, nil, 997, vim.uv.cwd())
    chat:show()
    vim.wait(30)
    return chat, sent, callbacks
end

local function delete_chat(chat)
    chat:destroy()
    if #vim.api.nvim_list_wins() == 1 then
        vim.cmd("new")
    end
    chat:hide()
    for _, buf in ipairs({ chat:history_buf(), chat:prompt_buf(), chat:attachments_buf() }) do
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end
end

local function buffer_contains(buf, text)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find(text, 1, true) ~= nil
end

describe("persistent prompt command modes", function()
    before_each(function()
        draft_enabled = Config.options.prompt.draft.enabled
    end)

    after_each(function()
        Config.options.prompt.draft.enabled = draft_enabled
    end)

    it("keeps backend bash mode after submit and ignores a bare prefix", function()
        local chat, sent = new_chat()
        local prompt = chat._prompt

        prompt:set_text("!")
        chat:submit()
        assert.are.equal(0, #sent)
        assert.are.equal("bash", prompt:command_mode())

        prompt:set_text("!printf backend")
        chat:submit()
        assert.are.equal(1, #sent)
        assert.are.equal("bash", sent[1].type)
        assert.are.equal("printf backend", sent[1].command)
        assert.is_nil(sent[1].excludeFromContext)
        assert.are.equal("!", prompt:text())
        assert.are.equal(chat:history_buf(), vim.api.nvim_win_get_buf(chat._layout:history_win()))
        delete_chat(chat)
    end)

    it("runs !! commands in one persistent local terminal outside agent RPC", function()
        local chat, sent = new_chat()
        local prompt = chat._prompt

        prompt:set_text("!!")
        chat:submit()
        local terminal_buf = chat._terminal_buf
        local terminal_job = chat._terminal_job
        assert.are.equal(0, #sent)
        assert.are.equal("terminal", prompt:command_mode())
        assert.are.equal(terminal_buf, vim.api.nvim_win_get_buf(chat._layout:history_win()))

        prompt:set_text("!!export PI_NVIM_TERM_TEST=kept")
        chat:submit()
        prompt:set_text("!!printf '__PI_LOCAL_TERM__%s\\n' \"$PI_NVIM_TERM_TEST\"")
        chat:submit()

        assert.are.equal(0, #sent)
        assert.are.equal("!!", prompt:text())
        assert.are.equal(terminal_buf, chat._terminal_buf)
        assert.are.equal(terminal_job, chat._terminal_job)
        assert.is_true(vim.wait(2000, function()
            return buffer_contains(terminal_buf, "__PI_LOCAL_TERM__kept")
        end, 20))

        prompt:set_text("!")
        assert.are.equal("bash", prompt:command_mode())
        assert.are.equal(chat:history_buf(), vim.api.nvim_win_get_buf(chat._layout:history_win()))
        prompt:set_text("")
        assert.are.equal("compose", prompt:command_mode())
        delete_chat(chat)
    end)

    it("keeps terminal view across layout and visibility changes", function()
        local chat = new_chat()
        chat._prompt:set_text("!!")
        local terminal_buf = chat._terminal_buf
        local terminal_job = chat._terminal_job

        chat:set_layout("float")
        assert.are.equal(terminal_buf, vim.api.nvim_win_get_buf(chat._layout:history_win()))
        chat:set_layout("side")
        assert.are.equal(terminal_buf, vim.api.nvim_win_get_buf(chat._layout:history_win()))
        chat:hide()
        assert.is_true(chat:_terminal_alive())
        chat:focus_terminal()
        assert.is_true(chat:is_visible())
        assert.are.equal(terminal_buf, vim.api.nvim_get_current_buf())
        assert.are.equal(terminal_job, chat._terminal_job)
        delete_chat(chat)
    end)

    it("stops and deletes local terminal on destroy", function()
        local chat = new_chat()
        chat._prompt:set_text("!!")
        local terminal_buf = chat._terminal_buf
        local terminal_job = chat._terminal_job

        chat:destroy()
        assert.is_false(vim.api.nvim_buf_is_valid(terminal_buf))
        assert.are_not.equal(-1, vim.fn.jobwait({ terminal_job }, 1000)[1])
        if #vim.api.nvim_list_wins() == 1 then
            vim.cmd("new")
        end
        chat:hide()
        for _, buf in ipairs({ chat:history_buf(), chat:prompt_buf(), chat:attachments_buf() }) do
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
    end)

    it("temporarily restores chat History for prompt requests", function()
        local chat = new_chat()
        local prompt = chat._prompt
        prompt:set_text("!!")
        local terminal_buf = chat._terminal_buf

        chat:present_prompt_request({
            id = "local-terminal-request",
            kind = "confirm",
            title = "Proceed?",
            options = { "Yes", "No" },
            selected = 1,
            callback = function() end,
        })
        assert.are.equal(chat:history_buf(), vim.api.nvim_win_get_buf(chat._layout:history_win()))

        prompt:confirm_request()
        assert.are.equal("!!", prompt:text())
        assert.are.equal(terminal_buf, vim.api.nvim_win_get_buf(chat._layout:history_win()))
        delete_chat(chat)
    end)
end)
