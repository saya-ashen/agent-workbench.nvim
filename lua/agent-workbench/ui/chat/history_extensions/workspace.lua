--- Workspace identity policy for chat history buffers.

local M = {}

---@param history agent_workbench.ChatHistory
---@param name string
function M.attach(history, name)
    local Workspace = require("agent-workbench.workspace")
    Workspace.register(name, history._buf)
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = history._buf,
        once = true,
        callback = function()
            Workspace.unregister(history._name, history._buf)
        end,
    })
end

---@param history agent_workbench.ChatHistory
---@param name string
---@return boolean renamed
function M.rename(history, name)
    if not vim.api.nvim_buf_is_valid(history._buf) then
        return false
    end
    local old_name = history._name
    if old_name == name then
        return true
    end
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 and existing ~= history._buf then
        return false
    end
    history._name = name
    local Workspace = require("agent-workbench.workspace")
    Workspace.unregister(old_name, history._buf)
    Workspace.register(name, history._buf)
    return true
end

return M
