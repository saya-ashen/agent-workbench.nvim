--- Message-level Markdown rendering service for chat History buffers.

local M = {}

local Compiler = require("agent-workbench.ui.markdown.compiler")
local Config = require("agent-workbench.config")
local Notify = require("agent-workbench.notify")

local ns = vim.api.nvim_create_namespace("agent-workbench/markdown")
local warned = {}
local states = {}
local resize_autocmd ---@type integer?

---@class agent_workbench.MarkdownBlock
---@field id integer
---@field buffer integer
---@field role "user"|"assistant"
---@field anchor integer
---@field source_chunks string[]
---@field col_prefix integer
---@field decoration_ids integer[]
---@field generation integer
---@field complete boolean
---@field dirty boolean
---@field width_dependent boolean
---@field line_count integer
---@field _timer? uv.uv_timer_t

---@class agent_workbench.MarkdownRenderState
---@field buffer integer
---@field blocks agent_workbench.MarkdownBlock[]
---@field next_id integer
---@field paused boolean
---@field width integer
---@field available? boolean

---@param key string
---@param message string
---@param level "warn"|"error"
local function notify_once(key, message, level)
    if warned[key] then
        return
    end
    warned[key] = true
    Notify[level](message)
end

---@param plugin string
local function lazy_load(plugin)
    local ok, lazy = pcall(require, "lazy")
    if ok then
        pcall(lazy.load, { plugins = { plugin } })
    end
end

---@return agent_workbench.MarkdownConfig?
local function markdown_config()
    local render = Config.options.render
    return render and render.markdown or nil
end

---@return boolean
local function config_enabled()
    local render = Config.options.render or {}
    local engine = render.engine
    if engine == "markview" then
        notify_once(
            "legacy-engine-markview",
            "render.engine = 'markview' is deprecated; remove render.engine and configure render.markdown instead",
            "warn"
        )
    elseif engine == "builtin" or engine == "render-markdown" then
        notify_once(
            "unsupported-engine-" .. engine,
            ("render.engine = '%s' is no longer supported; Markdown decorations are disabled and raw text is preserved"):format(
                engine
            ),
            "error"
        )
        return false
    elseif engine ~= nil then
        notify_once(
            "unsupported-engine-other",
            ("render.engine = '%s' is not supported; Markdown decorations are disabled and raw text is preserved"):format(
                tostring(engine)
            ),
            "error"
        )
        return false
    end
    if type(render.markview) == "table" and next(render.markview) ~= nil then
        notify_once(
            "legacy-markview-config",
            "render.markview is ignored; migrate History rendering options to render.markdown",
            "warn"
        )
    end
    local markdown = render.markdown
    return type(markdown) ~= "table" or markdown.enabled ~= false
end

---@return string engine "markdown"|"raw"
function M.engine()
    return config_enabled() and "markdown" or "raw"
end

---@param state agent_workbench.MarkdownRenderState
---@return boolean
local function ensure_available(state)
    if state.available ~= nil then
        return state.available
    end
    if not config_enabled() then
        state.available = false
        return false
    end
    if package.loaded["markview.parser"] == nil then
        lazy_load("markview.nvim")
    end
    local ok, parser = pcall(require, "markview.parser")
    if not ok or type(parser.init) ~= "function" then
        state.available = false
        notify_once(
            "missing-markview-parser",
            "Markview parser is unavailable; install a compatible markview.nvim. History will show raw Markdown",
            "error"
        )
        return false
    end
    local tree_ok = pcall(vim.treesitter.get_string_parser, "", "markdown")
    if not tree_ok then
        state.available = false
        notify_once(
            "missing-markdown-parser",
            "Markdown Tree-sitter parser is unavailable. History will show raw Markdown",
            "error"
        )
        return false
    end
    state.available = true
    return true
end

---@param buf integer
---@return agent_workbench.MarkdownRenderState
local function state_for(buf)
    local state = states[buf]
    if state then
        return state
    end
    state = {
        buffer = buf,
        blocks = {},
        next_id = 0,
        paused = false,
        width = 80,
        available = nil,
    }
    states[buf] = state
    return state
end

---@param block agent_workbench.MarkdownBlock
local function stop_timer(block)
    if not block._timer then
        return
    end
    block._timer:stop()
    block._timer:close()
    block._timer = nil
end

---@param block agent_workbench.MarkdownBlock
local function clear_decorations(block)
    if not vim.api.nvim_buf_is_valid(block.buffer) then
        block.decoration_ids = {}
        return
    end
    for _, id in ipairs(block.decoration_ids) do
        pcall(vim.api.nvim_buf_del_extmark, block.buffer, ns, id)
    end
    block.decoration_ids = {}
