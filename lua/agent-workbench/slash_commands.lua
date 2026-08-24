--- Local slash commands that mirror pi's TUI controls.
local M = {}

local builtin = {
    { name = "model", description = "Select model", source = "builtin" },
    { name = "thinking", description = "Set thinking level", source = "builtin" },
    { name = "compact", description = "Compact session context", source = "builtin" },
    { name = "name", description = "Set session display name", source = "builtin" },
    { name = "new", description = "Start a separate session", source = "builtin" },
    { name = "replace", description = "Replace current session", source = "builtin" },
    { name = "resume", description = "Resume another session", source = "builtin" },
    { name = "session", description = "Show session overview", source = "builtin" },
    { name = "abort", description = "Abort current operation", source = "builtin" },
}

---@class agent_workbench.SlashArgumentContext
---@field name string
---@field prefix string
---@field start integer 0-based replacement column

---@class agent_workbench.SlashArgumentCompletion
---@field value string
---@field label string
---@field description string

---@type table<agent_workbench.Session, table[]>
local model_cache = setmetatable({}, { __mode = "k" })
---@type table<agent_workbench.Session, fun(models: table[])[]>
local model_waiters = setmetatable({}, { __mode = "k" })
---@type table<agent_workbench.Session, table<string, string[]>>
local thinking_cache = setmetatable({}, { __mode = "k" })
---@type table<agent_workbench.Session, table<string, fun(levels: string[])[]>>
local thinking_waiters = setmetatable({}, { __mode = "k" })

