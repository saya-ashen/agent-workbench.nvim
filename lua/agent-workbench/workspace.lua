--- Stable virtual resources for persisted Pi sessions.

local M = {}

---@type table<string, integer>
local buffers = {}

---@return string
function M.ensure_current()
    local tabnr = vim.api.nvim_tabpage_get_number(0)
    local cwd = vim.fn.getcwd(-1, tabnr)
    if vim.fn.haslocaldir(-1, tabnr) == 0 then
        vim.cmd("tcd " .. vim.fn.fnameescape(cwd))
    end
    return cwd
end

---@param tab? agent_workbench.TabId
---@return string
function M.cwd(tab)
    tab = tab or vim.api.nvim_get_current_tabpage()
    return vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tab))
end

---@param tab? agent_workbench.TabId
---@return string
function M.label(tab)
    local cwd = M.cwd(tab)
    local name = vim.fs.basename(cwd)
    return name ~= "" and name or cwd
end

---@param cwd string
---@return string
function M.project_key(cwd)
    local normalized = vim.fs.normalize(cwd)
    local name = vim.fs.basename(normalized)
    return ((name ~= "" and name or "root"):gsub("[^%w._-]", "-"))
end

---@param session_file string?
---@param fallback string|integer
---@return string
local function session_key(session_file, fallback)
    if type(session_file) == "string" and session_file ~= "" then
        return vim.fs.basename(session_file):gsub("%.jsonl$", "")
    end
    return "new-" .. tostring(fallback)
end

---@param cwd string
---@param session_file string?
---@param fallback string|integer
---@return string
function M.uri(cwd, session_file, fallback)
    return ("agent://%s/%s/transcript"):format(M.project_key(cwd), session_key(session_file, fallback))
end

---@param uri string
---@return string?, string?, string?
function M.parse(uri)
    local project, session, resource = uri:match("^agent://([^/]+)/([^/]+)/([^/]+)$")
    if project and session and resource then
        return project, session, resource
    end

    -- Accept phase-one names: agent://project/session-id.
    project, session = uri:match("^agent://([^/]+)/(.+)$")
    if project and session and session ~= "" then
        return project, session, "transcript"
    end
    return nil, nil, nil
end

---@param uri string
---@param buf integer
function M.register(uri, buf)
    buffers[uri] = buf
end

---@param uri string
---@return integer?
function M.buffer(uri)
    local buf = buffers[uri]
    if buf and vim.api.nvim_buf_is_valid(buf) then
        return buf
    end
    buffers[uri] = nil
    return nil
end

---@param uri string
---@param buf integer
function M.unregister(uri, buf)
    if buffers[uri] == buf then
        buffers[uri] = nil
    end
end

function M.reset()
    buffers = {}
end

return M
