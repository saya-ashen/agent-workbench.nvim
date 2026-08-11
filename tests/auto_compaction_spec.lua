-- :PiToggleAutoCompaction — read the backend's current auto-compaction state
-- (get_state), send set_auto_compaction with the inverted value, and refresh
-- the statusline on success. Session-level state lives in the backend, so the
-- command carries no config; without an active session it is a silent no-op.
-- These specs drive the session manager against a stubbed Rpc: no real pi
-- process, canned responses.

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")
local Pi = require("pi")

Config.setup({})
Pi.setup({})

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
            data = { autoCompactionEnabled = false },
        }
    end
    responders.set_auto_compaction = function(cmd)
        return { type = "response", success = true, data = { enabled = cmd.enabled } }
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
---@return table? cmd
---@return integer idx
local function find_after(from, type)
    for i = from + 1, #sent do
        if sent[i].type == type then
            return sent[i], i
        end
    end
    return nil, #sent
end

describe("toggle auto compaction", function()
    before_each(function()
        install_stub()
    end)

    after_each(function()
        restore_stub()
    end)

    it("registers the :PiToggleAutoCompaction user command", function()
        local cmds = vim.api.nvim_get_commands({})
        assert.is_not_nil(cmds["PiToggleAutoCompaction"])
    end)

    it("is a silent no-op without an active session", function()
        Pi.toggle_auto_compaction()
        assert.are.equal(0, #sent)
        assert.are.equal(0, #notes)
    end)

    it("sends set_auto_compaction with the inverted state", function()
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        wait_or_fail(function()
            return #sent > 0
        end, "initial get_state was not sent")

        local from = #sent
        Pi.toggle_auto_compaction()
        assert.is_not_nil(select(1, find_after(from, "get_state")), "toggle did not read get_state")

        local set_cmd
        wait_or_fail(function()
            set_cmd = select(1, find_after(from, "set_auto_compaction"))
            return set_cmd ~= nil
        end, "set_auto_compaction was not sent")
        assert.are.equal(true, set_cmd.enabled) -- responder reports disabled
    end)

    it("disables auto compaction when it is currently on", function()
        responders.get_state = function()
            return {
                type = "response",
                success = true,
                data = { autoCompactionEnabled = true },
            }
        end
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        wait_or_fail(function()
            return #sent > 0
        end, "initial get_state was not sent")

        local from = #sent
        Pi.toggle_auto_compaction()
        local set_cmd
        wait_or_fail(function()
            set_cmd = select(1, find_after(from, "set_auto_compaction"))
            return set_cmd ~= nil
        end, "set_auto_compaction was not sent")
        assert.are.equal(false, set_cmd.enabled)
    end)

    it("refreshes the statusline state after a successful toggle", function()
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        wait_or_fail(function()
            return #sent > 0
        end, "initial get_state was not sent")

        local from = #sent
        Pi.toggle_auto_compaction()
        local set_idx
        wait_or_fail(function()
            local _, idx = find_after(from, "set_auto_compaction")
            set_idx = idx
            return set_idx ~= nil
        end, "set_auto_compaction was not sent")

        -- Success callback triggers refresh_state -> another get_state.
        local refresh
        wait_or_fail(function()
            refresh = select(1, find_after(set_idx, "get_state"))
            return refresh ~= nil
        end, "statusline refresh get_state was not sent")
        assert.are.equal("get_state", refresh.type)
    end)

    it("surfaces a failed toggle and does not refresh", function()
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        wait_or_fail(function()
            return #sent > 0
        end, "initial get_state was not sent")

        responders.set_auto_compaction = function()
            return { type = "response", success = false, error = "compaction locked" }
        end

        local from = #sent
        Pi.toggle_auto_compaction()
        local set_idx
        wait_or_fail(function()
            local _, idx = find_after(from, "set_auto_compaction")
            set_idx = idx
            return set_idx ~= nil
        end, "set_auto_compaction was not sent")

        wait_or_fail(function()
            return #notes > 0
        end, "no error notification for the failed toggle")
        assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
        assert.is_not_nil(notes[#notes].msg:find("Toggle auto compaction failed", 1, true))
        -- No refresh get_state after the failed set.
        assert.is_nil(select(1, find_after(set_idx, "get_state")))
    end)
end)
