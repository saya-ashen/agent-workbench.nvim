-- Per-tab model pin: a tab's model choice must survive :PiNewSession and must
-- not be clobbered by model switches made in other sessions.
--
-- Core persists every set_model/cycle_model to global settings, and resolves
-- a fresh session's model from those settings — so without the pin, another
-- tab's model selection would leak into this tab's next conversation. The
-- plugin keeps a per-tab pin (captured from get_state, updated on manual
-- switches) and reapplies it after new_session. These specs drive the session
-- manager against a stubbed Rpc: no real pi process, canned responses.

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
    Sessions.stop()
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

    it("reapplies the pinned model after a new session", function()
        local session = Sessions.get_or_create()
        wait_or_fail(function()
            return session.pinned_model ~= nil
        end, "initial pin was not captured")

        Models.set(session, { provider = "kimi", id = "k2" })
        wait_or_fail(function()
            return session.pinned_model and session.pinned_model.id == "k2"
        end, "pin was not updated by manual set")

        local from = #sent
        Sessions.new_session()

        local reapply
        wait_or_fail(function()
            local _, new_idx = find_after(from, "new_session")
            reapply = select(1, find_after(new_idx, "set_model"))
            return reapply ~= nil
        end, "pinned model was not reapplied after new_session")
        assert.are.equal("kimi", reapply.provider)
        assert.are.equal("k2", reapply.modelId)
        -- The pin itself is unchanged.
        assert.are.same({ provider = "kimi", id = "k2" }, session.pinned_model)
    end)

    it("silently resyncs the pin to core's choice when reapply fails", function()
        local session = Sessions.get_or_create()
        wait_or_fail(function()
            return session.pinned_model ~= nil
        end, "initial pin was not captured")

        Models.set(session, { provider = "kimi", id = "k2" })
        wait_or_fail(function()
            return session.pinned_model and session.pinned_model.id == "k2"
        end, "pin was not updated by manual set")

        -- The pinned model becomes unusable; core falls back to its own choice.
        responders.set_model = function()
            return { type = "response", success = false, error = "Model not found: kimi/k2" }
        end
        responders.get_state = function()
            return {
                type = "response",
                success = true,
                data = { model = { provider = "core", id = "fallback" }, thinkingLevel = "off" },
            }
        end

        local notes_before = #notes
        Sessions.new_session()
        wait_or_fail(function()
            return session.pinned_model and session.pinned_model.id == "fallback"
        end, "pin was not resynced after failed reapply")
        assert.are.same({ provider = "core", id = "fallback" }, session.pinned_model)

        -- Silent fallback: no new user-facing notifications from the reapply.
        for i = notes_before + 1, #notes do
            assert.is_not.equal(vim.log.levels.ERROR, notes[i].level, "unexpected error notification: " .. notes[i].msg)
            assert.is_not.equal(
                vim.log.levels.WARN,
                notes[i].level,
                "unexpected warning notification: " .. notes[i].msg
            )
        end
    end)

    it("still starts a new session when no pin was ever captured", function()
        responders.get_state = nil -- never answered: pin stays nil
        local session = Sessions.get_or_create()
        assert.is_nil(session.pinned_model)

        responders.get_state = function()
            return {
                type = "response",
                success = true,
                data = { model = { provider = "core", id = "chosen" }, thinkingLevel = "off" },
            }
        end

        local from = #sent
        Sessions.new_session()
        wait_or_fail(function()
            return find_after(from, "new_session") ~= nil
        end, "new_session was not sent")

        -- No pin -> no set_model reapply; the pin is captured from core's choice.
        local _, new_idx = find_after(from, "new_session")
        assert.is_nil(select(1, find_after(new_idx, "set_model")))
        wait_or_fail(function()
            return session.pinned_model ~= nil
        end, "pin was not captured after new_session")
        assert.are.same({ provider = "core", id = "chosen" }, session.pinned_model)
    end)
end)
