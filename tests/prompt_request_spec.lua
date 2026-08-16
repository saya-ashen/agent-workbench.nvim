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

local function request_virtual_text(buf)
    local namespace = vim.api.nvim_get_namespaces()["pi-prompt-request"]
    local texts = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
        local details = mark[4]
        if details.virt_text then
            local chunks = {}
            for _, chunk in ipairs(details.virt_text) do
                chunks[#chunks + 1] = chunk[1]
            end
            texts[#texts + 1] = { text = table.concat(chunks), col = details.virt_text_win_col }
        end
        for _, virtual_line in ipairs(details.virt_lines or {}) do
            local chunks = {}
            for _, chunk in ipairs(virtual_line) do
                chunks[#chunks + 1] = chunk[1]
            end
            texts[#texts + 1] = { text = table.concat(chunks) }
        end
    end
    return texts
end

---@param entries table[]
---@return string
local function joined_virtual_text(entries)
    local texts = {}
    for _, entry in ipairs(entries) do
        texts[#texts + 1] = vim.trim(entry.text)
    end
    return table.concat(texts, "\n")
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
        vim.api.nvim_set_current_win(chat._layout:history_win())
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
        assert.are.equal(prompt:win(), vim.api.nvim_get_current_win())
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

    it("moves embedded title previews onto selected option rows", function()
        local chat = new_chat()
        local prompt = chat._prompt

        assert.is_true(chat:present_prompt_request({
            id = "embedded-1",
            kind = "select",
            title = "Choose\n\n--- 1. A preview ---\n```text\nPreview A\n```\n\n--- 2. B preview ---\nPreview B",
            options = { "A", "B" },
            callback = function() end,
        }))

        local lines = vim.api.nvim_buf_get_lines(prompt:buf(), 0, -1, false)
        assert.are.equal("Choose", lines[1])
        assert.are.equal("  › A", lines[3])
        assert.are_not.equal("--- 1. A preview ---", lines[3])

        prompt:move_request_selection(1)
        lines = vim.api.nvim_buf_get_lines(prompt:buf(), 0, -1, false)
        assert.are.equal("  › B", lines[4])
        assert.are_not.equal("--- 2. B preview ---", lines[4])
        delete_chat(chat)
    end)

    it("renders structured option descriptions and multiline previews", function()
        local chat = new_chat()
        local prompt = chat._prompt
        local resolved
        local ramen_preview =
            "╭────────────╮\n│ 豚骨拉面   │\n│ 叉烧 · 鸡蛋 │\n│ 热气腾腾   │\n╰────────────╯"
        local pizza_preview =
            "╭────────────╮\n│ 玛格丽特   │\n│ 番茄 · 芝士 │\n╰────────────╯"

        assert.is_true(chat:present_prompt_request({
            id = "structured-1",
            kind = "select",
            title = "[晚餐选择] 今晚想吃什么？",
            options = {
                {
                    label = "1. 拉面",
                    description = "热汤面，适合想吃得暖和时。",
                    preview = ramen_preview,
                },
                {
                    label = "2. 披萨",
                    description = "多人分享，口味选择多。",
                    preview = pizza_preview,
                    value = "pizza",
                },
                { label = "3. 寿司", description = "清爽少油，适合轻食。" },
                { label = "4. Type something." },
            },
            callback = function(value)
                resolved = value
            end,
        }))

        local lines = vim.api.nvim_buf_get_lines(prompt:buf(), 0, -1, false)
        assert.are.equal("[晚餐选择] 今晚想吃什么？", lines[1])
        assert.are.equal("  › 1. 拉面 — 热汤面，适合想吃得暖和时。", lines[3])
        assert.are.equal("    2. 披萨 — 多人分享，口味选择多。", lines[4])
        assert.is_nil(table.concat(lines, "\n"):find("豚骨拉面", 1, true))

        local preview_marks = request_virtual_text(prompt:buf())
        local preview_text = joined_virtual_text(preview_marks)
        assert.is_true(preview_text:find("╭────────────╮", 1, true) ~= nil)
        assert.is_true(preview_text:find("│ 豚骨拉面   │", 1, true) ~= nil)
        assert.is_true(preview_text:find("│ 叉烧 · 鸡蛋 │", 1, true) ~= nil)
        assert.is_true(preview_text:find("╰────────────╯", 1, true) ~= nil)
        assert.is_nil(preview_text:find("玛格丽特", 1, true))
        assert.is_true(preview_marks[1].col ~= nil)

        prompt:move_request_selection(1)
        lines = vim.api.nvim_buf_get_lines(prompt:buf(), 0, -1, false)
        assert.are.equal("  › 2. 披萨 — 多人分享，口味选择多。", lines[4])
        preview_text = joined_virtual_text(request_virtual_text(prompt:buf()))
        assert.is_true(preview_text:find("玛格丽特", 1, true) ~= nil)
        assert.is_nil(preview_text:find("豚骨拉面", 1, true))

        local columns = vim.o.columns
        vim.o.columns = 50
        prompt:move_request_selection(0)
        preview_marks = request_virtual_text(prompt:buf())
        assert.are.equal(4, #preview_marks)
        for _, mark in ipairs(preview_marks) do
            assert.is_nil(mark.col)
        end
        assert.is_true(joined_virtual_text(preview_marks):find("│ 番茄 · 芝士 │", 1, true) ~= nil)
        vim.o.columns = columns

        prompt:confirm_request()
        assert.are.equal("pizza", resolved)
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
