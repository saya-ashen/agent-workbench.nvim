-- Model pin is session-owned. Creating another History buffer starts a separate
-- RPC session and does not mutate existing session's selected model.

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")
local Models = require("pi.models")

Config.setup({})

local real_rpc = { start = Rpc.start, stop = Rpc.stop, send = Rpc.send }

--- Commands sent through the stub, in order.
local sent = {}
--- type -> fun(cmd): pi.RpcEvent; nil responder = never answered.
local responders = {}
--- vim.notify spy records.
local notes = {}

local function install_stub()
    sent = {}
    responders = {}
    notes = {}

    Rpc.start = function(self)
        self._job_id = 999
        return true
    end
    Rpc.stop = function(self)
        self._job_id = nil
        self._pending = {}
    end
    Rpc.send = function(self, cmd, callback)
        if not self._job_id then
            return false
        end
        if not cmd.id then
            cmd.id = self._tab .. ":" .. self._req_id
            self._req_id = self._req_id + 1
        end
        sent[#sent + 1] = vim.deepcopy(cmd)
        local responder = responders[cmd.type]
        if callback and responder then
            local res = responder(cmd)
            vim.schedule(function()
                callback(res)
            end)
        end
        return true
    end

    vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level }
    end

    responders.get_commands = function()
        return { type = "response", success = true, data = { commands = {} } }
    end
    responders.get_state = function()
        return {
            type = "response",
            success = true,
            data = { model = { provider = "qwen", id = "qwen3-max" }, thinkingLevel = "off" },
        }
    end
    responders.abort = function()
        return { type = "response", success = true }
    end
    responders.new_session = function()
        return { type = "response", success = true, data = { cancelled = false } }
    end
    responders.set_model = function(cmd)
        return { type = "response", success = true, data = { provider = cmd.provider, id = cmd.modelId } }
    end
end

local function restore_stub()
    Sessions._reset()
    Rpc.start = real_rpc.start
    Rpc.stop = real_rpc.stop
    Rpc.send = real_rpc.send
end

--- Wait until fn() is truthy; fail the spec with `what` otherwise.
local function wait_or_fail(fn, what)
    assert(vim.wait(3000, fn, 10), what)
end

--- First command of `type` sent after index `from` (0 = from start).
local function find_after(from, type)
    for i = from + 1, #sent do
        if sent[i].type == type then
            return sent[i], i
        end
    end
    return nil, #sent
end

describe("session model pin", function()
    before_each(function()
        install_stub()
    end)

    after_each(function()
        restore_stub()
    end)

    it("captures the initial model pin from get_state on session creation", function()
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        wait_or_fail(function()
            return session.pinned_model ~= nil
        end, "initial pin was not captured")
        assert.are.same({ provider = "qwen", id = "qwen3-max" }, session.pinned_model)
    end)

    it("updates the pin when the user manually sets a model", function()
        local session = Sessions.get_or_create()
        wait_or_fail(function()
            return session.pinned_model ~= nil
        end, "initial pin was not captured")

        Models.set(session, { provider = "kimi", id = "k2" })
        wait_or_fail(function()
            return session.pinned_model and session.pinned_model.id == "k2"
        end, "pin was not updated by manual set")
        assert.are.same({ provider = "kimi", id = "k2" }, session.pinned_model)
    end)

    it("updates the pin when cycling through the backend", function()
        Config.options.models = nil
        responders.cycle_model = function()
            return {
                type = "response",
                success = true,
                data = { model = { provider = "deepseek", id = "ds-flash" }, thinkingLevel = "off" },
            }
        end

        local session = Sessions.get_or_create()
        wait_or_fail(function()
            return session.pinned_model ~= nil
        end, "initial pin was not captured")

        Models.cycle(session)
        wait_or_fail(function()
            return session.pinned_model and session.pinned_model.id == "ds-flash"
        end, "pin was not updated by cycle")
        assert.are.same({ provider = "deepseek", id = "ds-flash" }, session.pinned_model)
    end)

    it("creates a separate session without mutating existing model pin", function()
        local first = Sessions.get_or_create({ layout = "buffer" })
        wait_or_fail(function()
            return first.pinned_model ~= nil
        end, "initial pin was not captured")
        Models.set(first, { provider = "kimi", id = "k2" })
        wait_or_fail(function()
            return first.pinned_model and first.pinned_model.id == "k2"
        end, "pin was not updated by manual set")

        local from = #sent
        local second = Sessions.get_or_create({ new = true, layout = "buffer" })
        assert.is_not.equal(first, second)
        assert.is_true(first.rpc:is_running())
        assert.is_true(second.rpc:is_running())
        assert.are.same({ provider = "kimi", id = "k2" }, first.pinned_model)
        assert.is_nil(select(1, find_after(from, "new_session")))
        wait_or_fail(function()
            return second.pinned_model ~= nil
        end, "second session pin was not captured")
    end)
end)
