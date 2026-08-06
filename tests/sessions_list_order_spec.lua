-- :PiSessions list order must follow the tabline, not tabpage handles (issue #63).
--
-- Tabpage handles reflect creation order: `:tabnew` from tab 1 inserts the new
-- tab between tabs 1 and 2, and :tabmove reorders tabs without touching
-- handles. Sessions.list() used to sort by handle, so the sessions list could
-- disagree with the tabline (e.g. tabs 2 and 3 swapped). These specs pin the
-- visual-order invariant. They drive the session manager against a stubbed
-- Rpc: no real pi process, canned responses (see session_model_pin_spec.lua).

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")

Config.setup({})

local real_rpc = { start = Rpc.start, stop = Rpc.stop, send = Rpc.send }

local function install_stub()
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
        if callback then
            vim.schedule(function()
                callback({ type = "response", success = true, data = {} })
            end)
        end
        return true
    end
end

local function restore_stub()
    Rpc.start = real_rpc.start
    Rpc.stop = real_rpc.stop
    Rpc.send = real_rpc.send
end

--- Tabpage handles in current visual order.
local function visual_tabs()
    return vim.api.nvim_list_tabpages()
end

--- Tab handles of Sessions.list(), in listing order.
local function listed_tabs()
    local tabs = {}
    for _, session in ipairs(Sessions.list()) do
        tabs[#tabs + 1] = session.tab
    end
    return tabs
end

describe("sessions list order (issue #63)", function()
    local start_tab

    before_each(function()
        install_stub()
        start_tab = vim.api.nvim_get_current_tabpage()
    end)

    after_each(function()
        -- Stop every session first, then close the tabs we created; closing
        -- tabs with live sessions would trigger TabClosed cleanup too, so
        -- doing sessions first keeps teardown deterministic.
        for _, tab in ipairs(visual_tabs()) do
            vim.api.nvim_set_current_tabpage(tab)
            Sessions.stop()
        end
        for _, tab in ipairs(visual_tabs()) do
            if tab ~= start_tab and vim.api.nvim_tabpage_is_valid(tab) then
                vim.api.nvim_set_current_tabpage(tab)
                vim.cmd("tabclose!")
            end
        end
        vim.api.nvim_set_current_tabpage(start_tab)
        restore_stub()
    end)

    it("lists sessions in tabline order", function()
        Sessions.get_or_create()
        vim.cmd("tabnew")
        Sessions.get_or_create()
        vim.cmd("tabnew")
        Sessions.get_or_create()

        assert.are.same(visual_tabs(), listed_tabs())
    end)

    it("follows the tabline when a new tab is inserted mid-list", function()
        Sessions.get_or_create()
        vim.cmd("tabnew")
        Sessions.get_or_create()

        -- A tab created from tab 1 lands between tabs 1 and 2: its handle is
        -- the largest one, but visually it comes second. Handle-order listing
        -- would swap it with the last tab.
        vim.cmd("tabfirst")
        vim.cmd("tabnew")
        Sessions.get_or_create()

        local visual = visual_tabs()
        assert.is_true(#visual == 3, "expected three tabs")
        -- Precondition: visual order differs from handle order, so this
        -- scenario actually exercises the bug.
        local by_handle = { unpack(visual) }
        table.sort(by_handle)
        assert.are_not.same(by_handle, visual)
        assert.are.same(visual, listed_tabs())
    end)

    it("follows the tabline after :tabmove", function()
        Sessions.get_or_create()
        vim.cmd("tabnew")
        Sessions.get_or_create()
        vim.cmd("tabnew")
        Sessions.get_or_create()

        vim.cmd("tabfirst")
        vim.cmd("tabnext 3")
        vim.cmd("tabmove 0") -- move the last tab to the front

        assert.are.same(visual_tabs(), listed_tabs())
    end)
end)
