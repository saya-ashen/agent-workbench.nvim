local M = {}

---@return boolean
function M.is_windows()
    return vim.fn.has("win32") == 1
end

return M
