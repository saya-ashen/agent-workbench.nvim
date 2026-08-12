--- Session statistics: pure formatting and aggregation for :PiSessionStats.
---
--- Mirrors the TUI's /session info panel: SessionStats from get_session_stats,
--- the per-model cost breakdown (getUsageCostBreakdown over get_entries), and
--- the cache re-billed waste (computeCacheWaste). No UI dependencies — every
--- function here is testable in isolation; the float itself is rendered via
--- dialog.info() with per-line highlight ranges.

local M = {}

-- ============================================================================
-- Token formatting
-- ============================================================================

--- Format token count for display (e.g. 200000 -> "200k").
---@param count number
---@return string
function M.format_tokens(count)
    if count < 1000 then
        return tostring(count)
    elseif count < 9950 then
        return string.format("%.1fk", count / 1000)
    elseif count < 1000000 then
        return string.format("%dk", math.floor(count / 1000 + 0.5))
    elseif count < 9950000 then
        return string.format("%.1fM", count / 1000000)
    else
        return string.format("%dM", math.floor(count / 1000000 + 0.5))
    end
end

-- ============================================================================
-- Cost breakdown (port of the TUI's getUsageCostBreakdown, core/usage-totals.ts)
-- ============================================================================

---@class pi.StatsCostEntry
---@field key string
---@field cost number
---@field tokens integer

---@class pi.StatsTotals
---@field input number
---@field output number
---@field cacheRead number
---@field cacheWrite number
---@field cost number

--- Accumulate one usage payload into totals.
---@param totals pi.StatsTotals
---@param usage table Usage payload ({ input, output, cacheRead, cacheWrite, cost: { total } })
local function add_usage(totals, usage)
    totals.input = totals.input + (usage.input or 0)
    totals.output = totals.output + (usage.output or 0)
    totals.cacheRead = totals.cacheRead + (usage.cacheRead or 0)
    totals.cacheWrite = totals.cacheWrite + (usage.cacheWrite or 0)
    local cost = usage.cost
    totals.cost = totals.cost + (cost and cost.total or 0)
end

--- Group attributable usage by model, with tool results, compaction and branch
--- summaries in a shared bucket. Port of the TUI's getUsageCostBreakdown
--- (packages/coding-agent/src/core/usage-totals.ts): assistant messages are
--- keyed `provider/responseModel` (the concrete model when `responseModel`
--- differs from the requested `model`), everything else with usage lands in
--- "Tools/summaries". Entries with neither cost nor tokens are dropped; the
--- result is sorted by cost descending.
---@param entries table[] SessionEntry list from the RPC get_entries response
---@return pi.StatsCostEntry[]
function M.get_usage_cost_breakdown(entries)
    local by_key = {}
    local order = {}

    for _, entry in ipairs(entries) do
        local key
        local usage
        local message = entry.message
        if entry.type == "message" and message and message.role == "assistant" then
            key = message.provider .. "/" .. (message.responseModel or message.model)
            usage = message.usage
        elseif entry.type == "message" and message and message.role == "toolResult" and message.usage then
            key = "Tools/summaries"
            usage = message.usage
        elseif (entry.type == "branch_summary" or entry.type == "compaction") and entry.usage then
            key = "Tools/summaries"
            usage = entry.usage
        end
        if key and usage then
            if not by_key[key] then
                by_key[key] = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, cost = 0 }
                order[#order + 1] = key
            end
            add_usage(by_key[key], usage)
        end
    end

    local result = {}
    for _, key in ipairs(order) do
        local totals = by_key[key]
        local tokens = totals.input + totals.output + totals.cacheRead + totals.cacheWrite
        if totals.cost > 0 or tokens > 0 then
            result[#result + 1] = { key = key, cost = totals.cost, tokens = tokens }
        end
    end
    table.sort(result, function(a, b)
        if a.cost ~= b.cost then
            return a.cost > b.cost
        end
        if a.tokens ~= b.tokens then
            return a.tokens > b.tokens
        end
        return a.key < b.key
    end)
    return result
end

-- ============================================================================
-- Cache waste (port of the TUI's computeCacheWaste, core/cache-stats.ts)
-- ============================================================================

---@class pi.StatsCacheWaste
---@field missedTokens integer
---@field missedCost number
---@field missCount integer

--- Per-turn misses at or below this are cache breakpoint granularity noise.
local NOISE_FLOOR_TOKENS = 1024

--- Detect a cache miss on one assistant message relative to the previous
--- request. Returns nil when nothing is counted: first turn, after a reset,
--- no cache activity ever reported (provider without cache support), or miss
--- below the noise floor.
---
--- The extra cost is derived from the message's own cost breakdown (paid rate
--- from input+cacheWrite, read rate from cacheRead), so no model-pricing
--- runtime is needed; when cacheRead is 0 no read rate is known and the dollar
--- figure is left unknown (cost 0).
---@param prev table? PreviousRequest ({ promptTokens, reportedCache })
---@param message table AssistantMessage
---@return { missed: integer, cost: number }?
local function detect_cache_miss(prev, message)
    local usage = message.usage
    if not usage then
        return nil
    end
    local input = usage.input or 0
    local cacheRead = usage.cacheRead or 0
    local cacheWrite = usage.cacheWrite or 0
    local prompt = input + cacheRead + cacheWrite
    if not prev or prompt <= 0 or (cacheRead + cacheWrite == 0 and not prev.reportedCache) then
        return nil
    end

    local missed = math.min(prev.promptTokens, prompt) - cacheRead
    if missed <= NOISE_FLOOR_TOKENS then
        return nil
    end

    local cost = usage.cost or {}
    local paidTokens = input + cacheWrite
    local paidPerToken = 0
    if paidTokens > 0 then
        paidPerToken = ((cost.input or 0) + (cost.cacheWrite or 0)) / paidTokens
    end
    local readPerToken = 0
    if cacheRead > 0 then
        readPerToken = (cost.cacheRead or 0) / cacheRead
    end

    return { missed = missed, cost = missed * math.max(0, paidPerToken - readPerToken) }
end

--- Cumulative cache waste across a session: prompt tokens that should have
--- been cache reads (they were in the previous turn's prompt) but were
--- re-billed. Port of the TUI's computeCacheWaste (core/cache-stats.ts); the
--- model-pricing runtime is replaced by per-message cost breakdowns, so
--- missedCost is only known when the session data reports a cache-read rate.
---@param entries table[] SessionEntry list from the RPC get_entries response
---@return pi.StatsCacheWaste
function M.compute_cache_waste(entries)
    ---@type pi.StatsCacheWaste
    local totals = { missedTokens = 0, missedCost = 0, missCount = 0 }
    local prev ---@type table?

    for _, entry in ipairs(entries) do
        if entry.type == "compaction" or entry.type == "branch_summary" then
            -- The context legitimately changed; the next turn's prompt is new
            -- content, not re-billed content. Model switches are NOT exempt.
            prev = nil
        elseif entry.type == "message" and entry.message and entry.message.role == "assistant" then
            local message = entry.message
            local miss = detect_cache_miss(prev, message)
            if miss then
                totals.missedTokens = totals.missedTokens + miss.missed
                totals.missedCost = totals.missedCost + miss.cost
                totals.missCount = totals.missCount + 1
            end
            local usage = message.usage
            local prompt = usage and (usage.input or 0) + (usage.cacheRead or 0) + (usage.cacheWrite or 0) or 0
            if prompt > 0 then
                prev = {
                    promptTokens = prompt,
                    reportedCache = (prev and prev.reportedCache)
                        or (usage.cacheRead or 0) + (usage.cacheWrite or 0) > 0,
                }
            end
        end
    end
    return totals
end

-- ============================================================================
-- Dashboard rendering
-- ============================================================================

---@class pi.StatsRender
---@field lines string[]
---@field highlights table<integer, {start_col: integer, end_col: integer, hl: string}[]>

--- Width of per-model cost bars.
local COST_BAR_WIDTH = 10
--- Width of the context usage bar.
local CONTEXT_BAR_WIDTH = 16
--- Context percentage thresholds, matching the TUI footer and the statusline
--- `context` component defaults (warn 70 / error 90).
local CONTEXT_WARN = 70
local CONTEXT_ERROR = 90
--- Longest model key shown before truncation.
local MAX_KEY_WIDTH = 36
--- Longest session file path shown before truncation.
local MAX_PATH_WIDTH = 48

local BAR_FILLED = "█"
local BAR_EMPTY = "░"
local ELLIPSIS = "…"

--- Draw a horizontal bar of the given width for a fraction in [0, 1].
---@param fraction number
---@param width integer
---@return string
local function draw_bar(fraction, width)
    local filled = math.max(0, math.min(width, math.floor(fraction * width + 0.5)))
    return string.rep(BAR_FILLED, filled) .. string.rep(BAR_EMPTY, width - filled)
end

--- Truncate a string to a maximum byte length, adding an ellipsis.
---@param text string
---@param width integer
---@return string
local function truncate(text, width)
    if #text <= width then
        return text
    end
    if width <= #ELLIPSIS then
        return ELLIPSIS:sub(1, width)
    end
    return text:sub(1, width - #ELLIPSIS) .. ELLIPSIS
end

--- Build the :PiSessionStats dashboard: lines plus per-line highlight ranges
--- (row -> { start_col, end_col, hl }[], 0-based columns, end exclusive).
--- Rows are 0-based so they map directly onto the buffer for
--- nvim_buf_add_highlight.
---@param stats table SessionStats from the RPC get_session_stats response
---@param breakdown pi.StatsCostEntry[] cost breakdown (empty when unavailable)
---@param cache_waste pi.StatsCacheWaste cache waste totals (all zeros when unavailable)
---@return pi.StatsRender
function M.render_stats(stats, breakdown, cache_waste)
    local lines = {}
    local highlights = {}

    local function add_line(text, ranges)
        local row = #lines
        lines[#lines + 1] = text
        if ranges and #ranges > 0 then
            highlights[row] = ranges
        end
    end

    --- Section header in the tool-header highlight.
    ---@param title string
    local function section(title)
        add_line(title, { { start_col = 0, end_col = #title, hl = "PiToolHeader" } })
    end

    --- "  Label value" with the label dimmed.
    ---@param label string
    ---@param value string
    local function label_value(label, value)
        add_line("  " .. label .. value, { { start_col = 0, end_col = 2 + #label, hl = "Comment" } })
    end

    -- Identity
    if stats.sessionFile then
        label_value("File  ", truncate(stats.sessionFile, MAX_PATH_WIDTH))
    end
    label_value("ID    ", stats.sessionId or "?")

    -- Messages
    section("Messages")
    add_line(
        string.format(
            "  User %d · Assistant %d · Tools %d calls / %d results",
            stats.userMessages or 0,
            stats.assistantMessages or 0,
            stats.toolCalls or 0,
            stats.toolResults or 0
        )
    )

    -- Tokens
    local tokens = stats.tokens or {}
    local input = tokens.input or 0
    local output = tokens.output or 0
    local cacheRead = tokens.cacheRead or 0
    local cacheWrite = tokens.cacheWrite or 0
    local prompt = input + cacheRead + cacheWrite
    section("Tokens")
    label_value("Input    ", M.format_tokens(input))
    if prompt > 0 and (cacheRead > 0 or cacheWrite > 0) then
        local hit = string.format("%.1f%%", (cacheRead / prompt) * 100)
        label_value("Cached   ", M.format_tokens(cacheRead) .. "  (" .. hit .. " hit)")
        local uncached = M.format_tokens(input + cacheWrite)
        if cacheWrite > 0 then
            uncached = uncached .. "  (incl. " .. M.format_tokens(cacheWrite) .. " writes)"
        end
        label_value("Uncached ", uncached)
    end
    label_value("Output   ", M.format_tokens(output))
    label_value("Total    ", M.format_tokens(input + output + cacheRead + cacheWrite))

    -- Cost
    if stats.cost > 0 or #breakdown > 0 then
        section(string.format("Cost  $%.3f", stats.cost or 0))
        if #breakdown > 0 then
            local key_width = 0
            local cost_width = 0
            for _, entry in ipairs(breakdown) do
                key_width = math.max(key_width, math.min(#entry.key, MAX_KEY_WIDTH))
                cost_width = math.max(cost_width, #string.format("$%.3f", entry.cost))
            end
            for _, entry in ipairs(breakdown) do
                local key = truncate(entry.key, MAX_KEY_WIDTH)
                local cost = string.format("$%.3f", entry.cost)
                local pct = stats.cost > 0 and entry.cost / stats.cost or 0
                local bar = draw_bar(pct, COST_BAR_WIDTH)
                local bar_start = 2 + key_width + 2 + cost_width + 1
                local filled = math.max(0, math.min(COST_BAR_WIDTH, math.floor(pct * COST_BAR_WIDTH + 0.5)))
                local line = "  "
                    .. key
                    .. string.rep(" ", key_width - #key)
                    .. "  "
                    .. string.rep(" ", cost_width - #cost)
                    .. cost
                    .. " "
                    .. bar
                    .. string.format(" %d%%", math.floor(pct * 100 + 0.5))
                local ranges = { { start_col = 0, end_col = 2 + key_width, hl = "Comment" } }
                if filled > 0 then
                    ranges[#ranges + 1] = { start_col = bar_start, end_col = bar_start + filled, hl = "PiStatsBar" }
                end
                add_line(line, ranges)
            end
        end
        if cache_waste.missedTokens > 0 then
            local miss_label = cache_waste.missCount == 1 and "1 miss" or (cache_waste.missCount .. " misses")
            local detail = M.format_tokens(cache_waste.missedTokens) .. " tokens, " .. miss_label
            local text
            if cache_waste.missedCost >= 0.0001 then
                text = string.format("  Cache re-billed  $%.3f  (%s)", cache_waste.missedCost, detail)
            else
                text = "  Cache re-billed  " .. detail
            end
            add_line(text, { { start_col = 0, end_col = 2 + #"Cache re-billed", hl = "Comment" } })
        end
    end

    -- Context
    local context = stats.contextUsage
    if context then
        local window = M.format_tokens(context.contextWindow or 0)
        if context.percent == nil or context.tokens == nil then
            -- Unknown after compaction until the next response, like the TUI.
            add_line("Context  ? / " .. window, { { start_col = 0, end_col = #"Context", hl = "Comment" } })
        else
            local pct = context.percent
            local bar = draw_bar(pct / 100, CONTEXT_BAR_WIDTH)
            local tokens_text = M.format_tokens(context.tokens)
            local text = string.format("Context  %s / %s  %s  %.1f%%", tokens_text, window, bar, pct)
            local ranges = { { start_col = 0, end_col = #"Context", hl = "Comment" } }
            local bar_start = 9 + #tokens_text + 3 + #window + 2
            local bar_hl = "PiStatsBar"
            if pct > CONTEXT_ERROR then
                bar_hl = "PiStatusLineError"
            elseif pct > CONTEXT_WARN then
                bar_hl = "PiStatusLineWarning"
            end
            ranges[#ranges + 1] = { start_col = bar_start, end_col = bar_start + CONTEXT_BAR_WIDTH, hl = bar_hl }
            add_line(text, ranges)
        end
    end

    return { lines = lines, highlights = highlights }
end

return M
