--- Opt-in global keymap preset for Agent Workbench.

local Keys = require("agent-workbench.keys")
local Notify = require("agent-workbench.notify")

---@class agent_workbench.RecommendedKeymap
---@field key string
---@field prefixed? boolean
---@field modes string[]
---@field callback function
---@field desc string

---@class agent_workbench.InstalledRecommendedKeymap
---@field mode string
---@field lhs string
---@field effective_lhs string
---@field callback function

local M = {}

---@type agent_workbench.InstalledRecommendedKeymap[]
local installed = {}

local function new_session()
    require("agent-workbench").new_session()
end

local function continue_session()
    require("agent-workbench").continue_session()
end

local function resume_session()
    require("agent-workbench").resume_session()
end

local function send_mention()
    require("agent-workbench").send_mention()
end

local function diff_review()
    require("agent-workbench").diff_review()
end

local function attention()
    require("agent-workbench").attention()
end

local function workspaces()
    require("agent-workbench").workspaces()
end

local function new_workspace()
    require("agent-workbench").new_workspace()
end

local function workspace_sidebar()
    require("agent-workbench").workspace_sidebar()
end

local function previous_buffer()
    vim.cmd("bprevious")
end

local function next_buffer()
    vim.cmd("bnext")
end

local function next_workspace()
    vim.cmd("tabnext")
end

local function previous_workspace()
    vim.cmd("tabprevious")
end

---@type agent_workbench.RecommendedKeymap[]
local recommended = {
    {
        key = "a",
        prefixed = true,
        modes = { "n" },
        callback = new_session,
        desc = "Agent Workbench: create new session",
    },
    {
        key = "c",
        prefixed = true,
        modes = { "n" },
        callback = continue_session,
        desc = "Agent Workbench: continue latest session",
    },
    {
        key = "r",
        prefixed = true,
        modes = { "n" },
        callback = resume_session,
        desc = "Agent Workbench: resume session",
    },
    {
        key = "m",
        prefixed = true,
        modes = { "n", "x" },
        callback = send_mention,
        desc = "Agent Workbench: mention file or selection",
    },
    {
        key = "d",
        prefixed = true,
        modes = { "n" },
        callback = diff_review,
        desc = "Agent Workbench: review session diff",
    },
    {
        key = "t",
        prefixed = true,
        modes = { "n" },
        callback = attention,
        desc = "Agent Workbench: open attention request",
    },
    {
        key = "w",
        prefixed = true,
        modes = { "n" },
        callback = workspaces,
        desc = "Agent Workbench: pick workspace",
    },
    {
        key = "W",
        prefixed = true,
        modes = { "n" },
        callback = new_workspace,
        desc = "Agent Workbench: create workspace",
    },
    {
        key = "e",
        prefixed = true,
        modes = { "n" },
        callback = workspace_sidebar,
        desc = "Agent Workbench: toggle workspace explorer",
    },
    { key = "<M-h>", modes = { "n" }, callback = previous_buffer, desc = "Agent Workbench: previous buffer" },
    { key = "<M-l>", modes = { "n" }, callback = next_buffer, desc = "Agent Workbench: next buffer" },
    { key = "<M-j>", modes = { "n" }, callback = next_workspace, desc = "Agent Workbench: next workspace" },
    { key = "<M-k>", modes = { "n" }, callback = previous_workspace, desc = "Agent Workbench: previous workspace" },
}

---@param mode string
---@param effective_lhs string
---@return table?
local function find_global_map(mode, effective_lhs)
    for _, mapping in ipairs(vim.api.nvim_get_keymap(mode)) do
        if Keys.normalize_lhs(mapping.lhs) == effective_lhs then
            return mapping
        end
    end
    return nil
end

local function remove_installed()
    for _, mapping in ipairs(installed) do
        local current = find_global_map(mapping.mode, mapping.effective_lhs)
        if current and current.callback == mapping.callback then
            pcall(vim.keymap.del, mapping.mode, mapping.lhs)
        end
    end
    installed = {}
end

--- Apply or remove the configured recommended global keymap preset.
--- Existing global mappings are never replaced.
function M.setup()
    local config = require("agent-workbench.config").options.keymaps
    local preset = config.preset
    if preset ~= false and preset ~= "recommended" then
        error('Agent Workbench: keymaps.preset must be false or "recommended"', 2)
    end

    if preset == false then
        remove_installed()
        return
    end

    if type(config.prefix) ~= "string" or config.prefix == "" then
        error("Agent Workbench: keymaps.prefix must be a non-empty string", 2)
    end

    remove_installed()
    local skipped = {}
    for _, spec in ipairs(recommended) do
        local lhs = spec.prefixed and (config.prefix .. spec.key) or spec.key
        local effective_lhs = Keys.normalize_lhs(lhs)
        for _, mode in ipairs(spec.modes) do
            if find_global_map(mode, effective_lhs) then
                skipped[#skipped + 1] = string.format("%s (%s)", lhs, mode)
            else
                vim.keymap.set(mode, lhs, spec.callback, { desc = spec.desc, silent = true })
                local mapping = find_global_map(mode, effective_lhs)
                installed[#installed + 1] = {
                    mode = mode,
                    lhs = mapping and mapping.lhs or lhs,
                    effective_lhs = effective_lhs,
                    callback = spec.callback,
                }
            end
        end
    end

    if #skipped > 0 then
        Notify.warn("Skipped recommended keymaps already in use: " .. table.concat(skipped, ", "))
    end
end

--- Remove keymaps installed by this module without touching user replacements.
function M._reset()
    remove_installed()
end

return M
