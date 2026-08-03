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

    describe("status_text", function()
        it("shows the active verb when busy", function()
            local text = SessionList.status_text({ status = "busy", verb = "Cooking" })
            assert.are.equal("● Cooking…", text)
        end)

        it("falls back to Working when busy has no verb", function()
            local text = SessionList.status_text({ status = "busy", verb = nil })
            assert.are.equal("● Working…", text)
        end)

        it("shows icon-only markers for compacting, idle and exited", function()
            assert.are.equal("○", SessionList.status_text({ status = "idle" }))
            assert.are.equal("✕", SessionList.status_text({ status = "exited" }))
            assert.are.equal(
                vim.trim(require("pi.config").options.labels.compaction),
                SessionList.status_text({ status = "compacting" })
            )
        end)
    end)

    describe("format_line", function()
        it("lays out tab number, status, name, and attention", function()
            local row = { tab = 1, number = 1, status = "busy", verb = "Working", attention = 2, name = "fix login" }
            local line, chunks = SessionList.format_line(row)

            assert.is_truthy(line:find("fix login", 1, true))
            assert.is_truthy(line:find("󰵚 2", 1, true))
            assert.are.equal(4, #chunks)
            -- tab, status, name, attention groups
            assert.are.equal("PiSessionsListTab", chunks[1][3])
            assert.are.equal("PiBusy", chunks[2][3])
            assert.are.equal("Normal", chunks[3][3])
            assert.are.equal("PiStatusLineAttention", chunks[4][3])
        end)

        it("omits the attention chunk when the count is zero", function()
            local row = { tab = 1, number = 1, status = "idle", attention = 0, name = "x" }
            local line, chunks = SessionList.format_line(row)
            assert.is_nil(line:find("󰵚", 1, true))
            assert.are.equal(3, #chunks)
        end)

        it("renders a pending placeholder when the name is unknown", function()
            local row = { tab = 1, number = 1, status = "idle", attention = 0, name = nil }
            local _, chunks = SessionList.format_line(row)
            assert.are.equal("PiSessionsListPending", chunks[3][3])
        end)

        it("produces byte ranges valid for extmarks", function()
            local row =
                { tab = 12, number = 12, status = "busy", verb = "Shaving yaks", attention = 1, name = "námé" }
            local line, chunks = SessionList.format_line(row)

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

        it("pads the status column to a fixed display width", function()
            -- The name column must start at the same display column whether the
            -- status text is short or over-long (byte offsets differ: status
            -- icons are multibyte).
            local line_short, c_short =
                SessionList.format_line({ tab = 1, number = 1, status = "idle", attention = 0, name = "a" })
            local line_long, c_long = SessionList.format_line({
                tab = 1,
                number = 1,
                status = "busy",
                verb = string.rep("x", 40),
                attention = 0,
                name = "a",
            })
            local prefix_w_short = vim.fn.strdisplaywidth(line_short:sub(1, c_short[3][1]))
            local prefix_w_long = vim.fn.strdisplaywidth(line_long:sub(1, c_long[3][1]))
            assert.are.equal(prefix_w_short, prefix_w_long)
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
            assert.are.equal("Cooking", rows[1].verb)
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