---@return agent_workbench.SlashCommand[]
function M.list()
    local CommandsCache = require("agent-workbench.cache.commands")
    local result = vim.deepcopy(builtin)
    local seen = {}
    for _, command in ipairs(result) do
        seen[command.name] = true
    end
    for _, command in ipairs(CommandsCache.list()) do
        if not seen[command.name] then
            result[#result + 1] = command
            seen[command.name] = true
        end
    end
    return result
end

---@param command agent_workbench.SlashCommand
---@return string? lowercased skill short name
local function skill_short(command)
    if command.source == "skill" then
        return command.name:lower():match("^skill:(.+)$")
    end
end

---@param prefix string
---@return agent_workbench.SlashCommand[]
function M.match(prefix)
    local query = prefix:lower()
    local exact = {}
    local fuzzy = {}
    for _, command in ipairs(M.list()) do
        local name = command.name:lower()
        local short = skill_short(command)
        if name:sub(1, #query) == query or (short and short:sub(1, #query) == query) then
            exact[#exact + 1] = command
        elseif
            query ~= ""
            and (
                require("agent-workbench.completion").fuzzy_match(query, name)
                or (short and require("agent-workbench.completion").fuzzy_match(query, short))
            )
        then
            fuzzy[#fuzzy + 1] = command
        end
    end
    vim.list_extend(exact, fuzzy)
    return exact
end

---@param text string
---@return string? name, string args
function M.parse(text)
    local name, args = text:match("^%s*/([%w_:%-]+)%s*(.-)%s*$")
    return name, args or ""
end

---@param line string
---@param cursor integer Number of bytes before cursor
---@return agent_workbench.SlashArgumentContext?
function M.argument_context(line, cursor)
    local before = line:sub(1, cursor)
    local name, prefix = before:match("^/([%w_:%-]+)%s+(.*)$")
    if name ~= "model" and name ~= "thinking" then
        return nil
    end
    return { name = name, prefix = prefix, start = #before - #prefix }
end

---@param models table[]
---@param prefix string
---@return agent_workbench.SlashArgumentCompletion[]
local function model_completions(models, prefix)
    local Matcher = require("agent-workbench.completion")
    local query = prefix:lower()
    local direct = {}
    local fuzzy = {}
    for _, model in ipairs(models) do
        if type(model.provider) == "string" and type(model.id) == "string" then
            local canonical = model.provider .. "/" .. model.id
            local id = model.id:lower()
            local provider = model.provider:lower()
            local name = type(model.name) == "string" and model.name:lower() or ""
            local search = id
                .. " "
                .. provider
                .. " "
                .. canonical:lower()
                .. " "
                .. provider
                .. " "
                .. id
                .. " "
                .. name
            local item = { value = canonical, label = model.id, description = model.provider }
            if query == "" or id:sub(1, #query) == query or canonical:lower():sub(1, #query) == query then
                direct[#direct + 1] = item
            elseif Matcher.fuzzy_match(query, search) then
                fuzzy[#fuzzy + 1] = item
            end
        end
    end
    vim.list_extend(direct, fuzzy)
    return direct
end

---@param levels string[]
---@param prefix string
---@return agent_workbench.SlashArgumentCompletion[]
local function thinking_completions(levels, prefix)
    local Matcher = require("agent-workbench.completion")
    local query = prefix:lower()
    local direct = {}
    local fuzzy = {}
    for _, level in ipairs(levels) do
        local lower = level:lower()
        local item = { value = level, label = level, description = "thinking level" }
        if query == "" or lower:sub(1, #query) == query then
            direct[#direct + 1] = item
        elseif Matcher.fuzzy_match(query, lower) then
            fuzzy[#fuzzy + 1] = item
        end
    end
    vim.list_extend(direct, fuzzy)
    return direct
end

---@param session agent_workbench.Session
---@return string
local function thinking_model_key(session)
    local model = session.pinned_model
    if type(model) == "table" and type(model.provider) == "string" and type(model.id) == "string" then
        return model.provider .. "/" .. model.id
    end
    return ""
end

---@param name string
---@param prefix string
---@return agent_workbench.SlashArgumentCompletion[]?
function M.cached_argument_completions(name, prefix)
    local session = require("agent-workbench.sessions.manager").get()
    if name == "model" then
        local models = session and model_cache[session] or nil
        return models and model_completions(models, prefix) or nil
    end
    if name == "thinking" and session then
        local cache = thinking_cache[session]
        local levels = cache and cache[thinking_model_key(session)] or nil
        return levels and thinking_completions(levels, prefix) or nil
    end
    return nil
end

---@param session agent_workbench.Session
---@param prefix string
---@param callback fun(items: agent_workbench.SlashArgumentCompletion[])
local function request_model_completions(session, prefix, callback)
    local cached = model_cache[session]
    if cached then
        callback(model_completions(cached, prefix))
        return
    end

    local waiters = model_waiters[session]
    if not waiters then
        waiters = {}
        model_waiters[session] = waiters
    end
    waiters[#waiters + 1] = function(models)
        callback(model_completions(models, prefix))
    end
    if #waiters > 1 then
        return
    end

    local sent = session.rpc:send({ type = "get_available_models" }, function(res)
        vim.schedule(function()
            local models = res.success and (res.data or {}).models or nil
            if models then
                model_cache[session] = models
            end
            local pending = model_waiters[session] or {}
            model_waiters[session] = nil
            for _, waiter in ipairs(pending) do
                waiter(models or {})
            end
        end)
    end)
    if not sent then
        local pending = model_waiters[session] or {}
        model_waiters[session] = nil
        for _, waiter in ipairs(pending) do
            waiter({})
        end
    end
end

---@param session agent_workbench.Session
---@param key string
---@param levels string[]
local function finish_thinking_request(session, key, levels)
    local by_model = thinking_waiters[session] or {}
    local pending = by_model[key] or {}
    by_model[key] = nil
    if next(by_model) == nil then
        thinking_waiters[session] = nil
    end
    for _, waiter in ipairs(pending) do
        waiter(levels)
    end
end

---@param session agent_workbench.Session
---@param prefix string
---@param callback fun(items: agent_workbench.SlashArgumentCompletion[])
local function request_thinking_completions(session, prefix, callback)
    local key = thinking_model_key(session)
    local cache = thinking_cache[session]
    local cached = cache and cache[key] or nil
    if cached then
        callback(thinking_completions(cached, prefix))
        return
    end

    local by_model = thinking_waiters[session]
    if not by_model then
        by_model = {}
        thinking_waiters[session] = by_model
    end
    local waiters = by_model[key]
    if not waiters then
        waiters = {}
        by_model[key] = waiters
    end
    waiters[#waiters + 1] = function(levels)
        callback(thinking_completions(levels, prefix))
    end
    if #waiters > 1 then
        return
    end

    local sent = session.rpc:send({ type = "get_available_thinking_levels" }, function(res)
        vim.schedule(function()
            local levels = res.success and (res.data or {}).levels or nil
            if levels then
                cache = thinking_cache[session]
                if not cache then
                    cache = {}
                    thinking_cache[session] = cache
                end
                cache[key] = levels
            end
            finish_thinking_request(session, key, levels or {})
        end)
    end)
    if not sent then
        finish_thinking_request(session, key, {})
    end
end

---@param name string
---@param prefix string
---@param callback fun(items: agent_workbench.SlashArgumentCompletion[])
---@return boolean supported
function M.request_argument_completions(name, prefix, callback)
    if name ~= "model" and name ~= "thinking" then
        return false
    end
    local session = require("agent-workbench.sessions.manager").get()
    local supported = session
        and (
            (name == "model" and (session.capabilities == nil or session.capabilities.models))
            or (name == "thinking" and (session.capabilities == nil or session.capabilities.thinking))
        )
    if not session or not supported or not session.rpc or not session.rpc:is_running() then
        callback({})
        return true
    end
    if name == "model" then
        request_model_completions(session, prefix, callback)
    else
        request_thinking_completions(session, prefix, callback)
    end
    return true
end

function M._reset_argument_cache()
    model_cache = setmetatable({}, { __mode = "k" })
    model_waiters = setmetatable({}, { __mode = "k" })
    thinking_cache = setmetatable({}, { __mode = "k" })
    thinking_waiters = setmetatable({}, { __mode = "k" })
end

---@param text string
---@return boolean handled
function M.execute(text)
    local name, args = M.parse(text)
    if not name then
        return false
    end

    local Pi = require("agent-workbench")
    if name == "new" then
        Pi.new_session()
    elseif name == "replace" then
        Pi.replace_session()
    elseif name == "resume" then
        Pi.resume_session()
    elseif name == "model" then
        local session = require("agent-workbench.sessions.manager").get()
        if
            args ~= ""
            and session
            and (session.capabilities == nil or session.capabilities.models)
            and session.rpc
            and session.rpc:is_running()
        then
            local Models = require("agent-workbench.models")
            Models.with_available(session, function(models)
                for _, model in ipairs(models) do
                    if args == model.provider .. "/" .. model.id or args == model.id then
                        Models.set(session, model)
                        return
                    end
                end
                require("agent-workbench.notify").warn("Model not found: " .. args)
            end)
        else
            Pi.select_model()
        end
    elseif name == "thinking" then
        if args == "" then
            Pi.select_thinking_level()
        else
            local session = require("agent-workbench.sessions.manager").get()
            if
                session
                and (session.capabilities == nil or session.capabilities.thinking)
                and session.rpc
                and session.rpc:is_running()
            then
                require("agent-workbench.thinking").set(session, args)
            else
                Pi.select_thinking_level()
            end
        end
    elseif name == "compact" then
        Pi.compact(args ~= "" and args or nil)
    elseif name == "name" then
        Pi.set_session_name(args ~= "" and args or nil)
    elseif name == "session" then
        Pi.sessions()
    elseif name == "abort" then
        Pi.abort()
    else
        return false
    end
    return true
end

return M
