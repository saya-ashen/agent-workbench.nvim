-- Thinking level selection against the backend's available levels (issue #81).
--
-- The picker used to hardcode the six-level list. RPC now exposes
-- `get_available_thinking_levels`; the picker lists only what the current
-- model supports, falls back to the built-in list when the fetch fails, and
-- warns without opening a picker when the model supports no thinking levels.

local Thinking = require("agent-workbench.thinking")

---@type string[]
local sent = {}
---@type table<string, fun(cmd: table): table>
local responders = {}
---@type { msg: string, level: integer }[]
local notes = {}

local fake_rpc = {
    send = function(_, cmd, callback)
        sent[#sent + 1] = vim.deepcopy(cmd)
        local responder = responders[cmd.type]
        if callback and responder then
            local res = responder(cmd)
            vim.schedule(function()
                callback(res)
            end)
        end
        return true
    end,
}

---@return table a minimal session whose rpc answers from `responders`
local function fake_session()
    return { rpc = fake_rpc }
end

local function reset()
    sent = {}
    responders = {}
    notes = {}
    vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level }
    end
end

--- Wait until fn() is truthy; fail the spec with `what` otherwise.
local function wait_or_fail(fn, what)
    assert(vim.wait(3000, fn, 10), what)
end

--- Install a vim.ui.select stub that records calls and resolves via fn.
---@return { calls: table[], answer: fun(choice: string?) }
local function stub_select()
    local calls = {}
    local pending = nil ---@type fun(choice: string?)?
    local original = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
        calls[#calls + 1] = { items = items, opts = opts, on_choice = on_choice }
        pending = on_choice
    end
    return {
        calls = calls,
        answer = function(choice)
            local cb = pending
            pending = nil
            if cb then
                cb(choice)
            end
        end,
        restore = function()
            vim.ui.select = original
        end,
    }
end

describe("thinking levels", function()
    before_each(reset)

    describe("with_available", function()
        it("calls fn with the backend's levels on success", function()
            responders.get_available_thinking_levels = function()
                return { type = "response", success = true, data = { levels = { "off", "medium", "high" } } }
            end
            local got
            Thinking.with_available(fake_session(), function(levels)
                got = levels
            end)
            wait_or_fail(function()
                return got ~= nil
            end, "with_available callback did not run")
            assert.are.same({ "off", "medium", "high" }, got)
        end)

        it("falls back to the built-in list when the fetch fails", function()
            responders.get_available_thinking_levels = function()
                return { type = "response", success = false, error = "boom" }
            end
            local got
            Thinking.with_available(fake_session(), function(levels)
                got = levels
            end)
            wait_or_fail(function()
                return got ~= nil
            end, "with_available callback did not run")
            assert.are.same({ "off", "minimal", "low", "medium", "high", "xhigh" }, got)
            assert.equal(1, #notes)
            assert.matches("boom", notes[1].msg)
            assert.matches("using defaults", notes[1].msg)
        end)

        it("warns and skips fn when the model supports no thinking levels", function()
            responders.get_available_thinking_levels = function()
                return { type = "response", success = true, data = { levels = {} } }
            end
            local called = false
            Thinking.with_available(fake_session(), function()
                called = true
            end)
            wait_or_fail(function()
                return #notes > 0
            end, "no warning was emitted")
            assert.is_false(called)
            assert.matches("does not support thinking", notes[1].msg)
        end)
    end)

    describe("select", function()
        it("opens the picker with the backend's levels and sends set_thinking_level", function()
            responders.get_available_thinking_levels = function()
                return { type = "response", success = true, data = { levels = { "off", "medium", "high" } } }
            end
            responders.set_thinking_level = function()
                return { type = "response", success = true }
            end
            local stub = stub_select()
            Thinking.select(fake_session())

            wait_or_fail(function()
                return #stub.calls > 0
            end, "picker did not open")
            assert.are.same({ "off", "medium", "high" }, stub.calls[1].items)
            assert.equal("Thinking level", stub.calls[1].opts.prompt)
            assert.equal("pi-thinking-level", stub.calls[1].opts.kind)

            stub.answer("high")
            assert.equal("set_thinking_level", sent[#sent].type)
            assert.equal("high", sent[#sent].level)
            stub.restore()
        end)

        it("falls back to the built-in list when the fetch fails", function()
            responders.get_available_thinking_levels = function()
                return { type = "response", success = false, error = "boom" }
            end
            local stub = stub_select()
            Thinking.select(fake_session())

            wait_or_fail(function()
                return #stub.calls > 0
            end, "picker did not open")
            assert.are.same({ "off", "minimal", "low", "medium", "high", "xhigh" }, stub.calls[1].items)
            stub.restore()
        end)

        it("does not open a picker when the model supports no thinking levels", function()
            responders.get_available_thinking_levels = function()
                return { type = "response", success = true, data = { levels = {} } }
            end
            local stub = stub_select()
            Thinking.select(fake_session())
            wait_or_fail(function()
                return #notes > 0
            end, "no warning was emitted")
            assert.equal(0, #stub.calls)
            assert.matches("does not support thinking", notes[1].msg)
            stub.restore()
        end)
    end)
end)
