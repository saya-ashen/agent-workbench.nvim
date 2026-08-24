local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sorcar_root = vim.env.SORCAR_NVIM_ROOT
vim.opt.runtimepath:prepend(sorcar_root)
package.path = table.concat({ sorcar_root .. "/lua/?.lua", sorcar_root .. "/lua/?/init.lua", package.path }, ";")

local Config = require("agent-workbench.config")
local Sessions = require("agent-workbench.sessions.manager")
local Workbench = require("agent-workbench")

local listeners = {}
local sent = {}
local state = {
    connection = { connected = false, generation = 0 },
    registry = {},
    registry_generation = 0,
    tabs = {},
}
local controller = {
    active_generation = 0,
    state = state,
    add_listener = function(_, listener)
        listeners[#listeners + 1] = listener
        return function() end
    end,
    connect = function(self)
        self.active_generation = 1
        state.connection = { connected = true, generation = 1, stale = false }
        for _, listener in ipairs(listeners) do
            listener({ type = "connection_connected" }, 1)
        end
        return true
    end,
    close = function()
        state.connection.connected = false
    end,
}
local lifecycle = {
    add_listener = function()
        return function() end
    end,
    open = function(_, tab_id)
        sent[#sent + 1] = { type = "openTab", tabId = tab_id }
        return true
    end,
    close = function() end,
}
local actions = {
    run = function(_, tab_id, prompt)
        sent[#sent + 1] = { type = "run", tabId = tab_id, prompt = prompt }
        return true
    end,
    steer = function(_, tab_id, prompt)
        sent[#sent + 1] = { type = "steer", tabId = tab_id, prompt = prompt }
        return true
    end,
    stop = function(_, tab_id)
        sent[#sent + 1] = { type = "stop", tabId = tab_id }
        return true
    end,
    close_tab = function(_, tab_id)
        sent[#sent + 1] = { type = "closeTab", tabId = tab_id }
        return true
    end,
}

require("kiss-sorcar.agent_workbench").register()
Config.setup({
    backend = "sorcar",
    backend_options = {
        controller = controller,
        tab_lifecycle = lifecycle,
        actions = actions,
        path = "/tmp/fake.sock",
    },
    render = { markdown = { enabled = false } },
    prompt = { history = { enabled = false }, draft = { enabled = false } },
})

local session = assert(Sessions.get_or_create({ layout = "buffer" }))
local tab_id = "agent-workbench-1"
state.registry_generation = 1
for _, listener in ipairs(listeners) do
    listener({ type = "tabs_state", tabs = {} }, 1)
end
state.registry = { { tabId = tab_id } }
state.registry_generation = 1
state.tabs[tab_id] = { running = false, running_generation = 1, transcript = {} }
for _, listener in ipairs(listeners) do
    listener({ type = "tabs_state", tabs = state.registry }, 1)
end

session.chat._prompt:set_text("inspect repository")
session.chat:submit()
assert(sent[#sent].type == "run", "prompt did not use Sorcar action: " .. vim.inspect(sent))
state.tabs[tab_id].running = true
for _, event in ipairs({
    { type = "status", tabId = tab_id, running = true },
    { type = "thinking_start", tabId = tab_id },
    { type = "thinking_delta", tabId = tab_id, text = "checking" },
    { type = "thinking_end", tabId = tab_id },
    { type = "text_delta", tabId = tab_id, text = "answer" },
    { type = "result", tabId = tab_id, text = "semantic result" },
    { type = "task_done", tabId = tab_id },
}) do
    for _, listener in ipairs(listeners) do
        listener(event, 1)
    end
end
assert(session.chat:is_streaming(), "result/lifecycle ended run before status(false)")
session.chat._prompt:set_text("focus")
session.chat:submit()
assert(sent[#sent].type == "steer", "live prompt did not use steering action")
Workbench.abort()
assert(sent[#sent].type == "stop", "abort did not use guarded stop action")
for _, listener in ipairs(listeners) do
    listener({ type = "status", tabId = tab_id, running = false }, 1)
end
assert(not session.chat:is_streaming(), "status(false) did not settle Chat")
assert(
    vim.wait(1000, function()
        local rendered = table.concat(vim.api.nvim_buf_get_lines(session.chat:history_buf(), 0, -1, false), "\n")
        return rendered:find("answer", 1, true) ~= nil
    end, 10),
    "stream render did not flush"
)

local text = table.concat(vim.api.nvim_buf_get_lines(session.chat:history_buf(), 0, -1, false), "\n")
assert(text:find("Thought for", 1, true), "thinking block missing from History:\n" .. text)
assert(text:find("answer", 1, true), "streamed text missing from History:\n" .. text)
Sessions._reset()
assert(sent[#sent].type == "closeTab", "session close did not close Sorcar tab")
print("PASS Agent Workbench Sorcar backend e2e")
vim.cmd("qa!")
