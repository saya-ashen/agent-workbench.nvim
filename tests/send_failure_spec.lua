local Chat = require("pi.ui.chat")

local function cleanup(chat)
    chat:destroy()
    for _, buf in ipairs({ chat:history_buf(), chat:prompt_buf(), chat:attachments_buf() }) do
        if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
end

describe("chat send failure", function()
    it("treats legacy nil send results as accepted", function()
        local chat = Chat.new(2, "side", {
            send = function() end,
        })
        chat._prompt:set_text("legacy transport")

        chat:_send_message(nil)

        assert.are.equal("", chat._prompt:text())
        assert.is_true(vim.wait(100, function()
            local history = table.concat(vim.api.nvim_buf_get_lines(chat:history_buf(), 0, -1, false), "\n")
            return history:find("legacy transport", 1, true) ~= nil
        end))
        cleanup(chat)
    end)

    it("keeps draft and attachments without rendering user history", function()
        local chat = Chat.new(1, "side", {
            send = function()
                return false
            end,
        })
        chat._prompt:set_text("keep this draft")
        chat._attachments._items = {
            { name = "image.png", data = "abc", mime = "image/png", size = 3 },
        }
        chat._attachments:_rerender()
        local before = vim.api.nvim_buf_get_lines(chat:history_buf(), 0, -1, false)

        chat:_send_message(nil)

        assert.are.equal("keep this draft", chat._prompt:text())
        assert.are.equal(1, chat._attachments:count())
        assert.are.same(before, vim.api.nvim_buf_get_lines(chat:history_buf(), 0, -1, false))
        cleanup(chat)
    end)
end)