end

---@param block agent_workbench.MarkdownBlock
---@param decoration agent_workbench.MarkdownDecoration
---@param anchor_row integer
---@return integer?
---@return string?
local function apply_decoration(block, decoration, anchor_row)
    local target_row = anchor_row + decoration.row
    local target_col = decoration.col + block.col_prefix
    local opts = {
        strict = false,
        undo_restore = false,
        invalidate = true,
    }
    if decoration.end_col ~= nil then
        local relative_end_row = decoration.end_row or decoration.row
        -- Every nonempty user body line has the same textual prefix. Add it to
        -- a nonzero end column; an exclusive end at column 0 must remain before
        -- the next line's prefix (for example a heading ending at {next, 0}).
        opts.end_row = anchor_row + relative_end_row
        opts.end_col = decoration.end_col
            + ((relative_end_row == decoration.row or decoration.end_col > 0) and block.col_prefix or 0)
    elseif decoration.end_row ~= nil then
        opts.end_row = anchor_row + decoration.end_row
    end
    for _, key in ipairs({
        "hl_group",
        "conceal",
        "virt_text",
        "virt_text_pos",
        "virt_lines_above",
        "line_hl_group",
        "priority",
    }) do
        if decoration[key] ~= nil then
            opts[key] = decoration[key]
        end
    end
    if decoration.virt_lines ~= nil then
        opts.virt_lines = vim.deepcopy(decoration.virt_lines)
        if block.col_prefix > 0 then
            for _, line in ipairs(opts.virt_lines) do
                table.insert(line, 1, { string.rep(" ", block.col_prefix) })
            end
        end
    end
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, block.buffer, ns, target_row, target_col, opts)
    if not ok then
        return nil, tostring(id)
    end
    return id, nil
end

---@param block agent_workbench.MarkdownBlock
local function render_block(block)
    local state = states[block.buffer]
    if not state or state.paused or not block.dirty or not vim.api.nvim_buf_is_valid(block.buffer) then
        return
    end
    if not ensure_available(state) then
        clear_decorations(block)
        block.dirty = false
        return
    end
    local source = table.concat(block.source_chunks)
    local config = markdown_config() or {}
    local plan, err = Compiler.compile(source, {
        width = state.width,
        features = config.features or {},
        symbols = config.symbols or {},
    })
    if not plan then
        clear_decorations(block)
        block.dirty = false
        notify_once("compile-error-" .. tostring(err), tostring(err) .. ". History will show raw Markdown", "error")
        return
    end
    local anchor = vim.api.nvim_buf_get_extmark_by_id(block.buffer, ns, block.anchor, {})
    if not anchor[1] then
        clear_decorations(block)
        block.dirty = false
        return
    end
    clear_decorations(block)
    for _, decoration in ipairs(plan.decorations) do
        local id, apply_error = apply_decoration(block, decoration, anchor[1])
        if apply_error then
            clear_decorations(block)
            block.dirty = false
            notify_once(
                "decoration-error-" .. apply_error,
                "Markdown decoration failed: " .. apply_error .. ". History will show raw Markdown",
                "error"
            )
            return
        end
        block.decoration_ids[#block.decoration_ids + 1] = id --[[@as integer]]
    end
    block.width_dependent = plan.width_dependent
    block.dirty = false
end

---@param block agent_workbench.MarkdownBlock
local function schedule_block(block)
    local state = states[block.buffer]
    if not state or state.paused or not ensure_available(state) then
        return
    end
    stop_timer(block)
    local config = markdown_config() or {}
    local delay = math.max(0, tonumber(config.debounce_ms) or 30)
    local generation = block.generation
    if delay == 0 then
        render_block(block)
        return
    end
    local timer = assert(vim.uv.new_timer())
    block._timer = timer
    timer:start(
        delay,
        0,
        vim.schedule_wrap(function()
            if block._timer ~= timer then
                return
            end
            block._timer = nil
            timer:stop()
            timer:close()
            if block.generation == generation then
                render_block(block)
            end
        end)
    )
end

---@param buf integer
local function flush_dirty(buf)
    local state = states[buf]
    if not state or state.paused or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    for _, block in ipairs(state.blocks) do
        if block.dirty then
            render_block(block)
        end
    end
end

local function ensure_resize_autocmd()
    if resize_autocmd then
        return
    end
    resize_autocmd = vim.api.nvim_create_autocmd("WinResized", {
        callback = function()
            for buf in pairs(states) do
                if vim.api.nvim_buf_is_valid(buf) then
                    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
                        if vim.api.nvim_win_is_valid(win) then
                            M.configure_history_window(buf, win)
                        end
                    end
                end
            end
        end,
    })
end

---@param buf integer
function M.attach_history(buf)
    local state = state_for(buf)
    ensure_available(state)
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = buf,
        callback = function()
            flush_dirty(buf)
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            M.detach_history(buf)
        end,
    })
    ensure_resize_autocmd()
