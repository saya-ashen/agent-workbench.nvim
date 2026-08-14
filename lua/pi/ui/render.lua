--- Markdown rendering adapter for Pi chat history.

local M = {}

local Config = require("pi.config")
local Ft = require("pi.filetypes")

local warned_missing = {}
local markview_scheduled = {}
local markview_paused = {}
local markview_dirty = {}
local markview_rendered_tick = {}

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
        ("pi.nvim: render.engine = '%s' but renderer is not installed; falling back to builtin rendering."):format(
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
    return vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0
end

---@param buf integer
local function render_markview(buf)
    if
        markview_paused[buf]
        or markview_scheduled[buf]
        or not markview_dirty[buf]
        or not is_visible(buf)
    then
        return
    end
    markview_scheduled[buf] = true
    vim.schedule(function()
        markview_scheduled[buf] = nil
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
        local render_ok = pcall(markview.render, buf)
        local ok = clear_ok and render_ok
        vim.b[buf].pi_markview = ok
        if ok then
            markview_rendered_tick[buf] = vim.b[buf].changedtick
            markview_dirty[buf] = nil
        end
    end)
end

---@param buf integer
local function refresh_markview(buf)
    if
        vim.api.nvim_buf_is_valid(buf)
        and markview_rendered_tick[buf] ~= vim.b[buf].changedtick
    then
        markview_dirty[buf] = true
    end
    render_markview(buf)
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
        render_markview(buf)
        return
    end
    if M.engine() == "render-markdown" then
        vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(buf) then
                return
            end
            local manager = render_markdown_manager()
            if manager then
                pcall(manager.set_buf, buf, true)
            end
        end)
    end
end

function M._reset()
    warned_missing = {}
    markview_scheduled = {}
    markview_paused = {}
    markview_dirty = {}
    markview_rendered_tick = {}
end

return M
