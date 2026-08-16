--- Shared matching logic for @-mention and /command completion sources.

local FilesCache = require("agent-workbench.cache.files")
local CommandsCache = require("agent-workbench.cache.commands")
local Providers = require("agent-workbench.mention_providers")

local M = {}

--- Stop the fuzzy pass after this many results. Completion menus page
--- through far fewer than this; on huge repos an unbounded fuzzy scan is
--- the dominant per-keystroke cost.
local MAX_FUZZY_RESULTS = 100

--- Subsequence check on already-lowercased strings.
---@param lquery string lowercased query
---@param ltarget string lowercased target
---@return boolean
local function fuzzy_match_lower(lquery, ltarget)
    local qi = 1
    local ql = #lquery
    for ti = 1, #ltarget do
        if ltarget:byte(ti) == lquery:byte(qi) then
            qi = qi + 1
            if qi > ql then
                return true
            end
        end
    end
    return false
end

--- Check if all characters of query appear in order in target (case-insensitive).
---@param query string
---@param target string
---@return boolean
function M.fuzzy_match(query, target)
    return fuzzy_match_lower(query:lower(), target:lower())
end

--- Memoized parallel arrays of lowercased paths, keyed weakly by the files
--- array's identity: FilesCache rebuilds its array on every refresh, so the
--- lowered copy is computed once per cache generation and GC'd with the
--- array it belongs to.
---@type table<string[], string[]>
local lowered_memo = setmetatable({}, { __mode = "k" })

---@param files string[]
---@return string[] parallel lowercased array
local function lowered_paths(files)
    local lower = lowered_memo[files]
    if not lower then
        lower = {}
        for i, path in ipairs(files) do
            lower[i] = path:lower()
        end
        lowered_memo[files] = lower
    end
    return lower
end

--- Two-pass file matching: prefix matches (with directory collapsing) then
--- fuzzy matches (full paths, capped at MAX_FUZZY_RESULTS).
--- Calls make_item(path_or_dir, kind, is_fuzzy) for each result.
--- kind is "file" or "dir". Results are returned in priority order.
---@param prefix string typed text after @
---@param make_item fun(path: string, kind: "file"|"dir", is_fuzzy: boolean): table
---@return table[]
function M.complete_files(prefix, make_item)
    local project_files = FilesCache.list()
    local items = {}
    local seen_dirs = {}
    local prefix_matched = {}

    local plen = #prefix
    local first_byte = plen > 0 and prefix:byte(1) or nil

    -- Pass 1: prefix matches with directory collapsing
    for _, path in ipairs(project_files) do
        if plen == 0 or (path:byte(1) == first_byte and path:sub(1, plen) == prefix) then
            if plen > 0 then
                prefix_matched[path] = true
            end
            local slash = path:find("/", plen + 1)
            if slash then
                local dir = path:sub(1, slash)
                if not seen_dirs[dir] then
                    seen_dirs[dir] = true
                    items[#items + 1] = make_item(dir, "dir", false)
                end
            else
                items[#items + 1] = make_item(path, "file", false)
            end
        end
    end

    -- Pass 2: fuzzy matches on full path (case-insensitive, capped). The
    -- scan is inlined and anchored on a C-speed find() of the first query
    -- character so no-match queries reject without a Lua byte loop; paths
    -- are matched against memoized lowercase copies (one lower() per path
    -- per cache generation instead of per keystroke).
    if plen > 0 then
        local lprefix = prefix:lower()
        local lfirst = lprefix:sub(1, 1)
        local lower = lowered_paths(project_files)
        local fuzzy_count = 0
        for i, path in ipairs(project_files) do
            if not prefix_matched[path] then
                local lt = lower[i]
                -- Greedy subsequence scan anchored at the first occurrence
                -- of the first query char (equivalent to a scan from
                -- position 1: the earliest anchor is always optimal).
                local start = lt:find(lfirst, 1, true)
                if start then
                    local matched = plen == 1
                    if not matched then
                        local qi = 2
                        for ti = start + 1, #lt do
                            if lt:byte(ti) == lprefix:byte(qi) then
                                qi = qi + 1
                                if qi > plen then
                                    matched = true
                                    break
                                end
                            end
                        end
                    end
                    if matched then
                        items[#items + 1] = make_item(path, "file", true)
                        fuzzy_count = fuzzy_count + 1
                        if fuzzy_count >= MAX_FUZZY_RESULTS then
                            break
                        end
                    end
                end
            end
        end
    end

    return items
end

--- Two-pass dynamic-provider matching: case-insensitive prefix matches
--- first, then fuzzy matches. Providers are few, so both passes are cheap.
--- Calls make_item(provider, is_fuzzy) for each result.
---@param prefix string typed text after @
---@param make_item fun(provider: agent_workbench.MentionProvider, is_fuzzy: boolean): table
---@return table[]
function M.complete_providers(prefix, make_item)
    local lprefix = prefix:lower()
    local items = {}
    local seen = {}

    -- Pass 1: prefix matches on name (case-insensitive)
    for _, provider in ipairs(Providers.list()) do
        local lname = provider.name:lower()
        if lname:sub(1, #lprefix) == lprefix then
            seen[provider.name] = true
            items[#items + 1] = make_item(provider, false)
        end
    end

    -- Pass 2: fuzzy matches on name
    if lprefix ~= "" then
        for _, provider in ipairs(Providers.list()) do
            if not seen[provider.name] and fuzzy_match_lower(lprefix, provider.name:lower()) then
                items[#items + 1] = make_item(provider, true)
            end
        end
    end

    return items
end

--- Two-pass command matching: prefix matches then fuzzy matches.
--- Skills are also matched by their short name (after "skill:").
--- Calls make_item(cmd, is_fuzzy) for each result.
---@param prefix string typed text after /
---@param make_item fun(cmd: agent_workbench.SlashCommand, is_fuzzy: boolean): table
---@return table[]
function M.complete_commands(prefix, make_item)
    local commands = CommandsCache.list()
    if prefix == "" then
        local items = {}
        for _, cmd in ipairs(commands) do
            items[#items + 1] = make_item(cmd, false)
        end
        return items
    end

    local lprefix = prefix:lower()
    local items = {}
    local seen = {}

    --- Check if lprefix is a prefix of name.
    ---@param name string already lowercased
    local function is_prefix(name)
        return name:sub(1, #lprefix) == lprefix
    end

    --- Get the short name for skills (after "skill:"), or nil.
    ---@param cmd agent_workbench.SlashCommand
    ---@return string? lowercased short name
    local function skill_short(cmd)
        if cmd.source == "skill" then
            return cmd.name:lower():match("^skill:(.+)$")
        end
    end

    -- Pass 1: prefix matches on full name or skill short name
    for _, cmd in ipairs(commands) do
        local lname = cmd.name:lower()
        local short = skill_short(cmd)
        if is_prefix(lname) or (short and is_prefix(short)) then
            seen[cmd.name] = true
            items[#items + 1] = make_item(cmd, false)
        end
    end

    -- Pass 2: fuzzy matches on full name or skill short name
    for _, cmd in ipairs(commands) do
        if not seen[cmd.name] then
            local lname = cmd.name:lower()
            local short = skill_short(cmd)
            if fuzzy_match_lower(lprefix, lname) or (short and fuzzy_match_lower(lprefix, short)) then
                items[#items + 1] = make_item(cmd, true)
            end
        end
    end

    return items
end

return M
