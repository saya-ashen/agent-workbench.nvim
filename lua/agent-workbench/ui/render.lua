--- Markdown rendering adapter for Pi chat history.

local M = {}

local Config = require("agent-workbench.config")
local Ft = require("agent-workbench.filetypes")

local warned_missing = {}
local markview_scheduled = {}
local markview_paused = {}
local markview_dirty = {}
local markview_rendered_tick = {}
local markview_cursor_generation = {}

local MARKVIEW_CURSOR_DEBOUNCE_MS = 30

---@return string engine "builtin"|"markview"|"render-markdown"
function M.engine()
    local render = Config.options.render
    return (render and render.engine) or "builtin"
end

---@param engine string
local function warn_missing(engine)
    if warned_missing[engine] then
        return
    end
    warned_missing[engine] = true
    vim.notify(
        ("Agent Workbench: render.engine = '%s' but renderer is not installed; falling back to builtin rendering."):format(
            engine
        ),
        vim.log.levels.WARN
    )
end

---@param plugin string
local function lazy_load(plugin)
    local ok, lazy = pcall(require, "lazy")
    if ok then
        pcall(lazy.load, { plugins = { plugin } })
    end
end

---@return table?
local function ensure_markview()
    if package.loaded.markview == nil then
        lazy_load("markview.nvim")
    end
    local ok, markview = pcall(require, "markview")
    if not ok then
        warn_missing("markview")
        return nil
    end
    return markview
end

---@return boolean
local function ensure_render_markdown()
    if package.loaded["render-markdown"] == nil then
        lazy_load("render-markdown.nvim")
    end
    local ok, renderer = pcall(require, "render-markdown")
    if not ok then
        warn_missing("render-markdown")
        return false
    end

    local state = require("render-markdown.state")
    if type(state.file_types) == "table" then
        if not vim.tbl_contains(state.file_types, Ft.history) then
            table.insert(state.file_types, Ft.history)
        end
    else
        renderer.setup({ file_types = { "markdown", Ft.history } })
    end
    return true
end

