--- Local slash commands that mirror pi's TUI controls.
local M = {}

local builtin = {
    { name = "model", description = "Select model", source = "builtin" },
    { name = "thinking", description = "Set thinking level", source = "builtin" },
    { name = "compact", description = "Compact session context", source = "builtin" },
    { name = "name", description = "Set session display name", source = "builtin" },
    { name = "new", description = "Start a new session", source = "builtin" },
    { name = "resume", description = "Resume another session", source = "builtin" },
    { name = "session", description = "Show session overview", source = "builtin" },
    { name = "abort", description = "Abort current operation", source = "builtin" },
}

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
    elseif name == "resume" then
        Pi.resume_session()
    elseif name == "model" then
        local session = require("agent-workbench.sessions.manager").get()
        if args ~= "" and session and session.rpc:is_running() then
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
            if session and session.rpc:is_running() then
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
