--- Tab-backed workspace bar and picker.

local M = {}

local Config = require("pi.config")
local Workspace = require("pi.workspace")

---@class pi.WorkspaceRow
---@field tab pi.TabId
---@field index integer
---@field cwd string
---@field name string
---@field sessions integer
---@field status "attention"|"busy"|"idle"

local BUILTIN_TABLINE = "%!v:lua.require'pi.ui.workspaces'.tabline()"
local owns_tabline = false
local bufferline_active = false
local bufferline_options
local bufferline_custom_areas
local bufferline_right_area
local bufferline_show_tab_indicators
local setup_generation = 0

---@param text string
---@return string
local function escape_tabline(text)
    local escaped = text:gsub("%%", "%%%%")
    return escaped
end

---@return boolean
local function uses_bufferline()
    return vim.o.tabline:lower():find("bufferline", 1, true) ~= nil or type(rawget(_G, "nvim_bufferline")) == "function"
end

---@param row pi.WorkspaceRow
---@return string
local function workspace_label(row)
    local options = Config.options.workspace_bar
    local label = row.name
    if options.label == "path" then
        label = row.cwd
    elseif type(options.label) == "function" then
        local ok, custom = pcall(options.label, row)
        if ok and type(custom) == "string" and custom ~= "" then
            label = custom
        end
    end
    local index = options.show_index and (row.index .. " ") or ""
    local count = options.session_count and (" " .. row.sessions) or ""
    local status = options.status and (row.status == "attention" and " !" or (row.status == "busy" and " ●" or ""))
        or ""
    return ("%s%s%s%s"):format(index, label, count, status)
end

---@return table[]
local function bufferline_workspace_area()
    local items = {} ---@type table[]
    if bufferline_right_area then
        local ok, existing = pcall(bufferline_right_area)
        if ok and type(existing) == "table" then
            vim.list_extend(items, existing)
        end
    end
    local current = vim.api.nvim_get_current_tabpage()
    for _, row in ipairs(M.list()) do
        local link = row.tab == current and "BufferLineTabSelected" or "BufferLineTab"
        items[#items + 1] = {
            text = ("%%%dT %s %%T"):format(row.index, escape_tabline(workspace_label(row))),
            link = link,
        }
    end
    return items
end

---@return boolean changed
local function enable_bufferline_workspace_area()
    local ok, bufferline = pcall(require, "bufferline.config")
    if not ok or type(bufferline.options) ~= "table" then
        return false
    end
    if bufferline_options ~= bufferline.options then
        bufferline_options = bufferline.options
        bufferline_custom_areas = bufferline.options.custom_areas
        bufferline_right_area = bufferline_custom_areas and bufferline_custom_areas.right or nil
        bufferline_show_tab_indicators = bufferline.options.show_tab_indicators
    end
    if
        bufferline.options.show_tab_indicators == false
        and bufferline.options.custom_areas
        and bufferline.options.custom_areas.right == bufferline_workspace_area
    then
        return false
    end
    bufferline.options.show_tab_indicators = false
    local areas = vim.tbl_extend("force", {}, bufferline_custom_areas or {})
    areas.right = bufferline_workspace_area
    bufferline.options.custom_areas = areas
    return true
end

---@param generation integer
---@param remaining integer
local function retry_bufferline_setup(generation, remaining)
    if generation ~= setup_generation or remaining == 0 then
        return
    end
    vim.defer_fn(function()
        if generation ~= setup_generation then
            return
        end
        if Config.options.workspace_bar.enabled and uses_bufferline() then
            bufferline_active = true
            local changed = enable_bufferline_workspace_area()
            if changed and type(rawget(_G, "nvim_bufferline")) == "function" then
                vim.cmd("redrawtabline")
            end
        end
        retry_bufferline_setup(generation, remaining - 1)
    end, 100)
end

---@return pi.WorkspaceRow[]
function M.list()
    local sessions = require("pi.sessions.manager").list()
    local tabs = vim.api.nvim_list_tabpages()
    local cwd_counts = {} ---@type table<string, integer>
    local base_counts = {} ---@type table<string, integer>

    for _, tab in ipairs(tabs) do
        local cwd = Workspace.cwd(tab)
        local base = Workspace.label(tab)
        cwd_counts[cwd] = (cwd_counts[cwd] or 0) + 1
        base_counts[base] = (base_counts[base] or 0) + 1
    end

    ---@type pi.WorkspaceRow[]
    local rows = {}
    for index, tab in ipairs(tabs) do
        local cwd = Workspace.cwd(tab)
        local base = Workspace.label(tab)
        local name = base
        if base_counts[base] > 1 then
            local parent = vim.fs.basename(vim.fs.dirname(cwd))
            name = parent ~= "" and (parent .. "/" .. base) or cwd
        end
        if cwd_counts[cwd] > 1 then
            name = name .. " #" .. index
        end

        local count = 0
        local busy = false
        local attention = false
        for _, session in ipairs(sessions) do
            if session.workspace_tab == tab or session.workspace_tab == nil and session.cwd == cwd then
                count = count + 1
                busy = busy or session.chat:is_streaming() or session.chat:is_compacting()
                attention = attention or require("pi.attention").count_for_session(session) > 0
            end
        end

        rows[#rows + 1] = {
            tab = tab,
            index = index,
            cwd = cwd,
            name = name,
            sessions = count,
            status = attention and "attention" or (busy and "busy" or "idle"),
        }
    end
    return rows
