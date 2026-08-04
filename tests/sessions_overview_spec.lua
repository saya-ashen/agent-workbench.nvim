-- Unit tests for pi.ui.sessions (:PiSessions overview): status derivation,
-- line formatting/highlight chunks, row building, and the shared-buffer
-- open/render/toggle lifecycle. Window opening is exercised headlessly.

local Ft = require("pi.filetypes")
local SessionList = require("pi.ui.sessions")

--- Build a fake pi.Session with just enough surface for the list.
---@param opts? { running?: boolean, streaming?: boolean, compacting?: boolean, verb?: string, tab?: integer }
local function fake_session(opts)
    opts = opts or {}
    return {
        tab = opts.tab or 1000,
        rpc = {
            is_running = function()
                return opts.running ~= false
            end,
        },
        chat = {
            is_streaming = function()
                return opts.streaming == true
            end,
            is_compacting = function()
                return opts.compacting == true
            end,
            active_verb = function()
                return opts.verb
            end,
        },
    }
end

describe("sessions overview", function()
    before_each(function()
        SessionList._reset()
    end)

    after_each(function()
        -- Close any list window we opened, then drop module state.
        pcall(SessionList.close)
        SessionList._reset()
    end)

    describe("status_of", function()
        it("is exited when the process is not running", function()
            assert.are.equal("exited", SessionList.status_of(fake_session({ running = false })))
        end)

        it("is compacting while compaction runs, even if streaming", function()
            assert.are.equal("compacting", SessionList.status_of(fake_session({ streaming = true, compacting = true })))
        end)

        it("is busy while streaming", function()
            assert.are.equal("busy", SessionList.status_of(fake_session({ streaming = true })))
        end)

        it("is idle otherwise", function()
            assert.are.equal("idle", SessionList.status_of(fake_session()))
        end)
    end)

    describe("dot_hl", function()
        it("blinks between the busy color and dim", function()
            local row = { status = "busy", attention = 0 }
            assert.are.equal("PiBusy", SessionList.dot_hl(row, 0))
            assert.are.equal("PiSessionsListDotDim", SessionList.dot_hl(row, 1))
        end)

        it("blinks at half speed while compacting", function()
            local row = { status = "compacting", attention = 0 }
            assert.are.equal("PiSessionsListCompacting", SessionList.dot_hl(row, 0))
            assert.are.equal("PiSessionsListCompacting", SessionList.dot_hl(row, 1))
            assert.are.equal("PiSessionsListDotDim", SessionList.dot_hl(row, 2))
        end)

        it("is steady for idle and exited; attention wins over busy", function()
            assert.are.equal("PiSessionsListIdle", SessionList.dot_hl({ status = "idle", attention = 0 }, 1))
            assert.are.equal("PiSessionsListExited", SessionList.dot_hl({ status = "exited", attention = 0 }, 0))
            assert.are.equal("PiStatusLineAttention", SessionList.dot_hl({ status = "busy", attention = 2 }, 1))
        end)
    end)

    describe("format_line", function()
        it("puts the dot at the left edge and the name right after it", function()
            local row = { tab = 1, status = "idle", attention = 0, name = "fix login" }
            local line, chunks = SessionList.format_line(row, 0)
            assert.are.equal(" ● fix login", line)
            assert.are.equal(2, #chunks)
            assert.are.equal(1, chunks[1][1]) -- one-cell left margin before the dot
            assert.are.equal("●", line:sub(chunks[1][1] + 1, chunks[1][2]))
            assert.are.equal(1 + #"●" + 1, chunks[2][1])
            assert.are.equal("Normal", chunks[2][3])
        end)

        it("renders a pending placeholder when the name is unknown", function()
            local _, chunks = SessionList.format_line({ tab = 1, status = "idle", attention = 0, name = nil }, 0)
            assert.are.equal("PiSessionsListPending", chunks[2][3])
        end)

        it("colors the dot by status and tick", function()
            local _, chunks = SessionList.format_line({ tab = 1, status = "busy", attention = 0, name = "x" }, 0)
            assert.are.equal("PiBusy", chunks[1][3])
            local _, chunks1 = SessionList.format_line({ tab = 1, status = "busy", attention = 0, name = "x" }, 1)
            assert.are.equal("PiSessionsListDotDim", chunks1[1][3])
        end)

        it("produces byte ranges valid for extmarks", function()
            local row = { tab = 12, status = "busy", attention = 1, name = "námé" }
            local line, chunks = SessionList.format_line(row, 0)

            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
            local ns = vim.api.nvim_create_namespace("pi-sessions-test")
            for _, chunk in ipairs(chunks) do
                -- Throws on an out-of-range byte index, so this validates ranges.
                vim.api.nvim_buf_set_extmark(buf, ns, 0, chunk[1], { end_col = chunk[2], hl_group = chunk[3] })
            end
            local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
            assert.are.equal(#chunks, #marks)
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end)
    end)

    describe("build_rows", function()
        it("maps sessions to rows with status, attention, and name", function()
            local a = fake_session({ tab = 10, streaming = true, verb = "Cooking" })
            local b = fake_session({ tab = 11 })
            local rows = SessionList.build_rows({ a, b }, function(tab)
                return tab == 11 and 3 or 0
            end, function(session)
                return session.tab == 10 and "alpha" or nil
            end)

            assert.are.equal(2, #rows)
            assert.are.equal("busy", rows[1].status)
            assert.are.equal("alpha", rows[1].name)
            assert.are.equal(0, rows[1].attention)
            assert.are.equal("idle", rows[2].status)
            assert.are.equal(3, rows[2].attention)
            assert.is_nil(rows[2].name)
        end)
    end)

    describe("open / render / toggle", function()
        it("opens a window on the shared list buffer with a placeholder", function()
            SessionList.open()
            assert.are.equal(Ft.sessions, vim.bo.filetype)
            assert.is_false(vim.bo.modifiable)
            local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            assert.same({ "  (no active sessions)" }, lines)
        end)

        it("toggle closes and reopens the list", function()
            SessionList.open()
            local bufnr = vim.api.nvim_get_current_buf()
            SessionList.toggle() -- close
            assert.is_not.equal(bufnr, vim.api.nvim_get_current_buf())
            SessionList.toggle() -- reopen
            assert.are.equal(bufnr, vim.api.nvim_get_current_buf())
        end)

        it("opening twice focuses the existing window, not a duplicate", function()
            SessionList.open()
            local win = vim.api.nvim_get_current_win()
            SessionList.open()
            assert.are.equal(win, vim.api.nvim_get_current_win())
        end)

        it("float layout opens a floating window", function()
            local Config = require("pi.config")
            local saved = Config.options.layout.default
            Config.options.layout.default = "float"
            SessionList.open()
            local cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
            assert.are.equal("editor", cfg.relative)
            Config.options.layout.default = saved
        end)
    end)
end)
