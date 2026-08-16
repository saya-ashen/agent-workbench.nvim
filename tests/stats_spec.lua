-- :PiSessionStats — fetch get_session_stats + get_entries in parallel and
-- render a dialog dashboard. The pure logic lives in pi.stats (token
-- formatting, per-model cost breakdown, cache waste, dashboard rendering);
-- the command specs drive the session manager against a stubbed Rpc with
-- canned responses and capture the rendered dialog.
--
-- Data shapes mirror the pi RPC protocol (docs/rpc.md): SessionStats from
-- get_session_stats, SessionEntry[] from get_entries, and the Usage payload
-- ({ input, output, cacheRead, cacheWrite, cost: { input, output, cacheRead,
-- cacheWrite, total } }) on assistant/toolResult/compaction entries.

local Config = require("agent-workbench.config")
local Rpc = require("agent-workbench.rpc")
local Sessions = require("agent-workbench.sessions.manager")
local Pi = require("agent-workbench")
local Stats = require("agent-workbench.stats")

Config.setup({})
Pi.setup({})

--- Build a Usage payload.
---@param input integer
---@param output integer
---@param cache_read integer
---@param cache_write integer
---@param cost table cost split + total (defaults: input/output/cacheRead priced at 1$/M, cacheWrite 2$/M)
---@return table
local function usage(input, output, cache_read, cache_write, cost)
    cost = cost or {}
    return {
        input = input,
        output = output,
        cacheRead = cache_read,
        cacheWrite = cache_write,
        cost = {
            input = cost.input or input / 1e6,
            output = cost.output or output / 1e6,
            cacheRead = cost.cacheRead or cache_read / 1e6,
            cacheWrite = cost.cacheWrite or (cache_write * 2) / 1e6,
            total = cost.total or (input + output + cache_read + cache_write * 2) / 1e6,
        },
    }
end

--- Build a session entry.
---@param type string
---@param data table
---@return table
local entry_seq = 0
local function entry(type, data)
    local result = vim.deepcopy(data)
    result.type = type
    entry_seq = entry_seq + 1
    result.id = "e" .. entry_seq
    return result
end

---@param provider string
---@param model string
---@param usage_data table
---@param response_model? string
---@return table
local function assistant_entry(provider, model, usage_data, response_model)
    return entry("message", {
        message = {
            role = "assistant",
            provider = provider,
            model = model,
            responseModel = response_model,
            usage = usage_data,
        },
    })
end

local SAMPLE_STATS = {
    sessionFile = "/home/user/.local/share/pi/sessions/abc123.jsonl",
    sessionId = "abc123",
    userMessages = 5,
    assistantMessages = 7,
    toolCalls = 12,
    toolResults = 11,
    totalMessages = 24,
    tokens = { input = 50000, output = 10000, cacheRead = 40000, cacheWrite = 5000, total = 105000 },
    cost = 0.45,
    contextUsage = { tokens = 60000, contextWindow = 200000, percent = 30 },
}

local SAMPLE_BREAKDOWN = {
    { key = "deepseek/deepseek-chat", cost = 0.281, tokens = 80000 },
    { key = "anthropic/claude-3.5-sonnet", cost = 0.148, tokens = 20000 },
    { key = "Tools/summaries", cost = 0.021, tokens = 5000 },
}

describe("stats.format_tokens", function()
    it("formats small counts verbatim", function()
        assert.are.equal("0", Stats.format_tokens(0))
        assert.are.equal("500", Stats.format_tokens(500))
        assert.are.equal("999", Stats.format_tokens(999))
    end)

    it("formats thousands with one decimal below 9.95k", function()
        assert.are.equal("1.2k", Stats.format_tokens(1234))
        assert.are.equal("9.9k", Stats.format_tokens(9949))
    end)

    it("rounds to whole k from 9.95k up", function()
        assert.are.equal("10k", Stats.format_tokens(9950))
        assert.are.equal("200k", Stats.format_tokens(200000))
        assert.are.equal("999k", Stats.format_tokens(999000))
    end)

    it("formats millions with one decimal below 9.95M", function()
        assert.are.equal("1.2M", Stats.format_tokens(1234567))
        assert.are.equal("9.9M", Stats.format_tokens(9900000))
    end)

    it("rounds to whole M from 9.95M up", function()
        assert.are.equal("10M", Stats.format_tokens(9950000))
        assert.are.equal("123M", Stats.format_tokens(123000000))
    end)
end)

