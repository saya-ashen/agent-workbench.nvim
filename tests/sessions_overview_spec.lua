-- Unit tests for pi.ui.sessions (:PiSessions overview): status derivation,
-- line formatting/highlight chunks, row building, and the shared-buffer
-- open/render/toggle lifecycle. Window opening is exercised headlessly.

local Ft = require("agent-workbench.filetypes")
local SessionList = require("agent-workbench.ui.sessions")

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

--- Fake session whose rpc:send captures the get_state callback instead of
--- sending, so tests control when the response arrives. `send_count` tracks
--- fetches; `respond(data)` delivers a response to the oldest in-flight one.
---@param opts? table see fake_session
local function fetchable_session(opts)
    local s = fake_session(opts)
    ---@type fun[]
    local in_flight = {}
    s.send_count = 0
    s.rpc.send = function(_, req, cb)
        assert.are.equal("get_state", req.type)
        s.send_count = s.send_count + 1
        table.insert(in_flight, cb)
        return true
    end
    s.respond = function(data)
        local cb = table.remove(in_flight, 1)
        assert.is_not.is_nil(cb, "no name fetch in flight")
        cb({ success = true, data = data or {} })
        -- The handler schedules the cache write; pump the event loop.
        vim.wait(100, function()
            return false
        end)
    end
    return s
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
            assert.are.equal("PiSessionsListBusy", SessionList.dot_hl(row, 0))
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

        it("blinks green for an unseen finished turn, red for an unseen error", function()
            local done = { status = "idle", attention = 0, done = true, error = false }
            assert.are.equal("PiSessionsListDone", SessionList.dot_hl(done, 0))
            assert.are.equal("PiSessionsListDotDim", SessionList.dot_hl(done, 1))
            local err = { status = "idle", attention = 0, done = false, error = true }
            assert.are.equal("PiSessionsListError", SessionList.dot_hl(err, 0))
            assert.are.equal("PiSessionsListDotDim", SessionList.dot_hl(err, 1))
            -- error outranks done and attention; exited outranks everything
            assert.are.equal(
                "PiSessionsListError",
                SessionList.dot_hl({ status = "idle", attention = 1, done = true, error = true }, 0)
            )
            assert.are.equal(
                "PiSessionsListExited",
                SessionList.dot_hl({ status = "exited", attention = 1, done = true, error = true }, 0)
            )
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
            assert.are.equal("PiSessionsListBusy", chunks[1][3])
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
            end, function(session)
                return session.tab == 11 and { done = true, error = false } or { done = false, error = false }
            end)

            assert.are.equal(2, #rows)
            assert.are.equal("busy", rows[1].status)
            assert.are.equal("alpha", rows[1].name)
            assert.are.equal(0, rows[1].attention)
            assert.are.equal("idle", rows[2].status)
            assert.are.equal(3, rows[2].attention)
            assert.is_true(rows[2].done)
            assert.is_false(rows[2].error)
            assert.is_false(rows[1].done)
            assert.is_nil(rows[2].name)
        end)
    end)

    describe("name resolution", function()
        it("shows the pending placeholder only until the first answer", function()
            local s = fetchable_session()
            assert.is_nil(SessionList._name_of(s))
            SessionList._fetch_name(s)
            assert.are.equal(1, s.send_count)
            assert.is_nil(SessionList._name_of(s)) -- "…" placeholder while in flight
            s.respond({}) -- no sessionName, no sessionFile
            assert.are.equal("(unnamed)", SessionList._name_of(s))
        end)

        it("keeps (unnamed) on screen while an unresolved name is retried", function()
            local s = fetchable_session()
            SessionList._fetch_name(s)
            s.respond({})
            assert.are.equal("(unnamed)", SessionList._name_of(s))

            -- Regression: a retry must not fall back to the pending
            -- placeholder — that alternation was the visible flicker.
            SessionList.on_agent_end(s)
            assert.are.equal(2, s.send_count)
            assert.are.equal("(unnamed)", SessionList._name_of(s))
            s.respond({})
            assert.are.equal("(unnamed)", SessionList._name_of(s))

            -- A name arriving on a later retry replaces (unnamed).
            SessionList.on_agent_end(s)
            s.respond({ sessionName = "my task" })
            assert.are.equal("my task", SessionList._name_of(s))

            -- Resolved non-empty entries are not retried.
            SessionList._fetch_name(s)
            assert.are.equal(3, s.send_count)
        end)

        it("retries unresolved names on message_end and stops once resolved", function()
            local s = fetchable_session()
            SessionList._fetch_name(s)
            s.respond({})
            assert.are.equal("(unnamed)", SessionList._name_of(s))

            -- The backend flushes the session file when the first assistant
            -- message completes; message_end is when the fallback becomes
            -- readable, well before agent_end on long turns.
            SessionList.on_message_end(s)
            assert.are.equal(2, s.send_count)
            s.respond({ sessionName = "named mid-turn" })
            assert.are.equal("named mid-turn", SessionList._name_of(s))

            -- Resolved entries make message_end a no-op.
            SessionList.on_message_end(s)
            assert.are.equal(2, s.send_count)
        end)

        it("keeps at most one retry of an unresolved name in flight", function()
            local s = fetchable_session()
            SessionList._fetch_name(s)
            s.respond({})

            SessionList.on_message_end(s) -- retry goes out
            SessionList.on_message_end(s) -- skipped while the retry is in flight
            SessionList.on_agent_end(s) -- same: one in flight at a time
            assert.are.equal(2, s.send_count)

            s.respond({})
            SessionList.on_message_end(s) -- next event may retry again
            assert.are.equal(3, s.send_count)
        end)

        it("does not clobber a name set by session_info_changed mid-fetch", function()
            -- First fetch in flight when a rename arrives.
            local s = fetchable_session()
            SessionList._fetch_name(s)
            SessionList.on_session_info_changed(s, "renamed")
            s.respond({}) -- stale empty answer must not win
            assert.are.equal("renamed", SessionList._name_of(s))

            -- Same for an in-flight retry of an empty entry.
            local s2 = fetchable_session()
            SessionList._fetch_name(s2)
            s2.respond({})
            SessionList.on_message_end(s2) -- retry in flight
            SessionList.on_session_info_changed(s2, "renamed too")
            s2.respond({}) -- stale empty answer must not win
            assert.are.equal("renamed too", SessionList._name_of(s2))
        end)

        it("does not re-fetch resolved names on redraws", function()
            local s = fetchable_session()
            local real_manager = package.loaded["agent-workbench.sessions.manager"]
            package.loaded["agent-workbench.sessions.manager"] = {
                list = function()
                    return { s }
                end,
                get = function()
                    return nil
                end,
            }
            local ok, err = pcall(function()
                SessionList.open() -- initial render kicks off the first fetch
                assert.are.equal(1, s.send_count)
                s.respond({}) -- also pumps the refresh the response schedules
                assert.are.equal("(unnamed)", SessionList._name_of(s))
                assert.are.equal(1, s.send_count)

                SessionList.request_refresh()
                vim.wait(100, function()
                    return false
                end)
                assert.are.equal(1, s.send_count) -- redraw is not a retry trigger

                local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
                assert.are.equal(" ● (unnamed)", lines[1])
            end)
            package.loaded["agent-workbench.sessions.manager"] = real_manager
            if not ok then
                error(err)
            end
        end)
    end)

    describe("rename", function()
        --- Fake session capturing every outgoing RPC request; the
        --- set_session_name response callback is held in `rename_cb`.
        local function renamable_session(opts)
            local s = fake_session(opts)
            s.sent = {}
            s.rpc.send = function(_, req, cb)
                table.insert(s.sent, req)
                if req.type == "set_session_name" then
                    s.rename_cb = cb
                end
                return true
            end
            return s
        end

        local function last_request(s, type_)
            for i = #s.sent, 1, -1 do
                if s.sent[i].type == type_ then
                    return s.sent[i]
                end
            end
            return nil
        end

        local function press_key(key)
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
        end

        --- Run fn with the session manager, Dialog.input, and Notify stubbed.
        --- The dialog answers `answer` immediately; fn receives the captured
        --- dialog option tables and notification list.
        local function with_stubs(sessions, answer, fn)
            local real_manager = package.loaded["agent-workbench.sessions.manager"]
            local real_dialog = package.loaded["agent-workbench.ui.dialog"]
            local real_notify = package.loaded["agent-workbench.notify"]
            local dialog_calls = {}
            local notifications = {}
            package.loaded["agent-workbench.sessions.manager"] = {
                list = function()
                    return sessions
                end,
                get = function()
                    return nil
                end,
            }
            package.loaded["agent-workbench.ui.dialog"] = {
                input = function(opts, cb)
                    table.insert(dialog_calls, opts)
                    cb(answer)
                end,
            }
            package.loaded["agent-workbench.notify"] = {
                warn = function(msg)
                    table.insert(notifications, { "warn", msg })
                end,
                error = function(msg)
                    table.insert(notifications, { "error", msg })
                end,
                info = function(msg)
                    table.insert(notifications, { "info", msg })
                end,
            }
            local ok, err = pcall(fn, dialog_calls, notifications)
            package.loaded["agent-workbench.sessions.manager"] = real_manager
            package.loaded["agent-workbench.ui.dialog"] = real_dialog
            package.loaded["agent-workbench.notify"] = real_notify
            if not ok then
                error(err)
            end
        end

        it("sends set_session_name for the session under the cursor", function()
            local s = renamable_session({ tab = vim.api.nvim_get_current_tabpage() })
            with_stubs({ s }, "new name", function(dialog_calls)
                SessionList.open()
                press_key("r")
                assert.are.equal(1, #dialog_calls)
                assert.are.equal("", dialog_calls[1].default) -- unnamed: nothing to prefill
                local req = last_request(s, "set_session_name")
                assert.is_not_nil(req)
                assert.are.equal("new name", req.name)
            end)
        end)

        it("prefills the input with the current backend name", function()
            local s = renamable_session({ tab = vim.api.nvim_get_current_tabpage() })
            SessionList.on_session_info_changed(s, "old name")
            with_stubs({ s }, "new name", function(dialog_calls)
                SessionList.open()
                press_key("r")
                assert.are.equal("old name", dialog_calls[1].default)
            end)
        end)

        it("does nothing when the input is cancelled or emptied", function()
            local s = renamable_session({ tab = vim.api.nvim_get_current_tabpage() })
            with_stubs({ s }, nil, function()
                SessionList.open()
                press_key("r")
                assert.is_nil(last_request(s, "set_session_name"))
            end)
            local s2 = renamable_session({ tab = vim.api.nvim_get_current_tabpage() })
            with_stubs({ s2 }, "", function()
                press_key("r")
                assert.is_nil(last_request(s2, "set_session_name"))
            end)
        end)

        it("refuses to rename a session whose process exited", function()
            local s = renamable_session({ running = false, tab = vim.api.nvim_get_current_tabpage() })
            with_stubs({ s }, "new name", function(dialog_calls, notifications)
                SessionList.open()
                press_key("r")
                assert.are.equal(0, #dialog_calls)
                assert.is_nil(last_request(s, "set_session_name"))
                assert.are.equal("warn", notifications[1][1])
            end)
        end)

        it("reports an RPC failure via Notify.error", function()
            local s = renamable_session({ tab = vim.api.nvim_get_current_tabpage() })
            with_stubs({ s }, "new name", function(_, notifications)
                SessionList.open()
                press_key("r")
                assert.is_not_nil(last_request(s, "set_session_name"))
                s.rename_cb({ success = false, error = "Session name cannot be empty" })
                vim.wait(100, function()
                    return false
                end)
                assert.are.equal("error", notifications[1][1])
                assert.is_truthy(notifications[1][2]:find("Session name cannot be empty", 1, true))
            end)
        end)

        it("stays silent on success; the row updates via session_info_changed", function()
            local s = renamable_session({ tab = vim.api.nvim_get_current_tabpage() })
            with_stubs({ s }, "new name", function(_, notifications)
                SessionList.open()
                press_key("r")
                s.rename_cb({ success = true })
                -- The backend emits session_info_changed, which updates the row.
                SessionList.on_session_info_changed(s, "new name")
                vim.wait(100, function()
                    return false
                end)
                assert.are.equal(0, #notifications)
                assert.are.equal("new name", SessionList._name_of(s))
            end)
        end)

        it("R drops cached names and re-fetches", function()
            local s = fetchable_session({ tab = vim.api.nvim_get_current_tabpage() })
            with_stubs({ s }, nil, function()
                SessionList.open()
                assert.are.equal(1, s.send_count)
                s.respond({})
                assert.are.equal("(unnamed)", SessionList._name_of(s))
                press_key("R")
                assert.are.equal(2, s.send_count)
            end)
        end)
    end)

    describe("current-tab marker", function()
        --- Run fn with the manager stubbed to a single session and the list
        --- open in the current tab.
        local function with_list_session(session, fn)
            local real_manager = package.loaded["agent-workbench.sessions.manager"]
            package.loaded["agent-workbench.sessions.manager"] = {
                list = function()
                    return { session }
                end,
                get = function()
                    return nil
                end,
            }
            local ok, err = pcall(function()
                SessionList.open()
                fn()
            end)
            package.loaded["agent-workbench.sessions.manager"] = real_manager
            if not ok then
                error(err)
            end
        end

        ---@param win integer
        local function marker_match(win)
            for _, m in ipairs(vim.fn.getmatches(win)) do
                if m.group == "PiSessionsListCurrent" then
                    return m
                end
            end
            return nil
        end

        --- Highlight group of the dot extmark on a line of the list buffer.
        ---@param bufnr integer
        ---@param lnum integer 1-based
        local function dot_extmark_hl(bufnr, lnum)
            local ns = vim.api.nvim_create_namespace("pi-sessions-list")
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                ns,
                { lnum - 1, 0 },
                { lnum - 1, -1 },
                { details = true }
            )
            assert.are.equal(2, #marks) -- dot + name
            return marks[1][4].hl_group
        end

        it("is steady while the current session is idle", function()
            local s = fetchable_session({ tab = vim.api.nvim_get_current_tabpage() })
            with_list_session(s, function()
                local win = vim.api.nvim_get_current_win()
                SessionList._set_blink_tick(0)
                SessionList._render()
                assert.is_not_nil(marker_match(win))
                SessionList._set_blink_tick(1)
                SessionList._render()
                assert.is_not_nil(marker_match(win))
            end)
        end)

        it("blinks while the current session is busy, keeping the agent color", function()
            local s = fetchable_session({ tab = vim.api.nvim_get_current_tabpage(), streaming = true })
            with_list_session(s, function()
                local win = vim.api.nvim_get_current_win()
                local bufnr = vim.api.nvim_win_get_buf(win)

                -- On phase: the marker covers the dot in the agent color;
                -- the busy yellow never shows for the current session.
                SessionList._set_blink_tick(0)
                SessionList._render()
                local m = marker_match(win)
                assert.is_not_nil(m)
                assert.same({ 1, 2, 3 }, m.pos1)
                assert.are.equal("PiSessionsListBusy", dot_extmark_hl(bufnr, 1))

                -- Off phase: no marker; the dot falls through to the dim
                -- buffer-level color (same rhythm as other blinking dots).
                SessionList._set_blink_tick(1)
                SessionList._render()
                assert.is_nil(marker_match(win))
                assert.are.equal("PiSessionsListDotDim", dot_extmark_hl(bufnr, 1))
            end)
        end)
    end)

    describe("open / render / toggle", function()
        it("uses session entry focus when opening a selected session", function()
            local session = fake_session({ tab = vim.api.nvim_get_current_tabpage() })
            session.id = 42
            local activated
            local focused
            session.chat.focus_for_session_entry = function()
                focused = true
            end
            SessionList.on_session_info_changed(session, "selected")

            local real_manager = package.loaded["agent-workbench.sessions.manager"]
            package.loaded["agent-workbench.sessions.manager"] = {
                list = function()
                    return { session }
                end,
                get = function()
                    return nil
                end,
                get_by_id = function(id)
                    return id == session.id and session or nil
                end,
                activate = function(value)
                    activated = value
                end,
            }
            local ok, err = pcall(function()
                SessionList.open()
                local callback
                for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
                    if map.lhs == "<CR>" then
                        callback = map.callback
                        break
                    end
                end
                assert.is_not_nil(callback)
                callback()
                assert.are.equal(session, activated)
                assert.is_true(focused)
            end)
            package.loaded["agent-workbench.sessions.manager"] = real_manager
            if not ok then
                error(err)
            end
        end)

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
            local Config = require("agent-workbench.config")
            local saved = Config.options.layout.default
            Config.options.layout.default = "float"
            SessionList.open()
            local cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
            assert.are.equal("editor", cfg.relative)
            Config.options.layout.default = saved
        end)

        it("sessions_list.mode overrides the chat/default layout", function()
            local Config = require("agent-workbench.config")
            local saved_mode = Config.options.sessions_list.mode
            local saved_default = Config.options.layout.default

            Config.options.sessions_list.mode = "float"
            Config.options.layout.default = "side"
            SessionList.open()
            assert.are.equal("editor", vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative)
            SessionList.close()

            Config.options.sessions_list.mode = "side"
            Config.options.layout.default = "float"
            SessionList.open()
            assert.are.equal("", vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative)

            Config.options.sessions_list.mode = saved_mode
            Config.options.layout.default = saved_default
        end)
    end)
end)
