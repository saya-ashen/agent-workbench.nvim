-- Double-<Esc> abort gesture during auto-retry (issue #87): while the core is
-- in the "Retrying…" backoff window (between agent_end and the retry's
-- agent_start) `_streaming` is false, so the gesture must be kept live by a
-- separate `_retrying` flag, and the second <Esc> must send abort_retry (it
-- only cancels the backoff) instead of abort.

local Chat = require("agent-workbench.ui.chat")
local Manager = require("agent-workbench.sessions.manager")

local TAB = 873

--- Build a real Chat headlessly and stub require("agent-workbench") so the abort target is
--- observable: the gesture's scheduled callback calls pi.abort() /
--- pi.abort_retry(), which normally no-op without a session.
local function setup_chat()
    local chat = Chat.new(TAB, "side", {
        send = function()
            return true
        end,
    })
    local sent = {}
    local original_pi = package.loaded["agent-workbench"]
    package.loaded["agent-workbench"] = {
        abort = function()
            sent[#sent + 1] = "abort"
        end,
        abort_retry = function()
            sent[#sent + 1] = "abort_retry"
        end,
    }
    return chat,
        sent,
        function()
            package.loaded["agent-workbench"] = original_pi
            chat:set_retrying(false)
            chat:_disarm_abort_esc()
            pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
            pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
        end
end

--- Wait for the scheduled abort callback to run.
local function pump(sent)
    vim.wait(500, function()
        return #sent > 0
    end)
end

describe("abort gesture during auto-retry", function()
    it("idle: <Esc> does not arm the gesture", function()
        local chat, sent, cleanup = setup_chat()
        cleanup()
        assert.is_false(chat._streaming)
        assert.is_false(chat._retrying)
        chat:_handle_abort_esc()
        assert.is_nil(chat._abort_esc_at)
        assert.are.same({}, sent)
    end)

    it("retrying: first <Esc> arms, second sends abort_retry", function()
        local chat, sent, cleanup = setup_chat()
        chat:set_retrying(true)
        chat:_handle_abort_esc()
        assert.is_not_nil(chat._abort_esc_at, "first <Esc> should arm during retry")
        assert.is_true(chat._retrying)
        chat:_handle_abort_esc()
        pump(sent)
        assert.are.same({ "abort_retry" }, sent, "second <Esc> during retry must send abort_retry")
        cleanup()
    end)

    it("streaming: second <Esc> still sends abort", function()
        local chat, sent, cleanup = setup_chat()
        chat._streaming = true
        chat:_handle_abort_esc()
        chat:_handle_abort_esc()
        pump(sent)
        assert.are.same({ "abort" }, sent, "streaming abort must stay on abort")
        cleanup()
    end)

    it("retrying while streaming (defensive): sends abort, not abort_retry", function()
        local chat, sent, cleanup = setup_chat()
        chat._streaming = true
        chat:set_retrying(true)
        chat:_handle_abort_esc()
        chat:_handle_abort_esc()
        pump(sent)
        assert.are.same({ "abort" }, sent)
        cleanup()
    end)

    it("set_retrying(false) disarms a gesture armed during retry", function()
        local chat, _, cleanup = setup_chat()
        chat:set_retrying(true)
        chat:_handle_abort_esc()
        assert.is_not_nil(chat._abort_esc_at)
        chat:set_retrying(false)
        assert.is_nil(chat._abort_esc_at, "leaving retry must disarm the gesture")
        cleanup()
    end)

    it("on_agent_start clears the retrying flag", function()
        local chat, _, cleanup = setup_chat()
        chat:set_retrying(true)
        chat:on_agent_start()
        assert.is_false(chat._retrying)
        assert.is_true(chat._streaming)
        cleanup()
    end)
end)

describe("manager auto_retry event wiring", function()
    --- Fake session whose chat records set_retrying/set_status/on_error calls.
    local function setup_recorder()
        local calls = {}
        local chat = {
            set_retrying = function(_, v)
                calls[#calls + 1] = { "set_retrying", v }
            end,
            set_status = function(_, s)
                calls[#calls + 1] = { "set_status", s }
            end,
            active_verb = function()
                return nil
            end,
            on_error = function(_, text)
                calls[#calls + 1] = { "on_error", text }
            end,
        }
        local session = {
            tab = 999,
            chat = chat,
            attention = { pending = {} },
        }
        return session, calls
    end

    it("auto_retry_start marks retrying and shows the status", function()
        local session, calls = setup_recorder()
        Manager.handle_event(session, { type = "auto_retry_start", attempt = 1, maxAttempts = 3, delayMs = 10 })
        assert.are.same({
            { "set_retrying", true },
            { "set_status", { type = "agent", text = "Retrying…" } },
        }, calls)
    end)

    it("auto_retry_end success clears retrying and restores the agent status", function()
        local session, calls = setup_recorder()
        Manager.handle_event(session, { type = "auto_retry_end", success = true, attempt = 1 })
        assert.are.same({
            { "set_retrying", false },
            { "set_status", nil },
        }, calls)
    end)

    it("auto_retry_end failure clears retrying and surfaces the error", function()
        local session, calls = setup_recorder()
        Manager.handle_event(session, {
            type = "auto_retry_end",
            success = false,
            attempt = 3,
            finalError = "429 rate limited",
        })
        assert.are.same({
            { "set_retrying", false },
            { "set_status", nil },
            { "on_error", "Retry failed after 3 attempts: 429 rate limited" },
        }, calls)
    end)
end)
