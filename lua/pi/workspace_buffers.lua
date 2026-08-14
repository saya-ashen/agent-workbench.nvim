--- Tab-local buffer visibility for workspace-backed tabs.

local M = {}

local Config = require("pi.config")
local Notify = require("pi.notify")

---@type table<pi.TabId, table<integer, true>>
local buffers_by_tab = {}
---@type table<integer, table<pi.TabId, true>>
local tabs_by_buffer = {}
local switching = false
local updating_listed = false
local initialized = false

---@param buf integer
---@return boolean
local function is_valid(buf)
    return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted
end

---@param buf integer
---@return boolean
local function is_history(buf)
    return vim.api.nvim_buf_is_valid(buf) and vim.b[buf].pi_session_id ~= nil
end

---@param buf integer
---@return boolean
local function is_trackable(buf)
    return vim.api.nvim_buf_is_valid(buf) and (vim.bo[buf].buflisted or tabs_by_buffer[buf] ~= nil)
end

---@param tab pi.TabId
---@return table<integer, true>
local function tab_buffers(tab)
    local buffers = buffers_by_tab[tab]
    if not buffers then
        buffers = {}
        buffers_by_tab[tab] = buffers
    end
    return buffers
end

---@param buf integer
---@return table<pi.TabId, true>
local function buffer_tabs(buf)
    local tabs = tabs_by_buffer[buf]
    if not tabs then
        tabs = {}
        tabs_by_buffer[buf] = tabs
    end
    return tabs
end

---@param buf integer
---@param listed boolean
local function set_listed(buf, listed)
    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buflisted == listed then
        return
    end
    updating_listed = true
    local ok, err = pcall(function()
        vim.bo[buf].buflisted = listed
    end)
    updating_listed = false
    if not ok then
        error(err)
    end
end

---@param buf integer
---@param tab pi.TabId
function M.assign(buf, tab)
    if not initialized or not Config.options.workspace_buffers.enabled or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    tab_buffers(tab)[buf] = true
    buffer_tabs(buf)[tab] = true
    local current = vim.api.nvim_get_current_tabpage()
    set_listed(buf, tab_buffers(current)[buf] == true)
end

---@param buf integer
---@param tab pi.TabId
function M.unassign(buf, tab)
    local buffers = buffers_by_tab[tab]
    if buffers then
        buffers[buf] = nil
    end
    local tabs = tabs_by_buffer[buf]
    if tabs then
        tabs[tab] = nil
        if next(tabs) == nil then
            tabs_by_buffer[buf] = nil
        end
    end
end

---@param tab pi.TabId
local function capture_listed(tab)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if is_valid(buf) and tabs_by_buffer[buf] == nil then
            M.assign(buf, tab)
        end
    end
end

---@param tab pi.TabId
local function show_tab(tab)
    switching = true
    local visible = buffers_by_tab[tab] or {}
    local ok, err = pcall(function()
        for buf in pairs(tabs_by_buffer) do
            set_listed(buf, visible[buf] == true)
        end
    end)
    switching = false
    if not ok then
        error(err)
    end
    vim.cmd("redrawtabline")
end

---@param buf integer
local function forget_buffer(buf)
    local tabs = tabs_by_buffer[buf]
    if tabs then
        for tab in pairs(tabs) do
            local buffers = buffers_by_tab[tab]
            if buffers then
                buffers[buf] = nil
            end
        end
    end
    tabs_by_buffer[buf] = nil
end

---@param tab_index integer
---@return boolean
function M.move_current(tab_index)
    local target = vim.api.nvim_list_tabpages()[tab_index]
    if not target then
        Notify.error("Invalid workspace: " .. tostring(tab_index))
        return false
    end

    local buf = vim.api.nvim_get_current_buf()
    if is_history(buf) then
        Notify.warn("π History buffers stay in their session workspace")
        return false
    end
    if not is_trackable(buf) then
        Notify.warn("Current buffer is not a workspace buffer")
        return false
    end

    local current = vim.api.nvim_get_current_tabpage()
    if target == current then
        return true
    end

    local replacement
    for candidate in pairs(tab_buffers(current)) do
        if candidate ~= buf and is_valid(candidate) then
            replacement = candidate
            break
        end
    end
    if replacement then
        vim.api.nvim_set_current_buf(replacement)
    else
        vim.cmd("enew")
    end

    M.unassign(buf, current)
    M.assign(buf, target)
    return true
end

---@return boolean
function M.is_updating_listed()
    return updating_listed
end

---@param buf integer
---@param tab pi.TabId
---@return boolean
function M._contains(buf, tab)
    return buffers_by_tab[tab] ~= nil and buffers_by_tab[tab][buf] == true
end

---@param tab pi.TabId
---@return integer[]
function M.list(tab)
    local result = {}
    for buf in pairs(buffers_by_tab[tab] or {}) do
        if vim.api.nvim_buf_is_valid(buf) then
            result[#result + 1] = buf
        end
    end
    table.sort(result, function(a, b)
        return a < b
    end)
    return result
end

---@return string[]
function M.complete_workspaces()
    local result = {} ---@type string[]
    for index in ipairs(vim.api.nvim_list_tabpages()) do
        result[#result + 1] = tostring(index)
    end
    return result
end

function M.setup()
    if initialized or not Config.options.workspace_buffers.enabled then
        return
    end
    initialized = true

    local current = vim.api.nvim_get_current_tabpage()
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            local buf = vim.api.nvim_win_get_buf(win)
            if is_valid(buf) then
                tab_buffers(tab)[buf] = true
                buffer_tabs(buf)[tab] = true
            end
        end
    end
    capture_listed(current)
    show_tab(current)

    local group = vim.api.nvim_create_augroup("PiWorkspaceBuffers", { clear = true })
    vim.api.nvim_create_autocmd("TabLeave", {
        group = group,
        callback = function()
            switching = true
            capture_listed(vim.api.nvim_get_current_tabpage())
        end,
    })
    vim.api.nvim_create_autocmd("TabEnter", {
        group = group,
        callback = function()
            show_tab(vim.api.nvim_get_current_tabpage())
        end,
    })
    vim.api.nvim_create_autocmd("TabNewEntered", {
        group = group,
        callback = function()
            local tab = vim.api.nvim_get_current_tabpage()
            local buf = vim.api.nvim_get_current_buf()
            if not is_history(buf) and is_trackable(buf) then
                M.assign(buf, tab)
            end
            show_tab(tab)
        end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        callback = function(args)
            if switching or is_history(args.buf) or not is_trackable(args.buf) then
                return
            end
            M.assign(args.buf, vim.api.nvim_get_current_tabpage())
            vim.cmd("redrawtabline")
        end,
    })
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = group,
        callback = function(args)
            if not updating_listed then
                forget_buffer(args.buf)
            end
        end,
    })
    vim.api.nvim_create_autocmd("TabClosed", {
        group = group,
        callback = function()
            for tab, buffers in pairs(buffers_by_tab) do
                if not vim.api.nvim_tabpage_is_valid(tab) then
                    for buf in pairs(buffers) do
                        M.unassign(buf, tab)
                    end
                    buffers_by_tab[tab] = nil
                end
            end
        end,
    })
end

function M._reset()
    pcall(vim.api.nvim_del_augroup_by_name, "PiWorkspaceBuffers")
    for buf in pairs(tabs_by_buffer) do
        set_listed(buf, true)
    end
    buffers_by_tab = {}
    tabs_by_buffer = {}
    switching = false
    updating_listed = false
    initialized = false
end

return M