end

---@return string
function M.tabline()
    local current = vim.api.nvim_get_current_tabpage()
    local parts = {} ---@type string[]
    for _, row in ipairs(M.list()) do
        local hl = row.tab == current and "%#TabLineSel#" or "%#TabLine#"
        parts[#parts + 1] = ("%s%%%dT %s %%T"):format(hl, row.index, escape_tabline(workspace_label(row)))
    end
    parts[#parts + 1] = "%#TabLineFill#%T"
    return table.concat(parts)
end

function M.select()
    local rows = M.list()
    vim.ui.select(rows, {
        prompt = "Select workspace",
        kind = "pi-workspace",
        format_item = function(row)
            return ("%d  %-20s  %d session%s  %s"):format(
                row.index,
                row.name,
                row.sessions,
                row.sessions == 1 and "" or "s",
                row.cwd
            )
        end,
    }, function(row)
        if row and vim.api.nvim_tabpage_is_valid(row.tab) then
            vim.api.nvim_set_current_tabpage(row.tab)
        end
    end)
end

function M.create()
    vim.ui.input({
        prompt = "Workspace path: ",
        default = Workspace.cwd(vim.api.nvim_get_current_tabpage()),
        completion = "dir",
    }, function(input)
        if input == nil or vim.trim(input) == "" then
            return
        end
        local path = vim.uv.fs_realpath(vim.fn.fnamemodify(vim.fn.expand(vim.trim(input)), ":p"))
        if not path or vim.fn.isdirectory(path) ~= 1 then
            require("pi.notify").error("Workspace path is not a directory: " .. input)
            return
        end
        vim.cmd.tabnew()
        vim.cmd.tcd(vim.fn.fnameescape(path))
        M.refresh()
    end)
end

function M.refresh()
    if not Config.options.workspace_bar.enabled then
        return
    end
    if owns_tabline and vim.o.tabline ~= BUILTIN_TABLINE then
        owns_tabline = false
    end
    if not owns_tabline and uses_bufferline() then
        bufferline_active = true
        enable_bufferline_workspace_area()
    end
    if owns_tabline then
        local show = Config.options.workspace_bar.show
        local visible = show == "always" or #vim.api.nvim_list_tabpages() > 1
        vim.o.showtabline = visible and 2 or 1
    end
    if owns_tabline or bufferline_active and type(rawget(_G, "nvim_bufferline")) == "function" then
        vim.cmd("redrawtabline")
    end
end

function M.setup()
    Workspace.ensure_current()
    local group = vim.api.nvim_create_augroup("PiWorkspaces", { clear = true })
    vim.api.nvim_create_autocmd("TabNew", {
        group = group,
        callback = function()
            Workspace.ensure_current()
            M.refresh()
        end,
    })

    local options = Config.options.workspace_bar
    if options.enabled and vim.o.tabline == "" then
        owns_tabline = true
        vim.o.tabline = BUILTIN_TABLINE
        vim.o.showtabline = options.show == "always" and 2 or 1
    elseif options.enabled and uses_bufferline() then
        bufferline_active = true
        enable_bufferline_workspace_area()
    end

    vim.api.nvim_create_autocmd({ "BufEnter", "TabEnter", "TabClosed", "DirChanged" }, {
        group = group,
        callback = M.refresh,
    })
    vim.api.nvim_create_autocmd("VimEnter", {
        group = group,
        callback = function()
            vim.schedule(M.refresh)
        end,
    })
    vim.api.nvim_create_autocmd("OptionSet", {
        group = group,
        pattern = "tabline",
        callback = M.refresh,
    })
    M.refresh()
    setup_generation = setup_generation + 1
    retry_bufferline_setup(setup_generation, 30)
end

function M._reset()
    setup_generation = setup_generation + 1
    if owns_tabline and vim.o.tabline == BUILTIN_TABLINE then
        vim.o.tabline = ""
    end
    if bufferline_options then
        bufferline_options.custom_areas = bufferline_custom_areas
        bufferline_options.show_tab_indicators = bufferline_show_tab_indicators
    end
    owns_tabline = false
    bufferline_active = false
    bufferline_options = nil
    bufferline_custom_areas = nil
    bufferline_right_area = nil
    bufferline_show_tab_indicators = nil
end

return M
