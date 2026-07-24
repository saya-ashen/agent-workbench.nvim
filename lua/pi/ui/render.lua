--- Optional markdown rendering for the chat history via render-markdown.nvim.
--
-- pi.nvim's built-in rendering ("builtin") draws agent prose with treesitter
-- markdown highlights plus custom extmarks for tables, labels and tool blocks.
-- When `opts.render.engine = "render-markdown"`, pi additionally lets
-- render-markdown.nvim render the history buffer (headings, lists, code-block
-- chrome, links, ...) for a richer presentation.
--
-- render-markdown is an OPTIONAL dependency: pi never hard-requires it. If the
-- engine is requested but the plugin is missing, pi warns once and falls back
-- to builtin rendering. The user's own render-markdown configuration is left
-- untouched — pi only appends its history filetype to the active file_types.

local M = {}

local Config = require("pi.config")
local Ft = require("pi.filetypes")

local warned_missing = false

---@return string engine "builtin"|"render-markdown"
function M.engine()
    local render = Config.options.render
    return (render and render.engine) or "builtin"
end

--- Make render-markdown available and responsible for the history filetype,
--- without clobbering any configuration the user already applied.
---@return boolean ok whether render-markdown is usable
local function ensure_render_markdown()
    -- If a plugin manager (lazy.nvim) owns render-markdown but hasn't loaded it
    -- yet (e.g. gated on ft), force-load it so its module and plugin/ exist.
    if package.loaded["render-markdown"] == nil then
        local ok_lazy, lazy = pcall(require, "lazy")
        if ok_lazy then
            pcall(lazy.load, { plugins = { "render-markdown.nvim" } })
        end
    end

    local ok, rm = pcall(require, "render-markdown")
    if not ok then
        if not warned_missing then
            warned_missing = true
            vim.notify(
                "pi.nvim: render.engine = 'render-markdown' but render-markdown.nvim is not installed; "
                    .. "falling back to builtin rendering.",
                vim.log.levels.WARN,
                { title = "π" }
            )
        end
        return false
    end

    -- Register pi's history filetype. If render-markdown is already set up we
    -- extend its live file_types list (preserving the user's config); otherwise
    -- run a minimal setup so the filetype is handled.
    local state = require("render-markdown.state")
    if type(state.file_types) == "table" then
        if not vim.tbl_contains(state.file_types, Ft.history) then
            table.insert(state.file_types, Ft.history)
        end
    else
        rm.setup({ file_types = { "markdown", Ft.history } })
    end
    return true
end

--- Attach the configured render engine to a freshly created history buffer.
--- No-op for the builtin engine.
---@param buf integer
function M.attach_history(buf)
    if M.engine() ~= "render-markdown" then
        return
    end
    if not ensure_render_markdown() then
        return
    end

    -- render-markdown auto-attaches via its FileType autocmd once the history
    -- filetype is registered above. Attach explicitly as well (idempotent) so
    -- buffers that predate registration are covered. pcall'd because this is an
    -- internal API that may move between versions; the FileType autocmd remains
    -- the primary, version-stable attach path.
    --
    -- From here render-markdown drives rendering itself through its standard
    -- TextChanged/CursorMoved hooks (the same mechanism codecompanion.nvim
    -- relies on for streamed chat buffers): pi's writes toggle 'modifiable' and
    -- fire TextChanged, which render-markdown re-renders in response to.
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

--- Reset module state (used by tests).
function M._reset()
    warned_missing = false
end

return M
