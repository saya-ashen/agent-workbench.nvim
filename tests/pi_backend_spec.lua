local Registry = require("agent-workbench.backends")
local PiBackend = require("agent-workbench.backends.pi")
local Rpc = require("agent-workbench.rpc")
local Chat = require("agent-workbench.ui.chat")

local real_new = Rpc.new

describe("pi backend session", function()
    local sent
    local started
    local closed
    local handler
    local rpc

    before_each(function()
        Registry._reset()
        sent = {}
        started = false
        closed = false
        handler = nil
        rpc = {
            set_handler = function(_, value)
                handler = value
            end,
            start = function()
                started = true
                return true
            end,
            stop = function()
                closed = true
            end,
            is_running = function()
                return started and not closed
            end,
            send = function(_, command)
                sent[#sent + 1] = vim.deepcopy(command)
                return true
            end,
        }
        Rpc.new = function(id, cwd)
            assert.are.equal(17, id)
            assert.are.equal("/tmp/workbench", cwd)
            return rpc
        end
    end)

    after_each(function()
        Rpc.new = real_new
    end)

    it("keeps Chat prompt, steering, and follow-up on semantic methods", function()
        local calls = {}
        local function record(command_type)
            return function(text, opts)
                calls[#calls + 1] = { type = command_type, text = text, images = opts.images }
                return true
            end
        end
        local chat = Chat.new(18, "buffer", {
            prompt = record("prompt"),
            steer = record("steer"),
            follow_up = record("follow_up"),
            send = function()
                error("ordinary messages must not use raw send")
            end,
        })

        chat._prompt:set_text("initial")
        chat:submit()
        chat:on_agent_start()
        chat._prompt:set_text("interrupt")
        chat:submit()
        chat._prompt:set_text("later")
        chat:submit_follow_up()

        assert.are.same({
            { type = "prompt", text = "initial" },
            { type = "steer", text = "interrupt" },
            { type = "follow_up", text = "later" },
        }, calls)
        chat:destroy()
    end)

    it("preserves pi command payloads and normalized core events", function()
        local backend = PiBackend.new({ id = 17, cwd = "/tmp/workbench" })
        local events = {}
        assert.is_true(backend:start(function(event)
            events[#events + 1] = event
        end))

        local image = { type = "image", data = "AA==", mimeType = "image/png" }
        assert.is_true(backend:prompt("first", { images = { image } }))
        assert.is_true(backend:steer("second"))
        assert.is_true(backend:follow_up("third"))
        assert.is_true(backend:stop())

        assert.are.same({
            { type = "prompt", message = "first", images = { image } },
            { type = "steer", message = "second" },
            { type = "follow_up", message = "third" },
            { type = "abort" },
        }, sent)
        assert.is_true(backend:is_running())
        assert.are.equal(rpc, backend.rpc)
        assert.is_true(backend:capabilities().raw_rpc)
        assert.is_true(backend:capabilities().follow_up)

        handler({ type = "agent_start" })
        handler({ type = "message_update", assistantMessageEvent = { type = "thinking_delta", delta = "why" } })
        handler({ type = "message_update", assistantMessageEvent = { type = "text_delta", delta = "answer" } })
        handler({ type = "tool_execution_start", toolName = "read", toolCallId = "tool-1", args = { path = "x" } })
        handler({ type = "tool_execution_update", toolName = "read", toolCallId = "tool-1", partial = "x" })
        handler({
            type = "tool_execution_end",
            toolName = "read",
            toolCallId = "tool-1",
            result = { content = {} },
            isError = false,
        })
        handler({ type = "agent_end" })
        handler({ type = "agent_settled" })
        handler({ type = "queue_update", steering = {}, followUp = {} })

        local types = {}
        for _, event in ipairs(events) do
            types[#types + 1] = event.type
        end
        assert.are.same({
            "run_started",
            "thinking_delta",
            "text_delta",
            "tool_started",
            "tool_updated",
            "tool_finished",
            "run_turn_finished",
            "run_settled",
            "backend_event",
        }, types)
        assert.are.equal("queue_update", events[#events].raw.type)

        backend:close()
        assert.is_true(closed)
        assert.is_false(backend:is_running())
    end)
end)
