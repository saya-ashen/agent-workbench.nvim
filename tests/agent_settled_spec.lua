-- Issue #84: agent_settled 事件：精确化「空闲」判定。
--
-- pi emits `agent_settled` after the full session-level run settles — no
-- retry, compaction retry, or queued continuation remains — but the plugin
-- used to drop it (Rpc.log_unhandled) and relied on piecemeal restores in
-- the compaction/retry branches. These specs drive the REAL session manager
-- (stubbed Rpc methods only, no pi process — same pattern as
-- session_model_pin_spec) and assert the status converges on the settle
-- event, that summarization retry events route without UNHANDLED noise, and
-- that the branchSummary busy state renders and settles.

local Config = require("agent-workbench.config")
local Rpc = require("agent-workbench.rpc")
local Sessions = require("agent-workbench.sessions.manager")
local SessionsList = require("agent-workbench.ui.sessions")

Config.setup({})

local real_start = Rpc.start
local real_stop = Rpc.stop
local real_send = Rpc.send
local real_log_unhandled = Rpc.log_unhandled
local real_request_refresh = SessionsList.request_refresh

--- Commands the stub answered with a canned response (get_messages → empty).
local function install_stubs()
    Rpc.start = function(self)
        self._job_id = 999
        return true
    end
    Rpc.stop = function(self)
        self._job_id = nil
        self._pending = {}
    end
    Rpc.send = function(self, cmd, callback)
        if cmd.type == "get_messages" then
            vim.schedule(function()
                callback({ success = true, data = { messages = {} } })
            end)
        end
        return true
    end
    Rpc.log_unhandled = function() end
    SessionsList.request_refresh = function() end
end

local function restore_stubs()
    Rpc.start = real_start
    Rpc.stop = real_stop
    Rpc.send = real_send
    Rpc.log_unhandled = real_log_unhandled
    SessionsList.request_refresh = real_request_refresh
end

--- Feed events through the manager's installed RPC handler.
---@param session agent_workbench.Session
local function feed(session, ...)
    local handler = session.rpc._handler
    assert.truthy(handler, "handler not installed")
    for _, msg in ipairs({ ... }) do
        handler(msg)
    end
end

--- Wait until the history status text settles on `expected` (nil = idle).
--- set_status renders through vim.schedule, so assertions must pump.
---@param chat agent_workbench.ChatAgent
---@param expected string?
local function await_status(chat, expected)
    return vim.wait(1000, function()
        return chat._history._status_text == expected
    end)
end

describe("agent_settled routing", function()
    local tab = nil ---@type integer?
    local session ---@type agent_workbench.Session?
    local chat ---@type agent_workbench.ChatAgent?
    local unhandled = {} ---@type string[]
    local rr_before = 0

    before_each(function()
        unhandled = {}
        Rpc.log_unhandled = function(event_type)
            unhandled[#unhandled + 1] = event_type
        end
        SessionsList.request_refresh = function()
            rr_before = rr_before + 1
        end
        Rpc.start = function(self)
            self._job_id = 999
            return true
        end
        Rpc.send = function(self, cmd, callback)
            if cmd.type == "get_messages" then
                vim.schedule(function()
                    callback({ success = true, data = { messages = {} } })
                end)
            end
            return true
        end
        local tabs = vim.api.nvim_list_tabpages()
        vim.cmd("tabnew")
        tab = vim.api.nvim_get_current_tabpage()
        assert.is_true(#vim.api.nvim_list_tabpages() > #tabs, "tab must be created")
        session = Sessions.get_or_create({ layout = "split" })
        assert.truthy(session, "session creation failed")
        chat = session.chat
    end)

    after_each(function()
        if tab then
            local tabs = vim.api.nvim_list_tabpages()
            if #tabs > 1 then
                vim.api.nvim_set_current_tabpage(tabs[1])
            end
            pcall(vim.api.nvim_tabpage_close, tab)
        end
        Rpc.start = real_start
        Rpc.stop = real_stop
        Rpc.send = real_send
        Rpc.log_unhandled = real_log_unhandled
        SessionsList.request_refresh = real_request_refresh
    end)

    it("settles leftover spinner state on agent_settled (final fallback)", function()
        feed(session, { type = "agent_start" }, { type = "agent_end", messages = {} })
        assert.is_true(await_status(chat, nil))
        -- Simulate a restore gap the settle event must converge: a stale
        -- status that no later agent_end/compaction_end would clear.
        chat:set_status({ type = "agent", text = "Stale…" })
        local rr_after = rr_before
        feed(session, { type = "agent_settled" })
        assert.is_true(await_status(chat, nil), "agent_settled must clear stale status")
        assert.are.same({}, unhandled, "agent_settled must be handled, not dropped")
        assert.is_true(rr_before > rr_after, "agent_settled must refresh the sessions list")
    end)

    it("handles agent_settled arriving during the compaction rebuild gate", function()
        feed(session, { type = "agent_start" }, { type = "agent_end", messages = {} })
        feed(session, { type = "compaction_start" })
        feed(session, { type = "compaction_end", result = {} }) -- async get_messages rebuild
        -- settle lands while _compaction_rebuilding is true → buffered
        feed(session, { type = "agent_settled" })
        assert.is_true(session._compaction_rebuilding == true, "rebuild must be in flight")
        assert.is_true(await_status(chat, nil), "status must settle after rebuild replay")
        assert.are.same({}, unhandled, "settle must be handled after the gate replay")
    end)

    it("routes summarization retry events during compaction without disturbing the status", function()
        feed(session, { type = "agent_start" }, { type = "agent_end", messages = {} })
        feed(session, { type = "compaction_start" })
        assert.is_true(await_status(chat, "Compacting…"))
        feed(session, {
            type = "summarization_retry_scheduled",
            attempt = 1,
            maxAttempts = 3,
            delayMs = 2000,
            errorMessage = "terminated",
        })
        feed(session, { type = "summarization_retry_attempt_start", source = "compaction", reason = "threshold" })
        feed(session, { type = "summarization_retry_finished" })
        assert.is_true(await_status(chat, "Compacting…"), "compaction status must stay put")
        feed(session, { type = "compaction_end" })
        assert.is_true(await_status(chat, nil), "compaction_end restores idle")
        assert.are.same({}, unhandled)
    end)

    it("shows and settles a busy state for branchSummary summarization retries", function()
        feed(session, { type = "summarization_retry_attempt_start", source = "branchSummary" })
        assert.is_true(await_status(chat, "Summarizing branch…"), "branch summary busy state must render")
        feed(session, { type = "summarization_retry_finished" })
        assert.is_true(await_status(chat, nil), "finished must restore idle")
        assert.are.same({}, unhandled)
    end)

    it("still settles after an auto-retry chain (regression)", function()
        feed(session, { type = "agent_start" }, { type = "agent_end", messages = {} })
        feed(session, { type = "auto_retry_start", attempt = 1, maxAttempts = 3 })
        feed(session, { type = "agent_start" }) -- retry turn
        feed(session, { type = "auto_retry_end", success = true, attempt = 1 })
        feed(session, { type = "agent_end", messages = {} })
        feed(session, { type = "agent_settled" })
        assert.is_true(await_status(chat, nil))
        assert.are.same({}, unhandled)
    end)
end)