end

---@param buf integer
---@param win integer
function M.configure_history_window(buf, win)
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
        return
    end
    vim.w[win].agent_workbench_managed = true
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = "nvic"
    local width = vim.api.nvim_win_get_width(win)
    local info = vim.fn.getwininfo(win)
    if info and info[1] then
        width = math.max(1, info[1].width - info[1].textoff)
    end
    local state = state_for(buf)
    if state.width ~= width then
        state.width = width
        local top = vim.api.nvim_win_call(win, function()
            return vim.fn.line("w0") - 1
        end)
        local bottom = vim.api.nvim_win_call(win, function()
            return vim.fn.line("w$") - 1
        end)
        for _, block in ipairs(state.blocks) do
            if block.width_dependent then
                local anchor = vim.api.nvim_buf_get_extmark_by_id(buf, ns, block.anchor, {})
                local row = anchor[1]
                if row and row <= bottom and row + block.line_count - 1 >= top then
                    block.dirty = true
                    block.generation = block.generation + 1
                    schedule_block(block)
                end
            end
        end
    end
    flush_dirty(buf)
end

---@param buf integer
---@param role "user"|"assistant"
---@param row integer
---@param source? string
---@param col_prefix? integer
---@param complete? boolean
---@return agent_workbench.MarkdownBlock?
function M.start_block(buf, role, row, source, col_prefix, complete)
    if not vim.api.nvim_buf_is_valid(buf) or source == "" then
        return nil
    end
    local state = state_for(buf)
    if not ensure_available(state) then
        return nil
    end
    state.next_id = state.next_id + 1
    local anchor = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        right_gravity = false,
        strict = false,
    })
    local block = {
        id = state.next_id,
        buffer = buf,
        role = role,
        anchor = anchor,
        source_chunks = source and { source } or {},
        col_prefix = col_prefix or 0,
        decoration_ids = {},
        generation = 1,
        complete = complete == true,
        dirty = true,
        width_dependent = false,
        line_count = source and #vim.split(source, "\n", { plain = true }) or 1,
    }
    state.blocks[#state.blocks + 1] = block
    if complete then
        render_block(block)
    else
        schedule_block(block)
    end
    return block
end

---@param block agent_workbench.MarkdownBlock?
---@param chunk string
function M.append_block(block, chunk)
    if not block or chunk == "" or block.complete then
        return
    end
    block.source_chunks[#block.source_chunks + 1] = chunk
    block.line_count = #vim.split(table.concat(block.source_chunks), "\n", { plain = true })
    block.generation = block.generation + 1
    block.dirty = true
    schedule_block(block)
end

---@param block agent_workbench.MarkdownBlock?
function M.finish_block(block)
    if not block or block.complete then
        return
    end
    stop_timer(block)
    block.complete = true
    block.generation = block.generation + 1
    block.dirty = true
    render_block(block)
end

---@param buf integer
function M.pause_history(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local state = state_for(buf)
    state.paused = true
    for _, block in ipairs(state.blocks) do
        stop_timer(block)
    end
end

---@param buf integer
function M.resume_history(buf)
    local state = states[buf]
    if not state or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    state.paused = false
    vim.schedule(function()
        flush_dirty(buf)
    end)
end

---@param buf integer
function M.reset_history(buf)
    local state = states[buf]
    if not state then
        return
    end
    for _, block in ipairs(state.blocks) do
        stop_timer(block)
        clear_decorations(block)
        pcall(vim.api.nvim_buf_del_extmark, buf, ns, block.anchor)
    end
    state.blocks = {}
    state.next_id = 0
    state.available = nil
    Compiler.cleanup()
end

---@param buf integer
function M.detach_history(buf)
    M.reset_history(buf)
    states[buf] = nil
    if resize_autocmd and next(states) == nil then
        pcall(vim.api.nvim_del_autocmd, resize_autocmd)
        resize_autocmd = nil
    end
end

function M._reset()
    for _, buf in ipairs(vim.tbl_keys(states)) do
        M.detach_history(buf)
    end
    states = {}
    warned = {}
    Compiler.cleanup()
end

M._namespace = ns
M._states = function()
    return states
end

return M