---@param buf integer
---@return boolean
local function is_visible(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    local current_tab = vim.api.nvim_get_current_tabpage()
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.api.nvim_win_get_tabpage(win) == current_tab then
            return true
        end
    end
    return false
end

---@return table?
local function markview_render_config()
    local overrides = Config.options.render and Config.options.render.markview
    if type(overrides) ~= "table" or next(overrides) == nil then
        return nil
    end
    local ok, spec = pcall(require, "markview.spec")
    if not ok or type(spec.config) ~= "table" then
        return vim.deepcopy(overrides)
    end
    return vim.tbl_deep_extend("force", vim.deepcopy(spec.config), overrides)
end

---@param buf integer
---@param win integer
function M.configure_history_window(buf, win)
    if
        M.engine() ~= "markview"
        or not vim.api.nvim_buf_is_valid(buf)
        or not vim.api.nvim_win_is_valid(win)
        or not ensure_markview()
    then
        return
    end
    vim.w[win].agent_workbench_managed = true
    local render_config = markview_render_config()
    local ok, spec = pcall(require, "markview.spec")
    if not ok or type(spec.get) ~= "function" then
        return
    end
    local temporary = render_config and type(spec.tmp_setup) == "function" and type(spec.tmp_reset) == "function"
    if temporary then
        spec.tmp_setup(render_config)
    end
    pcall(function()
        local callbacks = spec.get({ "preview", "callbacks" }, { fallback = {}, ignore_enable = true })
        if type(callbacks) ~= "table" then
            return
        end
        local enabled = spec.get({ "preview", "enable" }, { fallback = true, ignore_enable = true }) ~= false
        local hybrid = spec.get({ "preview", "enable_hybrid_mode" }, { fallback = true, ignore_enable = true })
        local windows = { win }
        local callback = enabled and callbacks.on_enable or callbacks.on_disable
        if type(callback) == "function" then
            callback(buf, windows)
        end
        callback = hybrid == false and callbacks.on_hybrid_disable or callbacks.on_hybrid_enable
        if enabled and type(callback) == "function" then
            callback(buf, windows)
        end
    end)
    if temporary then
        spec.tmp_reset()
    end
end

---@param buf integer
local function render_markview_now(buf)
    if markview_paused[buf] or not markview_dirty[buf] or not is_visible(buf) then
        return
    end
    local markview = ensure_markview()
    if not markview or type(markview.render) ~= "function" then
        return
    end
    local clear_ok = true
    if type(markview.clear) == "function" then
        clear_ok = pcall(markview.clear, buf)
    end
    local render_config = markview_render_config()
    local render_ok
    if render_config then
        render_ok = pcall(markview.render, buf, nil, render_config)
    else
        render_ok = pcall(markview.render, buf)
    end
    local ok = clear_ok and render_ok
    vim.b[buf].pi_markview = ok
    if ok then
        markview_rendered_tick[buf] = vim.b[buf].changedtick
        markview_dirty[buf] = nil
    end
end

---@param buf integer
local function render_markview(buf)
    if markview_paused[buf] or markview_scheduled[buf] or not markview_dirty[buf] or not is_visible(buf) then
        return
    end
    markview_scheduled[buf] = true
    vim.schedule(function()
        markview_scheduled[buf] = nil
        render_markview_now(buf)
    end)
end

---@param buf integer
---@param force? boolean
local function refresh_markview(buf, force)
    if force or vim.api.nvim_buf_is_valid(buf) and markview_rendered_tick[buf] ~= vim.b[buf].changedtick then
        markview_dirty[buf] = true
    end
    render_markview(buf)
end

---@param buf integer
local function refresh_markview_cursor(buf)
    local generation = (markview_cursor_generation[buf] or 0) + 1
    markview_cursor_generation[buf] = generation
    vim.defer_fn(function()
        if markview_cursor_generation[buf] ~= generation or not is_visible(buf) then
            return
        end
        refresh_markview(buf, true)
    end, MARKVIEW_CURSOR_DEBOUNCE_MS)
end

---@param buf integer
function M.refresh_history(buf)
    if M.engine() == "markview" then
        refresh_markview(buf)
    end
end

---@param buf integer
function M.attach_history(buf)
    local engine = M.engine()
    if engine == "markview" then
        if not ensure_markview() then
            return
        end
        markview_dirty[buf] = true
        vim.api.nvim_create_autocmd("TextChanged", {
            buffer = buf,
            callback = function()
                refresh_markview(buf)
            end,
        })
        vim.api.nvim_create_autocmd("BufWinEnter", {
            buffer = buf,
            callback = function()
                render_markview(buf)
            end,
        })
        vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
            buffer = buf,
            callback = function()
                refresh_markview_cursor(buf)
            end,
        })
        render_markview(buf)
        return
    end
    if engine ~= "render-markdown" or not ensure_render_markdown() then
        return
    end

    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local ok, manager = pcall(require, "render-markdown.core.manager")
        if ok then
            pcall(manager.attach, buf)
        end
    end)
end

---@return any?
local function render_markdown_manager()
    local ok, manager = pcall(require, "render-markdown.core.manager")
    return ok and manager or nil
end

---@param buf integer
function M.pause_history(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    if M.engine() == "markview" then
        markview_paused[buf] = true
        markview_dirty[buf] = true
        local markview = ensure_markview()
        if markview and type(markview.clear) == "function" then
            pcall(markview.clear, buf)
        end
        return
    end
    if M.engine() == "render-markdown" then
        local manager = render_markdown_manager()
        if manager then
            pcall(manager.set_buf, buf, false)
        end
    end
end

---@param buf integer
function M.resume_history(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    if M.engine() == "markview" then
        markview_paused[buf] = nil
        markview_dirty[buf] = true
        vim.defer_fn(function()
            render_markview(buf)
        end, 1)
        return
    end
    if M.engine() == "render-markdown" then
        vim.defer_fn(function()
            if not vim.api.nvim_buf_is_valid(buf) then
                return
            end
            local manager = render_markdown_manager()
            if manager then
                pcall(manager.set_buf, buf, true)
            end
        end, 1)
    end
end

function M._reset()
    warned_missing = {}
    markview_scheduled = {}
    markview_paused = {}
    markview_dirty = {}
    markview_rendered_tick = {}
    markview_cursor_generation = {}
end

return M
