local M = {}

local builtins
local factories

local function reset()
    builtins = {
        pi = function(options)
            return require("agent-workbench.backends.pi").new(options)
        end,
    }
    factories = vim.deepcopy(builtins)
end

reset()

--- Register one backend factory.
---@param name string
---@param factory fun(options: table): agent_workbench.BackendSession
function M.register(name, factory)
    assert(type(name) == "string" and name ~= "", "backend name must be a non-empty string")
    assert(type(factory) == "function", "backend factory must be a function")
    assert(factories[name] == nil, "backend already registered: " .. name)
    factories[name] = factory
end

--- Return whether backend name is registered.
---@param name string
---@return boolean
function M.has(name)
    return factories[name] ~= nil
end

--- Return built-in default backend name.
---@return string
function M.default()
    return "pi"
end

--- Create named backend session.
---@param name string
---@param options table
---@return agent_workbench.BackendSession?
---@return string?
function M.create(name, options)
    local factory = factories[name]
    if not factory then
        return nil, "Unknown backend: " .. tostring(name)
    end
    return factory(options), nil
end

--- Reset registry for isolated tests.
function M._reset()
    reset()
end

return M