describe("stats.get_usage_cost_breakdown", function()
    it("groups assistant messages by provider/responseModel", function()
        local entries = {
            assistant_entry("openrouter", "deepseek-chat", usage(1000, 500, 0, 0, { total = 0.01 })),
            assistant_entry("openrouter", "deepseek-chat", usage(2000, 100, 0, 0, { total = 0.02 })),
            assistant_entry("anthropic", "claude-3.5-sonnet", usage(500, 50, 0, 0, { total = 0.04 })),
        }
        local result = Stats.get_usage_cost_breakdown(entries)
        assert.are.equal(2, #result)
        assert.are.equal("anthropic/claude-3.5-sonnet", result[1].key) -- highest cost first
        assert.are.equal(0.04, result[1].cost)
        assert.are.equal(550, result[1].tokens)
        assert.are.equal("openrouter/deepseek-chat", result[2].key)
        assert.are.equal(0.03, result[2].cost)
        assert.are.equal(3600, result[2].tokens)
    end)

    it("prefers responseModel over the requested model in the key", function()
        local entries = {
            assistant_entry(
                "openrouter",
                "auto",
                usage(100, 100, 0, 0, { total = 0.01 }),
                "anthropic/claude-3.5-sonnet"
            ),
        }
        local result = Stats.get_usage_cost_breakdown(entries)
        assert.are.equal("openrouter/anthropic/claude-3.5-sonnet", result[1].key)
    end)

    it("buckets tool results, compaction and branch summaries under Tools/summaries", function()
        local entries = {
            entry("message", {
                message = { role = "toolResult", usage = usage(0, 0, 0, 0, { total = 0.004 }) },
            }),
            entry("compaction", { usage = usage(0, 0, 0, 0, { total = 0.006 }) }),
            entry("branch_summary", { usage = usage(0, 0, 0, 0, { total = 0.002 }) }),
        }
        local result = Stats.get_usage_cost_breakdown(entries)
        assert.are.equal(1, #result)
        assert.are.equal("Tools/summaries", result[1].key)
        assert.are.equal(0.012, result[1].cost)
    end)

    it("ignores user messages and tool results without usage", function()
        local entries = {
            entry("message", { message = { role = "user", content = "hi" } }),
            entry("message", { message = { role = "toolResult", usage = nil } }),
            entry("custom", { customType = "x" }),
        }
        assert.are.equal(0, #Stats.get_usage_cost_breakdown(entries))
    end)

    it("drops entries with neither cost nor tokens", function()
        local entries = {
            assistant_entry("openrouter", "deepseek-chat", usage(0, 0, 0, 0)),
            assistant_entry("openrouter", "deepseek-chat", usage(0, 0, 0, 0, { total = 0 })),
        }
        assert.are.equal(0, #Stats.get_usage_cost_breakdown(entries))
    end)

    it("counts token-only entries (free models) and sorts by cost then tokens", function()
        local entries = {
            assistant_entry("free", "model-a", usage(5000, 0, 0, 0)),
            assistant_entry("free", "model-b", usage(2000, 0, 0, 0)),
            assistant_entry("free", "model-a", usage(3000, 0, 0, 0)),
        }
        local result = Stats.get_usage_cost_breakdown(entries)
        assert.are.equal(2, #result)
        assert.are.equal("free/model-a", result[1].key) -- more tokens first at equal cost
        assert.are.equal(8000, result[1].tokens)
        assert.are.equal("free/model-b", result[2].key)
        assert.are.equal(2000, result[2].tokens)
    end)
end)

describe("stats.compute_cache_waste", function()
    it("counts nothing on the first turn", function()
        local entries = { assistant_entry("anthropic", "claude-3.5-sonnet", usage(1000, 100, 900, 0)) }
        local totals = Stats.compute_cache_waste(entries)
        assert.are.equal(0, totals.missedTokens)
        assert.are.equal(0, totals.missCount)
    end)

    it("counts prompt tokens re-billed when the next turn misses the cache", function()
        local entries = {
            assistant_entry("anthropic", "claude-3.5-sonnet", usage(10000, 500, 9000, 100)),
            assistant_entry("anthropic", "claude-3.5-sonnet", usage(10000, 500, 5000, 100)),
        }
        local totals = Stats.compute_cache_waste(entries)
        -- min(prev prompt 20000, cur prompt 15100) - cur cacheRead 5000 = 10100
        assert.are.equal(10100, totals.missedTokens)
        assert.are.equal(1, totals.missCount)
    end)

    it("ignores misses at or below the 1024-token noise floor", function()
        local entries = {
            assistant_entry("anthropic", "claude-3.5-sonnet", usage(1000, 100, 900, 100)),
            assistant_entry("anthropic", "claude-3.5-sonnet", usage(1000, 100, 999, 100)), -- miss 1
        }
        local totals = Stats.compute_cache_waste(entries)
        assert.are.equal(0, totals.missedTokens)
        assert.are.equal(0, totals.missCount)
    end)

    it("ignores providers that never report caching", function()
        local entries = {
            assistant_entry("openrouter", "some-model", usage(10000, 500, 0, 0)),
            assistant_entry("openrouter", "some-model", usage(10000, 500, 0, 0)),
        }
        local totals = Stats.compute_cache_waste(entries)
        assert.are.equal(0, totals.missedTokens)
        assert.are.equal(0, totals.missCount)
    end)

    it("counts a total miss on a cache-reporting provider", function()
        local entries = {
            assistant_entry("anthropic", "claude-3.5-sonnet", usage(10000, 500, 9000, 100)),
            assistant_entry("anthropic", "claude-3.5-sonnet", usage(10000, 500, 0, 0)),
        }
        local totals = Stats.compute_cache_waste(entries)
        -- min(prev 20000, cur 10000) - 0 = 10000
        assert.are.equal(10000, totals.missedTokens)
        assert.are.equal(1, totals.missCount)
    end)

    it("resets the previous request after compaction", function()
        local entries = {
            assistant_entry("anthropic", "claude-3.5-sonnet", usage(10000, 500, 9000, 100)),
            entry("compaction", { usage = usage(0, 0, 0, 0) }),
            assistant_entry("anthropic", "claude-3.5-sonnet", usage(10000, 500, 0, 0)),
        }
        local totals = Stats.compute_cache_waste(entries)
        assert.are.equal(0, totals.missedTokens)
        assert.are.equal(0, totals.missCount)
    end)

    it("computes the exact re-billed dollar amount", function()
        -- First turn: prompt 20000, cacheRead 18000 at 0.1$/M.
        -- Second turn: prompt 20000, cacheRead 5000, input 15000.
        -- Paid rate on the re-billed 15000 tokens = input rate 1$/M.
        local entries = {
            assistant_entry(
                "anthropic",
                "claude-3.5-sonnet",
                usage(2000, 500, 18000, 0, {
                    input = 0.002,
                    cacheRead = 0.0018,
                })
            ),
            assistant_entry(
                "anthropic",
                "claude-3.5-sonnet",
                usage(15000, 500, 5000, 0, {
                    input = 0.015,
                    cacheRead = 0.0005,
                })
            ),
        }
        local totals = Stats.compute_cache_waste(entries)
        -- min(prev 20000, cur 20000) - cacheRead 5000 = 15000 missed
        assert.are.equal(15000, totals.missedTokens)
        -- missed * (paid rate - read rate) = 15000 * (0.015/15000 - 0.0005/5000)
        -- = 15000 * (1e-6 - 1e-7) = 15000 * 9e-7 = 0.0135
        assert.are.equal(1, totals.missCount)
        assert.is_true(math.abs(totals.missedCost - 0.0135) < 1e-9)
    end)
end)

describe("stats.render_stats", function()
    it("renders identity, messages, tokens, cost and context sections", function()
        local rendered = Stats.render_stats(SAMPLE_STATS, SAMPLE_BREAKDOWN, {
            missedTokens = 12345,
            missedCost = 0.012,
            missCount = 3,
        })
        local lines = rendered.lines
        assert.are.equal("  File  /home/user/.local/share/pi/sessions/abc123.jsonl", lines[1])
        assert.are.equal("  ID    abc123", lines[2])
        assert.are.equal("Messages", lines[3])
        assert.are.equal("  User 5 · Assistant 7 · Tools 12 calls / 11 results", lines[4])
        assert.are.equal("Tokens", lines[5])
        assert.are.equal("  Input    50k", lines[6])
        -- prompt = 50000 + 40000 + 5000 = 95000; hit rate 40000/95000 = 42.1%
        assert.are.equal("  Cached   40k  (42.1% hit)", lines[7])
        assert.are.equal("  Uncached 55k  (incl. 5.0k writes)", lines[8])
        assert.are.equal("  Output   10k", lines[9])
        assert.are.equal("  Total    105k", lines[10])
        assert.are.equal("Cost  $0.450", lines[11])
        assert.are.equal("  deepseek/deepseek-chat       $0.281 ██████░░░░ 62%", lines[12])
        assert.are.equal("  anthropic/claude-3.5-sonnet  $0.148 ███░░░░░░░ 33%", lines[13])
        assert.are.equal("  Tools/summaries              $0.021 ░░░░░░░░░░ 5%", lines[14])
        assert.are.equal("  Cache re-billed  $0.012  (12k tokens, 3 misses)", lines[15])
        -- Context: title on its own line, then tokens/window, then the bar.
        assert.are.equal("Context", lines[16])
        assert.are.equal("  60k / 200k", lines[17])
        assert.are.equal("  █████░░░░░░░░░░░  30.0%", lines[18])
    end)

    it("highlights section headers, dims labels and colors bar fills", function()
        local rendered = Stats.render_stats(SAMPLE_STATS, SAMPLE_BREAKDOWN, {
            missedTokens = 0,
            missedCost = 0,
            missCount = 0,
        })
        local hl = rendered.highlights
        assert.are.equal("PiToolHeader", hl[2][1].hl)
        assert.are.equal("Comment", hl[1][1].hl) -- ID label
        -- Cost row: label dim, filled bar portion in PiStatsBar.
        local cost_hl = hl[11]
        assert.are.equal("Comment", cost_hl[1].hl)
        assert.are.equal(0, cost_hl[1].start_col)
        assert.are.equal("PiStatsBar", cost_hl[2].hl)
        assert.are.equal(38, cost_hl[2].start_col)
        assert.are.equal(44, cost_hl[2].end_col)
        -- Zero-fraction row has no bar highlight.
        assert.are.equal(1, #hl[13])
        -- Context: title is its own section header, bar on its own line.
        assert.are.equal("PiToolHeader", hl[14][1].hl)
        local ctx_hl = hl[16]
        assert.are.equal("PiStatsBar", ctx_hl[1].hl)
        assert.are.equal(2, ctx_hl[1].start_col)
        assert.are.equal(18, ctx_hl[1].end_col)
    end)

    it("omits the cache split rows without cache activity", function()
        local stats = vim.deepcopy(SAMPLE_STATS)
        stats.tokens = { input = 60000, output = 10000, cacheRead = 0, cacheWrite = 0, total = 70000 }
        local rendered = Stats.render_stats(stats, {}, { missedTokens = 0, missedCost = 0, missCount = 0 })
        local lines = rendered.lines
        assert.are.equal("  Input    60k", lines[6])
        assert.are.equal("  Output   10k", lines[7])
        assert.are.equal("  Total    70k", lines[8])
    end)

    it("omits the cost section when there is nothing to show", function()
        local stats = vim.deepcopy(SAMPLE_STATS)
        stats.cost = 0
        local rendered = Stats.render_stats(stats, {}, { missedTokens = 0, missedCost = 0, missCount = 0 })
        assert.is_false(vim.tbl_contains(rendered.lines, "Cost  $0.000"))
        for _, line in ipairs(rendered.lines) do
            assert.is_nil(line:find("^  %S+%$", 1))
        end
    end)

    it("omits the context section without contextUsage", function()
        local stats = vim.deepcopy(SAMPLE_STATS)
        stats.contextUsage = nil
        local rendered = Stats.render_stats(stats, {}, { missedTokens = 0, missedCost = 0, missCount = 0 })
        for _, line in ipairs(rendered.lines) do
            assert.is_nil(line:find("^Context", 1))
        end
    end)

    it("shows an unknown context percent after compaction", function()
        local stats = vim.deepcopy(SAMPLE_STATS)
        stats.contextUsage = { tokens = nil, contextWindow = 200000, percent = nil }
        local rendered = Stats.render_stats(stats, {}, { missedTokens = 0, missedCost = 0, missCount = 0 })
        assert.are.equal("Context", rendered.lines[#rendered.lines - 1])
        assert.are.equal("  ? / 200k", rendered.lines[#rendered.lines])
    end)

    it("colors the context bar by the warn/error thresholds", function()
        local warn_stats = vim.deepcopy(SAMPLE_STATS)
        warn_stats.contextUsage = { tokens = 150000, contextWindow = 200000, percent = 75 }
        local warn = Stats.render_stats(warn_stats, {}, { missedTokens = 0, missedCost = 0, missCount = 0 })
        assert.are.equal("PiStatusLineWarning", warn.highlights[#warn.lines - 1][1].hl)

        local err_stats = vim.deepcopy(SAMPLE_STATS)
        err_stats.contextUsage = { tokens = 190000, contextWindow = 200000, percent = 95 }
        local err = Stats.render_stats(err_stats, {}, { missedTokens = 0, missedCost = 0, missCount = 0 })
        assert.are.equal("PiStatusLineError", err.highlights[#err.lines - 1][1].hl)
    end)

    it("truncates long model keys and session file paths", function()
        local stats = vim.deepcopy(SAMPLE_STATS)
        stats.sessionFile = "/home/user/.local/share/pi/sessions/" .. string.rep("x", 40) .. ".jsonl"
        local breakdown = {
            { key = "openrouter/" .. string.rep("very-long-model-name", 4), cost = 0.45, tokens = 100 },
        }
        local rendered = Stats.render_stats(stats, breakdown, { missedTokens = 0, missedCost = 0, missCount = 0 })
        assert.are.equal(
            "  File  /home/user/.local/share/pi/sessions/" .. string.rep("x", 9) .. "…",
            rendered.lines[1]
        )
        assert.are.equal(
            "  openrouter/very-long-model-nameve…  $0.450 ██████████ 100%",
            rendered.lines[12]
        )
    end)

    it("shows the cache re-billed line without a dollar figure when cost is unknown", function()
        local rendered = Stats.render_stats(SAMPLE_STATS, SAMPLE_BREAKDOWN, {
            missedTokens = 12345,
            missedCost = 0,
            missCount = 2,
        })
        assert.are.equal("  Cache re-billed  12k tokens, 2 misses", rendered.lines[15])
    end)
end)

-- ============================================================================
-- :PiSessionStats command flow (stubbed Rpc, no real pi process)
-- ============================================================================

local real_rpc = { start = Rpc.start, stop = Rpc.stop, send = Rpc.send }
local real_dialog_info = require("agent-workbench.ui.dialog").info

--- Commands sent through the stub, in order.
local sent = {}
--- type -> fun(cmd): pi.RpcEvent; nil responder = never answered.
local responders = {}
--- vim.notify spy records.
local notes = {}
--- Dialog.info captures.
local dialog_infos = {}

local function install_stub()
    sent = {}
    responders = {}
    notes = {}
    dialog_infos = {}

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

    require("agent-workbench.ui.dialog").info = function(opts)
        dialog_infos[#dialog_infos + 1] = vim.deepcopy(opts)
    end

    responders.get_commands = function()
        return { type = "response", success = true, data = { commands = {} } }
    end
    responders.get_session_stats = function()
        return { type = "response", success = true, data = SAMPLE_STATS }
    end
    responders.get_entries = function()
        return {
            type = "response",
            success = true,
            data = {
                leafId = nil,
                entries = {
                    assistant_entry("deepseek", "deepseek-chat", usage(1000, 100, 0, 0, { total = 0.01 })),
                    assistant_entry("deepseek", "deepseek-chat", usage(2000, 200, 0, 0, { total = 0.02 })),
                },
            },
        }
    end
end

local function restore_stub()
    Sessions.stop()
    Rpc.start = real_rpc.start
    Rpc.stop = real_rpc.stop
    Rpc.send = real_rpc.send
    require("agent-workbench.ui.dialog").info = real_dialog_info
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

describe("session stats command", function()
    before_each(function()
        install_stub()
    end)

    after_each(function()
        restore_stub()
    end)

    it("registers the :PiSessionStats user command", function()
        local cmds = vim.api.nvim_get_commands({})
        assert.is_not_nil(cmds["PiSessionStats"])
    end)

    it("is a silent no-op without an active session", function()
        Pi.session_stats()
        assert.are.equal(0, #sent)
        assert.are.equal(0, #notes)
        assert.are.equal(0, #dialog_infos)
    end)

    it("fetches stats and entries in parallel and renders the dashboard", function()
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        wait_or_fail(function()
            return #sent > 0
        end, "initial get_commands was not sent")

        local from = #sent
        Pi.session_stats()
        wait_or_fail(function()
            return #dialog_infos > 0
        end, "dialog was not rendered")

        assert.is_not_nil(select(1, find_after(from, "get_session_stats")))
        assert.is_not_nil(select(1, find_after(from, "get_entries")))

        local opts = dialog_infos[1]
        assert.are.equal("Pi Session Stats", opts.title)
        assert.is_not_nil(vim.tbl_contains(opts.lines, "Cost  $0.450"))
        -- Breakdown rows come from the get_entries fixture: 0.03 of 0.45 = 7%.
        assert.is_not_nil(
            vim.tbl_contains(opts.lines, "  deepseek/deepseek-chat  $0.030 █░░░░░░░░░ 7%")
        )
        assert.is_not_nil(opts.highlights)
    end)

    it("degrades to a stats-only view when get_entries fails", function()
        responders.get_entries = function()
            return { type = "response", success = false, error = "boom" }
        end
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        wait_or_fail(function()
            return #sent > 0
        end, "initial get_commands was not sent")

        Pi.session_stats()
        wait_or_fail(function()
            return #dialog_infos > 0
        end, "dialog was not rendered")

        local opts = dialog_infos[1]
        assert.is_not_nil(vim.tbl_contains(opts.lines, "Cost  $0.450"))
        -- No per-model rows, no bars.
        assert.is_false(vim.tbl_contains(opts.lines, "  deepseek/deepseek-chat  $0.030"))
        assert.are.equal(0, #notes)
    end)

    it("notifies and skips the dialog when get_session_stats fails", function()
        responders.get_session_stats = function()
            return { type = "response", success = false, error = "no session file" }
        end
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        wait_or_fail(function()
            return #sent > 0
        end, "initial get_commands was not sent")

        Pi.session_stats()
        wait_or_fail(function()
            return #notes > 0
        end, "no error notification")
        assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
        assert.is_not_nil(notes[#notes].msg:find("Failed to get session stats", 1, true))
        assert.are.equal(0, #dialog_infos)
    end)
end)
