local Chat = require("agent-workbench.ui.chat")

local function unsupported_agent()
    return {
        capabilities = {
            attachments = false,
            direct_bash = false,
            follow_up = false,
            tree = false,
        },
        prompt = function()
            return true
        end,
        steer = function()
            return true
        end,
    }
end

describe("backend capability gates", function()
    it("keeps unsupported Pi features unavailable without raw sends", function()
        local chat = Chat.new(21, "buffer", unsupported_agent())
        chat:on_agent_start()

        chat._prompt:set_text("queued")
        chat:submit_follow_up()
        assert.are.equal("queued", chat._prompt:text())

        chat._prompt:set_text("!pwd")
        chat:submit()
        assert.are.equal("!pwd", chat._prompt:text())

        chat._prompt:set_text("/tree")
        chat:submit()
        assert.are.equal("/tree", chat._prompt:text())

        assert.is_false(chat:attach_image("/tmp/missing.png"))
        assert.is_false(chat:attach_from_clipboard())
        chat:destroy()
    end)
end)
