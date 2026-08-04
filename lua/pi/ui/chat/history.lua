--- Chat history buffer — message rendering and scrolling.

---@class pi.ChatHistory
---@field _buf integer
---@field _win integer?
---@field _tab pi.TabId
---@field _scroll_scheduled boolean
---@field _status_extmark_id integer?
---@field _status_virt_line_count integer
---@field _status_text string?
---@field _status_start_time number?
---@field _status_listener fun(model: pi.StatusLineBusy?)? Pushes the busy display model to the prompt statusline
---@field _queue_listener fun(count: integer)? Pushes the pending queue count to the prompt statusline
---@field _spinner_frames string[]
---@field _spinner_rate integer
---@field _spinner_index integer
---@field _spinner_timer uv.uv_timer_t?
---@field _agent_text_chunks string[]?
---@field _first_delta boolean
---@field _agent_start_time number?
---@field _show_thinking boolean
---@field _is_thinking boolean
---@field _needs_separator boolean
---@field _needs_breathing_line boolean
---@field _thinking_accum pi.ThinkingAccum?
---@field _thinking_blocks pi.ThinkingBlock[]
---@field _tool_blocks table<string, pi.ToolBlock>
---@field _compaction_blocks pi.CompactionBlock[]
---@field _blocks_expanded boolean
---@field _placeholder_extmark integer?
---@field _placeholder_mode? "loading"
---@field _has_conversation_content boolean
---@field _startup_block_line_count integer
---@field _startup_block_expanded boolean
---@field _startup_block_expanded_lines? string[]
---@field _startup_block_expanded_marks? pi.HighlightMark[]
---@field _startup_block_compact_lines? string[]
---@field _startup_block_compact_marks? pi.HighlightMark[]
---@field _startup_timestamp integer?
---@field _startup_sections pi.StartupSection[]
---@field _startup_loaded boolean whether startup data has been fetched at least once
---@field _startup_errors pi.SystemErrorEntry[]
---@field _pending_queue pi.PendingQueueEntry[]
---@field _pending_queue_extmark_id integer?
---@field _replaying boolean
---@field _agent_text_start_row integer?
---@field _current_turn_first_agent_response_extmark_id integer?
---@field _current_turn_last_agent_response_extmark_id integer?
---@field _text_batches string[][] sealed/open text-delta batches, one per structural boundary
---@field _structural_inflight integer structural dispatches whose callback has not run yet
---@field _pending_thinking string[]? coalesced thinking deltas awaiting flush
---@field _pending_bash table<string, string[]> coalesced bash output chunks by block id
---@field _pending_tool_updates table<string, pi.RpcEvent> latest tool live-update per tool call
---@field _bash_start_pending table<string, true> bash blocks whose start callback is queued
---@field _tool_start_pending table<string, true> tool blocks whose start callback is queued
---@field _stream_timer uv.uv_timer_t?
---@field _thinking_requested boolean? thinking block whose start callback is queued
local History = {}
History.__index = History

--- Milliseconds between streamed-content flushes. Rapid RPC deltas (text,
--- thinking, bash output, tool live updates) accumulate and are written to
--- the buffer at most once per interval instead of once per delta: every
--- buffer write dirties the screen, so per-delta writes cost roughly one
--- redraw per delta at model streaming rates. Tests may lower this.
History._stream_flush_ms = 30

---@class pi.MdTable
---@field start_row integer 0-indexed first row in the buffer
---@field end_row integer 0-indexed last row in the buffer (inclusive)
---@field header string[] header cell texts (trimmed)
---@field aligns ("left"|"center"|"right")[] per-column alignment
---@field rows string[][] data rows, each a list of cell texts
---@field widths integer[] display width per column

---@class pi.ToolBlock
---@field tool_name string
---@field icon_extmark integer
---@field name_extmark? integer marks tool name highlight (inline tools)
---@field spinner_extmark? integer marks spinner virt_text on header
---@field tail_extmark? integer marks last row of block after on_start; used for positional insertion in on_tool_end
---@field live_update_extmark? integer marks first row of live partial output
---@field live_update_line_count? integer number of live partial output rows
---@field output_extmark? integer
---@field end_extmark? integer
---@field end_hl_group? string highlight applied to the block's end/border row
---@field tool_input? table
---@field inline? boolean
---@field finished? boolean
---@field expanded? boolean
---@field expanded_inner_lines? string[]
---@field expanded_inner_extmarks? table[]
---@field collapsed_inner_lines? string[]
---@field collapsed_specs? string[]

---@class pi.ThinkingAccum
---@field lines string[]
---@field anchor integer
---@field start_time number
---@field buf_lines integer
---@field virt_id? integer extmark id of the streaming thinking preview
---@field header_text? string rendered header text of the thinking block

---@class pi.ThinkingBlock
---@field header string
---@field lines string[]
---@field anchor integer
---@field line_count integer
---@field visible boolean
---@field expanded? boolean

---@class pi.CompactionBlock
---@field summary string
---@field tokens_before integer
---@field anchor integer
---@field line_count integer
---@field expanded boolean

---@class pi.PendingQueueEntry
---@field queue_type "steer"|"follow_up"
---@field text string
---@field expanded_text string
---@field image_count? integer

---@class pi.ChatErrorOpts
---@field pad_top? boolean
---@field pad_bottom? boolean

---@class pi.HighlightMark
---@field row integer
---@field col_start integer
---@field col_end integer
---@field hl string

local Ft = require("pi.filetypes")
local Config = require("pi.config")
local Tools = require("pi.ui.chat.tools")
local Render = require("pi.ui.render")
local Text = require("pi.ui.chat.text")

local ns = vim.api.nvim_create_namespace("pi-chat")

local SCROLL_THRESHOLD = 10
local STARTUP_HL_PRIORITY = 200

---@return integer
local function now_ms()
    return os.time() * 1000
end

---@param image_count integer
---@return string
local function format_attachment_info(image_count)
    local icon = Config.options.labels.attachments
    return image_count == 1 and (icon .. " 1 image attached") or (icon .. " %d images attached"):format(image_count)
end

---@param value integer
---@return string
local function format_number(value)
    local formatted = tostring(value)
    while true do
        local next_value, count = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        formatted = next_value
        if count == 0 then
            return formatted
        end
    end
end

--- Capture extmarks in a row range (positions saved relative to start_row).
---@param buf integer
---@param ns_id integer
---@param start_row integer 0-indexed inclusive
---@param end_row integer 0-indexed inclusive
---@return table[]
local function capture_extmarks(buf, ns_id, start_row, end_row)
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns_id, { start_row, 0 }, { end_row, -1 }, { details = true })
    local result = {}
    for _, m in ipairs(marks) do
        local details = m[4] or {}
        local opts = {}
        for _, key in ipairs({
            "hl_group",
            "virt_text",
            "virt_text_pos",
            "hl_mode",
            "priority",
            "end_col",
            "line_hl_group",
            "hl_eol",
        }) do
            if details[key] ~= nil then
                opts[key] = details[key]
            end
        end
        if details.end_row then
            opts.end_row = details.end_row - start_row -- relative
        end
        result[#result + 1] = { row = m[2] - start_row, col = m[3], opts = opts }
    end
    return result
end

--- Restore previously captured extmarks offset by base_row.
---@param buf integer
---@param ns_id integer
---@param base_row integer 0-indexed
---@param saved table[]
local function restore_extmarks(buf, ns_id, base_row, saved)
    for _, em in ipairs(saved) do
        local opts = vim.deepcopy(em.opts)
        if opts.end_row then
            opts.end_row = base_row + opts.end_row
        end
        pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, base_row + em.row, em.col, opts)
    end
end

--- Re-anchor a tool block's footer extmark as a *single-line* mark.
---
--- nvim_buf_set_lines() shifts the footer row when the inner region is
--- replaced, and Neovim's boundary gravity can mutate the zero-width footer
--- extmark into a multi-line one (end_row = 1, spanning past the buffer end).
--- A later clear_namespace(inner_start, footer_row) then deletes that
--- multi-line mark, which breaks the next expand/collapse toggle (the footer
--- row can no longer be resolved).  Forcing the mark back to a single line
--- after every such set_lines keeps the anchor stable across round-trips.
---@param history pi.ChatHistory
---@param block pi.ToolBlock
---@param footer_row integer 0-indexed row the footer now lives on
local function reanchor_end_extmark(history, block, footer_row)
    if not block or not block.end_extmark then
        return
    end
    local buf = history:buf()
    local line = vim.api.nvim_buf_get_lines(buf, footer_row, footer_row + 1, false)[1] or ""
    vim.api.nvim_buf_set_extmark(buf, ns, footer_row, 0, {
        id = block.end_extmark,
        end_col = #line,
        hl_group = block.end_hl_group,
        line_hl_group = "PiToolBody",
    })
end

---@class pi.SpinnerDef
---@field refresh_rate integer ms between frames
---@field frames string[]
local spinner = {
    classic = {
        refresh_rate = 80,
        frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    },
    robot = {
        refresh_rate = 300,
        frames = {
            "󰚩",
            "󱙺",
            "󱚝",
            "󱚞",
            "󱚟",
            "󱚠",
            "󱚡",
            "󱚢",
            "󱚣",
            "󱚤",
            "󱚟",
            "󱚠",
            "󱜙",
            "󱜚",
            "󱚥",
            "󱚦",
        },
    },
    compaction = {
        refresh_rate = 400,
        frames = {
            "󰏗",
            "󰏖",
            "󱧕",
            "󱧘",
        },
    },
}

--- Format an epoch-ms timestamp for display
---@param ts number epoch milliseconds
---@return string
local function format_time(ts)
    local secs = math.floor(ts / 1000)
    return tostring(os.date(Config.options.timestamp_format, secs)) --[[@as string]]
end

---@param name string
local function wipe_stale_buf(name)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 then
        vim.api.nvim_buf_delete(existing, { force = true })
    end
end

--- Markdown tables

--- Parse cells from a pipe-delimited markdown table row.
---@param line string
---@return string[]
local function parse_table_cells(line)
    local inner = vim.trim(line):match("^|(.+)|$")
    if not inner then
        return {}
    end
    local cells = vim.split(inner, "|", { plain = true })
    for i, cell in ipairs(cells) do
        cells[i] = vim.trim(cell)
    end
    return cells
end

--- Try to parse a contiguous block of lines as a markdown table.
---@param lines string[]
---@param buf_start_row integer 0-indexed buffer row of the first line
---@return pi.MdTable?
local function parse_table(lines, buf_start_row)
    if #lines < 3 then
        return nil
    end
    local header = parse_table_cells(lines[1])
    local ncols = #header
    if ncols == 0 then
        return nil
    end
    local sep_cells = parse_table_cells(lines[2])
    if #sep_cells ~= ncols then
        return nil
    end
    local aligns = {}
    for _, cell in ipairs(sep_cells) do
        if not cell:match("^:?%-+:?$") then
            return nil
        end
        local l = cell:sub(1, 1) == ":"
        local r = cell:sub(-1) == ":"
        if l and r then
            aligns[#aligns + 1] = "center"
        elseif r then
            aligns[#aligns + 1] = "right"
        else
            aligns[#aligns + 1] = "left"
        end
    end
    local data_rows = {}
    for i = 3, #lines do
        local cells = parse_table_cells(lines[i])
        local row = {}
        for j = 1, ncols do
            row[j] = cells[j] or ""
        end
        data_rows[#data_rows + 1] = row
    end
    -- Column widths: max display width across header + all data rows
    local widths = {}
    for j = 1, ncols do
        widths[j] = vim.fn.strdisplaywidth(header[j])
    end
    for _, row in ipairs(data_rows) do
        for j = 1, ncols do
            widths[j] = math.max(widths[j], vim.fn.strdisplaywidth(row[j]))
        end
    end
    for j = 1, ncols do
        widths[j] = math.max(widths[j], 1)
    end
    return {
        start_row = buf_start_row,
        end_row = buf_start_row + #lines - 1,
        header = header,
        aligns = aligns,
        rows = data_rows,
        widths = widths,
    }
end

--- Pad or align a cell string to a given display width.
---@param text string
---@param width integer target display width
---@param align "left"|"center"|"right"
---@return string
local function align_table_cell(text, width, align)
    local pad = width - vim.fn.strdisplaywidth(text)
    if pad <= 0 then
        return text
    end
    if align == "right" then
        return string.rep(" ", pad) .. text
    elseif align == "center" then
        local l = math.floor(pad / 2)
        return string.rep(" ", l) .. text .. string.rep(" ", pad - l)
    end
    return text .. string.rep(" ", pad)
end

--- Build a horizontal border line with box-drawing characters.
---@param widths integer[]
---@param left string corner/tee glyph
---@param mid string intersection glyph
---@param right string corner/tee glyph
---@param fill string horizontal fill glyph
---@return string
local function table_border(widths, left, mid, right, fill)
    local parts = { left }
    for i, w in ipairs(widths) do
        parts[#parts + 1] = string.rep(fill, w + 2) -- +2 for cell padding
        if i < #widths then
            parts[#parts + 1] = mid
        end
    end
    parts[#parts + 1] = right
    return table.concat(parts)
end

--- Build a data/header row line with box-drawing pipe characters.
---@param cells string[]
---@param widths integer[]
---@param aligns ("left"|"center"|"right")[]
---@return string
local function table_row(cells, widths, aligns)
    local parts = { "│" }
    for i, cell in ipairs(cells) do
        parts[#parts + 1] = " " .. align_table_cell(cell, widths[i], aligns[i] or "left") .. " │"
    end
    return table.concat(parts)
end

--- Apply PiTableBorder highlight to every │ character in a buffer line.
---@param buf integer
---@param ns_id integer
---@param row integer 0-indexed
---@param line string
local function highlight_table_pipes(buf, ns_id, row, line)
    local pipe = "│"
    local pos = 1
    while true do
        local s, e = line:find(pipe, pos, true)
        if not s then
            break
        end
        vim.api.nvim_buf_set_extmark(buf, ns_id, row, s - 1, {
            end_col = e,
            hl_group = "PiTableBorder",
            priority = 200,
        })
        pos = e + 1
    end
end

---@param tab pi.TabId
---@return pi.ChatHistory
function History.new(tab)
    local self = setmetatable({}, History)
    self._win = nil
    self._tab = tab
    self._scroll_scheduled = false
    self._status_extmark_id = nil
    self._status_text = nil
    self._status_start_time = nil
    self._status_listener = nil
    self._queue_listener = nil
    self._spinner_index = 1
    self._spinner_timer = nil
    self:_pick_spinner()
    self._agent_text_chunks = nil
    self._first_delta = false
    self._agent_start_time = nil
    self._show_thinking = Config.options.show_thinking
    self._is_thinking = false
    self._needs_separator = false
    self._needs_breathing_line = false
    self._thinking_accum = nil
    self._thinking_blocks = {}
    self._tool_blocks = {}
    self._bash_blocks = {}
    self._bash_replay_counter = 0
    self._compaction_blocks = {}
    self._blocks_expanded = false
    self._placeholder_extmark = nil
    self._placeholder_mode = nil
    self._has_conversation_content = false
    self._startup_block_line_count = 0
    self._startup_block_expanded = Config.options.expand_startup_details
    self._startup_block_expanded_lines = nil
    self._startup_block_expanded_marks = nil
    self._startup_block_compact_lines = nil
    self._startup_block_compact_marks = nil
    self._startup_timestamp = nil
    self._startup_sections = {}
    self._startup_loaded = false
    self._startup_errors = {}
    self._pending_queue = {}
    self._pending_queue_extmark_id = nil
    self._status_virt_line_count = 0
    self._replaying = false
    self._agent_text_start_row = nil
    self._current_turn_first_agent_response_extmark_id = nil
    self._current_turn_last_agent_response_extmark_id = nil
    self._text_batches = { {} } -- invariant: always ends with one open batch
    self._structural_inflight = 0
    self._pending_thinking = nil
    self._pending_bash = {}
    self._pending_tool_updates = {}
    self._bash_start_pending = {}
    self._tool_start_pending = {}
    self._stream_timer = nil
    self._thinking_requested = nil

    local panel = Config.options.panels.history
    local name = panel.name and panel.name(tab) or ("π-chat | " .. tab)
    wipe_stale_buf(name)
    self._buf = vim.api.nvim_create_buf(false, true)
    vim.bo[self._buf].buftype = "nofile"
    vim.bo[self._buf].filetype = Ft.history
    vim.bo[self._buf].swapfile = false
    vim.bo[self._buf].bufhidden = "hide"
    vim.bo[self._buf].modifiable = false
    vim.api.nvim_buf_set_name(self._buf, name)

    -- Optional richer markdown rendering (no-op for the builtin engine).
    Render.attach_history(self._buf)

    return self
end

---@param fn fun()
function History:_with_modifiable(fn)
    vim.bo[self._buf].modifiable = true
    local ok, err = pcall(fn)
    vim.bo[self._buf].modifiable = false
    if not ok then
        error(err)
    end
end

---@return boolean
function History:_should_auto_scroll()
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return false
    end
    local cursor_line = vim.api.nvim_win_get_cursor(self._win)[1]
    local total = vim.api.nvim_buf_line_count(self._buf)
    return (total - cursor_line) <= SCROLL_THRESHOLD
end

function History:_maybe_scroll()
    if not self:_should_auto_scroll() then
        return
    end
    if self._scroll_scheduled then
        return
    end
    self._scroll_scheduled = true
    vim.schedule(function()
        self._scroll_scheduled = false
        self:_scroll_to_bottom()
    end)
end

--- Scroll to the last line with cursor at bottom of the window.
function History:_scroll_to_bottom()
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    vim.api.nvim_win_call(self._win, function()
        -- G=last line, 0=col 1, zb=redraw with cursor at bottom
        vim.cmd("normal! G0zb")
        -- Queue-preview virt_lines render below the last buffer line and
        -- G0zb leaves them clipped below the cursor; scroll down to reveal.
        local n = self._status_virt_line_count or 0
        if n > 0 then
            vim.cmd("normal! " .. n .. "\x05")
        end
    end)
end

local DEFAULT_SCROLL_LINES = 15

--- Scroll the history window by a number of lines.
---@param direction "up"|"down"
---@param lines? integer lines to scroll (default 15)
function History:scroll(direction, lines)
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    local count = lines or DEFAULT_SCROLL_LINES
    local key = direction == "up" and "\x19" or "\x05"
    vim.api.nvim_win_call(self._win, function()
        vim.cmd("normal! " .. count .. key)
    end)
end

--- Scroll the history window to the bottom (most recent message).
function History:scroll_to_bottom()
    self:_scroll_to_bottom()
end

---@param extmark_id integer?
function History:_scroll_to_agent_response(extmark_id)
    if not self._win or not vim.api.nvim_win_is_valid(self._win) then
        return
    end
    if not extmark_id then
        return
    end

    local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, extmark_id, {})
    if not pos or #pos == 0 then
        return
    end

    vim.api.nvim_win_call(self._win, function()
        vim.api.nvim_win_set_cursor(self._win, { pos[1] + 1, 0 })
        vim.cmd("normal! zt")
    end)
end

--- Scroll the history window to the first agent response in the current user turn.
function History:scroll_to_first_agent_response()
    self:_scroll_to_agent_response(self._current_turn_first_agent_response_extmark_id)
end

--- Scroll the history window to the last agent response in the current user turn.
function History:scroll_to_last_agent_response()
    self:_scroll_to_agent_response(self._current_turn_last_agent_response_extmark_id)
end

function History:_pick_spinner()
    local opt = Config.options.spinner
    ---@type pi.SpinnerDef
    local s
    if type(opt) == "table" then
        s = { refresh_rate = opt.refresh_rate or 80, frames = opt.frames or opt }
    else
        s = spinner[opt] or spinner.robot
    end
    self._spinner_frames = s.frames
    self._spinner_rate = s.refresh_rate
end

--- Rebuild the queue-preview virt_lines anchored below the last buffer line.
--- Only the pending-queue preview renders in the history window now; the
--- busy spinner and abort hints live in the prompt statusline (fixed
--- position), so the old bottom-padding machinery is gone and the preview
--- simply follows the content flow.
function History:_update_status_extmark()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return
    end
    -- Hot path: with an empty queue there is nothing to render. Bail before
    -- touching the window so per-delta calls stay O(1).
    if #self._pending_queue == 0 then
        if self._status_extmark_id then
            self:_clear_status_virt_lines()
        end
        return
    end
    local win = self:win()

    -- Build the status rows (rendered as virt_lines below the last buffer line).
    -- hls entries are { start_col, end_col, hl_group } in 0-indexed byte offsets.
    ---@type { text: string, hls: table[] }[]
    local rows = {}

    -- Pending queue rows (left-aligned with a 2-space indent)
    for _, entry in ipairs(self._pending_queue) do
        local label = entry.queue_type == "steer" and (Config.options.labels.steer_message .. " ")
            or (Config.options.labels.follow_up_message .. " ")
        local preview = entry.text:gsub("\n", " ")
        if preview == "" and entry.image_count and entry.image_count > 0 then
            preview = format_attachment_info(entry.image_count)
        end
        if #preview > 80 then
            preview = preview:sub(1, 77) .. "…"
        end
        local prefix = "  " .. label
        local text = prefix .. preview
        rows[#rows + 1] = {
            text = text,
            hls = { { 2, #prefix, "PiPendingQueueLabel" }, { #prefix, #text, "PiPendingQueueText" } },
        }
    end

    -- Text area width for right-padding (excludes signcolumn / foldcolumn).
    local width = 80
    if win then
        local info = vim.fn.getwininfo(win)
        if info and info[1] then
            width = info[1].width - info[1].textoff
        else
            width = vim.api.nvim_win_get_width(win)
        end
    end

    --- Convert a row's hls ({ start, end, hl } in 0-indexed byte offsets)
    --- into virt_lines chunk format ({ { text, hl }, ... }).
    local function row_to_chunks(row)
        local chunks = {} ---@type string[][]
        local pos = 0
        for _, h in ipairs(row.hls) do
            local s, e, hl = h[1], h[2], h[3]
            if s > pos then
                chunks[#chunks + 1] = { row.text:sub(pos + 1, s), "" }
            end
            if e > s then
                chunks[#chunks + 1] = { row.text:sub(s + 1, e), (hl and hl ~= "") and hl or "" }
            end
            pos = e
        end
        if pos < #row.text then
            chunks[#chunks + 1] = { row.text:sub(pos + 1), "" }
        end
        -- Right-pad to full width so the background extends edge-to-edge.
        local text_width = vim.fn.strdisplaywidth(row.text)
        if text_width < width then
            chunks[#chunks + 1] = { string.rep(" ", width - text_width), "" }
        end
        return chunks
    end

    -- Build virt_lines: one blank margin line + queue rows.
    ---@type string[][][]
    local virt_lines = {}
    local blank = { { string.rep(" ", width), "" } }
    virt_lines[#virt_lines + 1] = blank
    for _, r in ipairs(rows) do
        virt_lines[#virt_lines + 1] = row_to_chunks(r)
    end

    self._status_virt_line_count = #virt_lines

    -- Attach virt_lines to the last line of the history buffer.
    local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
    if self._status_extmark_id then
        pcall(vim.api.nvim_buf_set_extmark, self._buf, ns, last_line, 0, {
            id = self._status_extmark_id,
            virt_lines = virt_lines,
        })
    else
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, self._buf, ns, last_line, 0, {
            virt_lines = virt_lines,
        })
        if ok then
            self._status_extmark_id = id
        end
    end
end

--- Clear the status virt_lines from the history buffer.
function History:_clear_status_virt_lines()
    if self._status_extmark_id and self._buf and vim.api.nvim_buf_is_valid(self._buf) then
        pcall(vim.api.nvim_buf_del_extmark, self._buf, ns, self._status_extmark_id)
    end
    self._status_extmark_id = nil
    self._status_virt_line_count = 0
end

--- Register the listener receiving the busy (spinner) display model.
---@param listener fun(model: pi.StatusLineBusy?)?
function History:set_status_listener(listener)
    self._status_listener = listener
end

--- Register the listener receiving the pending queue count.
---@param listener fun(count: integer)?
function History:set_queue_listener(listener)
    self._queue_listener = listener
end

--- Push the current busy display model to the statusline listener.
function History:_emit_status()
    local listener = self._status_listener
    if not listener then
        return
    end
    if not self._status_text then
        listener(nil)
        return
    end
    local elapsed = ""
    if self._status_start_time then
        local secs = math.floor(vim.uv.hrtime() / 1e9 - self._status_start_time)
        if secs >= 60 then
            elapsed = " " .. math.floor(secs / 60) .. "m " .. (secs % 60) .. "s"
        elseif secs >= 1 then
            elapsed = " " .. secs .. "s"
        end
    end
    listener({
        frame = self._spinner_frames[self._spinner_index],
        text = self._status_text,
        elapsed = elapsed,
        thinking = self._is_thinking,
    })
end

--- Push the pending queue count to the statusline listener.
function History:_emit_queue_count()
    if self._queue_listener then
        self._queue_listener(#self._pending_queue)
    end
end

---@param text string
function History:_append_text(text)
    local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
    local cur = vim.api.nvim_buf_get_lines(self._buf, last_line, last_line + 1, false)[1] or ""
    local col = #cur
    local lines = vim.split(text, "\n", { plain = true })
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_text(self._buf, last_line, col, last_line, col, lines)
    end)
    self:_update_status_extmark()
    self:_maybe_scroll()
end

-- ---------------------------------------------------------------------------
-- Stream coalescing
--
-- Streaming RPC events (text_delta, thinking_delta, bash output, tool live
-- updates) used to each vim.schedule() their own buffer write — hundreds of
-- scheduled callbacks per response, and because every write dirties the
-- screen, roughly one redraw per delta at model streaming rates. Deltas now
-- accumulate synchronously at dispatch time and are flushed by a one-shot
-- timer at most once per History._stream_flush_ms.
--
-- Ordering with structural events (tool blocks, thinking blocks, turn
-- boundaries) is preserved exactly, even when many events dispatch inside
-- one event-loop turn: text deltas append to an open batch; every structural
-- *dispatch* seals the current batch (synchronously, so seals and callbacks
-- share one FIFO timeline); every structural *callback* pops and renders
-- exactly the batch sealed at its dispatch before mutating the buffer. The
-- timer flush only drains text while no structural callback is in flight.
--
-- Invariant: `_text_batches` always ends with one open batch. The pop in a
-- structural callback targets the batch that was open *before* its dispatch's
-- seal; if the list could be empty at seal time, the freshly pushed batch
-- itself would be popped — and any delta dispatched right after the seal
-- (e.g. the lazy assistant-block open, where on_agent_start and the first
-- on_text_delta dispatch back-to-back) would render *before* the structural
-- block (the first text chunk landed above the agent label).
-- ---------------------------------------------------------------------------

--- Append a coalesced text batch to the buffer, applying the stream-position
--- transforms (first-delta newline strip, post-tool breathing line).
---@param delta string
function History:_render_text_deltas(delta)
    if self._first_delta then
        self._first_delta = false
        delta = delta:gsub("^\n+", "")
        if delta == "" then
            return
        end
    end
    self._last_was_inline = false
    -- After a tool block, prepend a newline so the blank footer line
    -- becomes breathing room and text starts on a fresh line.
    if self._needs_breathing_line then
        self._needs_breathing_line = false
        delta = "\n" .. delta
    end
    if self._agent_text_chunks then
        self._agent_text_chunks[#self._agent_text_chunks + 1] = delta
    end
    if delta ~= "" then
        self:_append_text(delta)
    end
end

--- Seal the current text batch at a structural dispatch. Synchronous by
--- design: the seal shares the dispatch timeline, so the batch a structural
--- callback later pops is exactly the text that preceded its event.
function History:_seal_stream_text()
    self._text_batches[#self._text_batches + 1] = {}
    self._structural_inflight = self._structural_inflight + 1
end

--- Pop and render the batch sealed at this callback's dispatch. Every sealed
--- dispatch pops exactly once (keeping seals and callbacks FIFO-aligned), so
--- structural callbacks pop unconditionally at their top — even on early
--- returns.
function History:_pop_text_batch()
    self._structural_inflight = math.max(0, self._structural_inflight - 1)
    local batch = table.remove(self._text_batches, 1)
    if not batch or #batch == 0 then
        return
    end
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return
    end
    self:_render_text_deltas(table.concat(batch))
end

--- Timer-side text drain. Only safe while no structural callback is in
--- flight; those drain their own sealed batch in order.
function History:_flush_stream_text()
    if self._structural_inflight > 0 then
        return
    end
    local batches = self._text_batches
    if #batches == 0 then
        return
    end
    -- Keep the always-open tail batch invariant (see above).
    self._text_batches = { {} }
    local flat = batches[1]
    if #batches > 1 then
        flat = {}
        for _, batch in ipairs(batches) do
            vim.list_extend(flat, batch)
        end
    end
    if #flat == 0 then
        return
    end
    self:_render_text_deltas(table.concat(flat))
end

--- Pending content needing a timer re-arm: text batches not yet drainable
--- (structural callbacks in flight) or deltas whose anchor block does not
--- exist yet (its start callback runs next loop turn).
---@return boolean
function History:_has_deferred_stream()
    for _, batch in ipairs(self._text_batches) do
        if #batch > 0 then
            return true
        end
    end
    if self._pending_thinking then
        return true
    end
    if next(self._pending_bash) then
        return true
    end
    if next(self._pending_tool_updates) then
        return true
    end
    return false
end

--- Arm the one-shot flush timer (no-op when already armed).
function History:_ensure_stream_timer()
    if self._stream_timer then
        return
    end
    local timer = assert(vim.uv.new_timer())
    self._stream_timer = timer
    timer:start(
        History._stream_flush_ms,
        0,
        vim.schedule_wrap(function()
            if self._stream_timer ~= timer then
                return -- cleared while this callback was queued
            end
            self._stream_timer = nil
            timer:stop()
            timer:close()
            self:_flush_stream()
            if self:_has_deferred_stream() then
                self:_ensure_stream_timer()
            end
        end)
    )
end

--- Drain all pending streamed content. Synchronous; called from the flush
--- timer (structural handlers drain their own sealed batch via
--- _pop_text_batch instead, keeping FIFO alignment).
function History:_flush_stream()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        self._text_batches = { {} }
        self._pending_thinking = nil
        self._pending_bash = {}
        self._pending_tool_updates = {}
        return
    end
    self:_flush_stream_text()
    self:_flush_stream_thinking()
    self:_flush_stream_bash()
    self:_flush_tool_updates()
end

function History:_flush_stream_thinking()
    local pending = self._pending_thinking
    if not pending then
        return
    end
    if not self._thinking_accum then
        -- on_thinking_start's scheduled callback has not run yet; keep queued.
        return
    end
    self._pending_thinking = nil
    local delta = table.concat(pending)
    local parts = vim.split(delta, "\n", { plain = true })
    self._thinking_accum.lines[#self._thinking_accum.lines] = self._thinking_accum.lines[#self._thinking_accum.lines]
        .. parts[1]
    for i = 2, #parts do
        self._thinking_accum.lines[#self._thinking_accum.lines + 1] = parts[i]
    end

    if not self._show_thinking then
        return
    end
    -- Single-line: keep the header row fixed, roll the latest thinking
    -- through its inline preview (tail window) so the block stays one line.
    local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, self._thinking_accum.anchor, {})
    local header_row = pos[1] and (pos[1] + 1) or nil
    if header_row then
        local flat = Text.thinking_flat(self._thinking_accum.lines)
        local pw = self:_thinking_preview_width(self._thinking_accum.header_text or "")
        local preview = Text.thinking_tail(flat, pw)
        self._thinking_accum.virt_id = self:_set_thinking_preview(header_row, preview, self._thinking_accum.virt_id)
    end
    self:_update_status_extmark()
    self:_maybe_scroll()
end

function History:_flush_stream_bash()
    if not next(self._pending_bash) then
        return
    end
    for id, chunks in pairs(self._pending_bash) do
        local block = self._bash_blocks[id]
        if block and not block.finished then
            self._pending_bash[id] = nil
            self:_apply_bash_output(block, table.concat(chunks))
        elseif not self._bash_start_pending[id] then
            -- Stray output for a block that never started (or is gone).
            self._pending_bash[id] = nil
        end
        -- else: on_bash_start's scheduled callback has not run yet; keep queued.
    end
end

function History:_flush_tool_updates()
    if not next(self._pending_tool_updates) then
        return
    end
    for id, msg in pairs(self._pending_tool_updates) do
        if self._tool_blocks[id] then
            self._pending_tool_updates[id] = nil
            self:_apply_tool_update(id, msg)
        elseif not self._tool_start_pending[id] then
            -- Update for a tool that never started (or whose block is gone).
            self._pending_tool_updates[id] = nil
        end
        -- else: on_tool_start's scheduled callback has not run yet; keep queued.
    end
end

---@param text string
---@return boolean
function History:_agent_text_has_open_fence(text)
    local open = false
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        if line:match("^%s*```") then
            open = not open
        end
    end
    return open
end

---@param lines_list string[]
---@return integer start_row 0-indexed row where the first line was placed
function History:_append_lines(lines_list)
    local start_row = 0
    self:_with_modifiable(function()
        local line_count = vim.api.nvim_buf_line_count(self._buf)
        if line_count == 1 then
            local first = vim.api.nvim_buf_get_lines(self._buf, 0, 1, false)[1]
            if first == "" then
                vim.api.nvim_buf_set_lines(self._buf, 0, 1, false, lines_list)
                start_row = 0
                self:_maybe_scroll()
                return
            end
        end
        start_row = line_count
        vim.api.nvim_buf_set_lines(self._buf, line_count, line_count, false, lines_list)
    end)
    self:_update_status_extmark()
    self:_maybe_scroll()
    return start_row
end

--- Insert lines at a specific row instead of appending at the buffer end.
--- Used by on_tool_end to place output inside the correct tool block when
--- multiple tools run in parallel.
---@param row integer 0-indexed row to insert before
---@param lines_list string[]
---@return integer start_row 0-indexed row where the first line was placed
---@return integer next_row row after the last inserted line (for chaining)
function History:_insert_lines(row, lines_list)
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, row, row, false, lines_list)
    end)
    self:_update_status_extmark()
    self:_maybe_scroll()
    return row, row + #lines_list
end

--- Available display columns for the single-line thinking preview.
---@return integer
function History:_thinking_preview_width(header_text)
    local w = 80
    if self._win and vim.api.nvim_win_is_valid(self._win) then
        w = vim.api.nvim_win_get_width(self._win)
    end
    local reserved = vim.fn.strdisplaywidth(header_text) + 3
    return math.max(16, w - reserved)
end

--- Set (or clear) the end-of-line preview virtual text on a thinking header row.
---
--- Uses `virt_text_pos = "eol"` on purpose, not `"inline"`. An inline virt_text
--- counts toward the line's wrap width, so when the preview contains long
--- space-less runs (e.g. `pcall(vim.api.nvim_win_set_config)`) or wide glyphs,
--- the header line wraps onto a second screen line. Worse, Neovim computes the
--- wrap width with utf8proc char widths while the real terminal font often
--- renders nerd icons and ambiguous-width chars (the thinking icon, `…`) one
--- cell wider; that mismatch makes the *rendered* width oscillate between the
--- window width and width+1 as the rolling preview changes, so the header
--- flickers between one and two wrapped lines. An `eol` virt_text does not
--- participate in wrap width at all — it is drawn after the line and clipped at
--- the window edge — so the header always stays a single screen line regardless
--- of preview width or glyph-width mismatch. Visually it is nearly identical to
--- inline (the preview still sits right after a short header) and the hard clip
--- matches the existing tail truncation (which adds no ellipsis either).
---@param row integer 0-indexed header row
---@param text string? preview text; nil clears
---@return integer? virt_id
function History:_set_thinking_preview(row, text, virt_id)
    if not text or text == "" then
        if virt_id then
            pcall(vim.api.nvim_buf_del_extmark, self._buf, ns, virt_id)
        end
        return nil
    end
    local line = vim.api.nvim_buf_get_lines(self._buf, row, row + 1, false)[1] or ""
    local opts = {
        virt_text = { { "  " .. text, "PiThinkingPreview" } },
        virt_text_pos = "eol",
    }
    if virt_id then
        opts.id = virt_id
    end
    return vim.api.nvim_buf_set_extmark(self._buf, ns, row, #line, opts)
end

---@param header string
---@param content string[]
---@return string[]
function History:_build_thinking_block(header, content)
    local label = Config.options.labels.thinking
    local indent = "  "
    local result = { "", label .. " " .. header }
    for _, line in ipairs(content) do
        result[#result + 1] = indent .. line
    end
    result[#result + 1] = ""
    return result
end

---@param start_row integer
---@param count integer
function History:_apply_thinking_hl(start_row, count)
    for i = 0, count - 1 do
        local line = vim.api.nvim_buf_get_lines(self._buf, start_row + i, start_row + i + 1, false)[1] or ""
        vim.api.nvim_buf_set_extmark(self._buf, ns, start_row + i, 0, {
            end_col = #line,
            hl_group = "PiThinking",
        })
    end
end

---@param block_lines string[]
---@param anchor integer extmark id
function History:_insert_thinking_block(block_lines, anchor)
    local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, anchor, {})
    local row = pos[1]
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, row, row, false, block_lines)
    end)
    self:_apply_thinking_hl(row + 1, #block_lines - 2)
    self:_update_status_extmark()
    self:_maybe_scroll()
end

---@param line_count integer
---@param anchor integer extmark id
function History:_remove_thinking_block(line_count, anchor)
    local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, anchor, {})
    local anchor_row = pos[1]
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, anchor_row, anchor_row + line_count, false, {})
    end)
    self:_update_status_extmark()
    self:_maybe_scroll()
end

---@return integer
function History:buf()
    return self._buf
end

---@return integer
function History:ns()
    return ns
end

---@param win integer?
function History:set_win(win)
    self._win = win
end

---@return integer?
function History:win()
    if self._win and vim.api.nvim_win_is_valid(self._win) then
        return self._win
    end
    return nil
end

---@alias pi.Status { type: "agent", text: string } | { type: "compaction" }

---@param status pi.Status?
function History:set_status(status)
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end

        local text ---@type string?
        if status then
            if status.type == "compaction" then
                local s = spinner.compaction
                self._spinner_frames = s.frames
                self._spinner_rate = s.refresh_rate
                text = "Compacting…"
            else
                self:_pick_spinner()
                text = status.text
            end
        else
            self:_pick_spinner()
        end

        if text == self._status_text then
            return
        end
        self._status_text = text
        self._status_start_time = text and math.floor(vim.uv.hrtime() / 1e9) or nil
        self._spinner_index = 1
        self:_emit_status()
        -- Force scroll (bypass _scroll_scheduled guard) so the turn start is
        -- visible even if a prior scroll is still pending.
        if text and self:_should_auto_scroll() then
            self:_scroll_to_bottom()
        else
            self:_maybe_scroll()
        end

        -- Stop existing timer — rate may have changed between spinner types.
        if self._spinner_timer then
            self._spinner_timer:stop()
            self._spinner_timer:close()
            self._spinner_timer = nil
        end

        if text then
            self._spinner_timer = assert(vim.uv.new_timer())
            self._spinner_timer:start(
                self._spinner_rate,
                self._spinner_rate,
                vim.schedule_wrap(function()
                    self._spinner_index = self._spinner_index % #self._spinner_frames + 1
                    if self._status_text then
                        self:_emit_status()
                    end
                    -- Animate tool header spinners
                    local frame = self._spinner_frames[self._spinner_index]
                    for _, blk in pairs(self._tool_blocks) do
                        if blk.spinner_extmark and not blk.finished then
                            local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, blk.spinner_extmark, {})
                            if pos[1] then
                                vim.api.nvim_buf_set_extmark(self._buf, ns, pos[1], pos[2] or 0, {
                                    id = blk.spinner_extmark,
                                    virt_text = { { "  " .. frame, "PiToolRunning" } },
                                    virt_text_pos = "inline",
                                })
                            end
                        end
                    end
                end)
            )
        end
    end)
end

--- Find and render all markdown tables in the given buffer range.
--- Skips tables inside fenced code blocks.
---@param from_row integer 0-indexed
---@param to_row integer 0-indexed (inclusive)
function History:_render_tables(from_row, to_row)
    if from_row > to_row then
        return
    end
    local all_lines = vim.api.nvim_buf_get_lines(self._buf, from_row, to_row + 1, false)
    ---@type pi.MdTable[]
    local tables = {}
    local in_fence = false
    local i = 1
    while i <= #all_lines do
        local line = all_lines[i]
        if line:match("^```") then
            in_fence = not in_fence
            i = i + 1
        elseif in_fence then
            i = i + 1
        else
            local trimmed = vim.trim(line)
            if trimmed:match("^|.+|$") then
                local block = { line }
                local j = i + 1
                while j <= #all_lines do
                    local nt = vim.trim(all_lines[j])
                    if nt:match("^|.+|$") then
                        block[#block + 1] = all_lines[j]
                        j = j + 1
                    else
                        break
                    end
                end
                if #block >= 3 then
                    local tbl = parse_table(block, from_row + i - 1)
                    if tbl then
                        tables[#tables + 1] = tbl
                    end
                end
                i = j
            else
                i = i + 1
            end
        end
    end
    -- Render in reverse order so earlier row indices remain valid.
    for t = #tables, 1, -1 do
        self:_render_md_table(tables[t])
    end
end

--- Replace a parsed markdown table with box-drawing rendered lines and extmarks.
---@param tbl pi.MdTable
function History:_render_md_table(tbl)
    local widths = tbl.widths
    local aligns = tbl.aligns

    -- Build replacement lines (same count as original).
    local new_lines = {}
    new_lines[1] = table_row(tbl.header, widths, aligns)
    new_lines[2] = table_border(widths, "├", "┼", "┤", "─")
    for _, row in ipairs(tbl.rows) do
        new_lines[#new_lines + 1] = table_row(row, widths, aligns)
    end

    local top = table_border(widths, "┌", "┬", "┐", "─")
    local bot = table_border(widths, "└", "┴", "┘", "─")

    -- Replace buffer lines.
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, tbl.start_row, tbl.end_row + 1, false, new_lines)
    end)

    -- Top border (virtual line above first row).
    vim.api.nvim_buf_set_extmark(self._buf, ns, tbl.start_row, 0, {
        virt_lines = { { { top, "PiTableBorder" } } },
        virt_lines_above = true,
    })

    -- Bottom border (virtual line below last row).
    local last_row = tbl.start_row + #new_lines - 1
    vim.api.nvim_buf_set_extmark(self._buf, ns, last_row, 0, {
        virt_lines = { { { bot, "PiTableBorder" } } },
    })

    -- Highlights.
    for i, line in ipairs(new_lines) do
        local row = tbl.start_row + i - 1
        if i == 1 then
            -- Header: bold on the whole line, border color on │ at higher priority.
            vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
                end_col = #line,
                hl_group = "PiTableHeader",
                priority = 100,
            })
            highlight_table_pipes(self._buf, ns, row, line)
        elseif i == 2 then
            -- Separator: full border color.
            vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
                end_col = #line,
                hl_group = "PiTableBorder",
            })
        else
            -- Data rows: border color on │ only.
            highlight_table_pipes(self._buf, ns, row, line)
        end
    end
end

---@param msg string
---@param timestamp? number
---@param image_count? integer
---@param queue_type? "steer"|"follow_up"
function History:add_user_message(msg, timestamp, image_count, queue_type)
    self:_seal_stream_text()
    vim.schedule(function()
        self:_pop_text_batch()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self._current_turn_first_agent_response_extmark_id = nil
        self._current_turn_last_agent_response_extmark_id = nil
        local had_content = self._has_conversation_content
        self:_begin_conversation_content()
        local icon = Config.options.labels.user_message
        local has_message_text = msg ~= ""
        local msg_lines = has_message_text and vim.split(msg, "\n", { plain = true }) or {}
        -- Treesitter highlights fenced code blocks — an unclosed fence bleeds
        -- into everything below. We track fence parity and auto-close if odd.
        local fences = 0
        for _, line in ipairs(msg_lines) do
            if line:match("^```") then
                fences = fences + 1
            end
        end
        if fences % 2 == 1 then
            msg_lines[#msg_lines + 1] = "```"
        end
        local time = timestamp or (os.time() * 1000)
        local time_str = format_time(time)
        local queue_tag = ""
        if queue_type == "steer" then
            queue_tag = "  " .. Config.options.labels.steer_message
        elseif queue_type == "follow_up" then
            queue_tag = "  " .. Config.options.labels.follow_up_message
        end
        local time_sep = " "
        local label_line = icon .. time_sep .. time_str .. queue_tag
        -- Turn gap: extra blank line when turn_separator is on
        local turn_gap = (had_content and Config.options.turn_separator) and "" or nil
        local lines = turn_gap and { "", "", label_line, "" } or { "", label_line, "" }
        -- Indent user body lines
        for i, line in ipairs(msg_lines) do
            msg_lines[i] = "  " .. line
        end
        vim.list_extend(lines, msg_lines)
        if image_count and image_count > 0 then
            local info = format_attachment_info(image_count)
            lines[#lines + 1] = ""
            lines[#lines + 1] = info
        end
        local start = self:_append_lines(lines)
        local label_row = start + (turn_gap and 2 or 1)
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, 0, {
            end_col = #icon,
            hl_group = "PiUserMessageLabel",
        })
        local time_start = #icon + #time_sep
        local time_end = time_start + #time_str
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, time_start, {
            end_col = time_end,
            hl_group = "PiMessageDateTime",
        })
        if queue_tag ~= "" then
            vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, time_end, {
                end_col = time_end + #queue_tag,
                hl_group = "PiMessageQueueTag",
            })
        end
        -- Color user body text with the user role hue (Title.fg)
        local body_start = label_row + 2
        local body_end = label_row + 1 + #msg_lines
        for row = body_start, body_end do
            local line = vim.api.nvim_buf_get_lines(self._buf, row, row + 1, false)[1] or ""
            if #line > 0 then
                vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
                    end_col = #line,
                    hl_group = "PiUserBody",
                })
            end
        end
        if image_count and image_count > 0 then
            local info_row = start + #lines - 1
            local info_text = lines[#lines]
            vim.api.nvim_buf_set_extmark(self._buf, ns, info_row, 0, {
                end_col = #info_text,
                hl_group = "PiMessageAttachments",
            })
        end
        self:_scroll_to_bottom()
    end)
end

---@param timestamp? number
function History:on_agent_start(timestamp)
    self:_seal_stream_text()
    vim.schedule(function()
        self:_pop_text_batch() -- land stragglers from the previous turn in order
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        local had_content = self._has_conversation_content
        self:_begin_conversation_content()
        self._agent_start_time = vim.uv.hrtime() / 1e9
        self._first_delta = true
        self._agent_text_chunks = {}
        self._needs_separator = false
        self._last_was_inline = false
        self:_pick_spinner()
        local icon = Config.options.labels.agent_response
        local time = timestamp or (os.time() * 1000)
        local time_str = format_time(time)
        local time_sep = " "
        local label_line = icon .. time_sep .. time_str
        local turn_gap = (had_content and Config.options.turn_separator) and "" or nil
        -- If the buffer already ends with a blank line (e.g. a thinking block's
        -- trailing margin, or a tool block's footer), skip one leading blank so
        -- we don't double up (#48).  tool_start / bash_start do the same check.
        local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
        local last_text = vim.api.nvim_buf_get_lines(self._buf, last_line, last_line + 1, false)[1] or ""
        local ends_blank = last_text == ""
        -- End the label block exactly like a tool block's end (#48): one
        -- trailing blank + the breathing-line flag. A following text delta
        -- prepends a newline in _render_text_deltas, so one blank remains
        -- before the text; a following tool/bash/thinking block sees the
        -- blank last line and adds none of its own. Previously the label
        -- left two trailing blanks that only a text delta reused, so a
        -- block follower rendered a two-line gap under the label.
        self._needs_breathing_line = true
        local lines
        if turn_gap then
            lines = ends_blank and { "", label_line, "" } or { "", "", label_line, "" }
        else
            lines = ends_blank and { label_line, "" } or { "", label_line, "" }
        end
        local start = self:_append_lines(lines)
        local label_offset = turn_gap and (ends_blank and 1 or 2) or (ends_blank and 0 or 1)
        local label_row = start + label_offset
        local response_extmark_id = vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, 0, {})
        if not self._current_turn_first_agent_response_extmark_id then
            self._current_turn_first_agent_response_extmark_id = response_extmark_id
        end
        self._current_turn_last_agent_response_extmark_id = response_extmark_id
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, 0, {
            end_col = #icon,
            hl_group = "PiAgentResponseLabel",
        })
        local time_start = #icon + #time_sep
        vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, time_start, {
            end_col = #label_line,
            hl_group = "PiMessageDateTime",
        })
        self._agent_text_start_row = label_row + 2
    end)
end

---@param delta string
function History:on_text_delta(delta)
    -- Accumulate and coalesce (see the flush machinery above); ordering with
    -- structural events is preserved by seal-at-dispatch / pop-in-callback.
    local batches = self._text_batches
    local open = batches[#batches]
    if not open then
        open = {}
        batches[1] = open
    end
    open[#open + 1] = delta
    self:_ensure_stream_timer()
end

---@param done_verb? string
---@param opts? { force_completion?: boolean, stop_reason?: string }
function History:on_agent_end(done_verb, opts)
    self:_seal_stream_text()
    vim.schedule(function()
        self:_pop_text_batch() -- land the final streamed text before turn close
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        -- Agent may stop mid-stream with an open fence. Recompute from the
        -- streamed agent text because chunks can split the ``` marker.
        local agent_text = table.concat(self._agent_text_chunks or {})
        if self:_agent_text_has_open_fence(agent_text) then
            self:_append_text("\n```")
        end
        self._agent_text_chunks = nil
        -- Render markdown tables in the agent response text.
        if self._agent_text_start_row then
            local scan_end = vim.api.nvim_buf_line_count(self._buf) - 1
            self:_render_tables(self._agent_text_start_row, scan_end)
            self._agent_text_start_row = nil
        end
        if not self._agent_start_time then
            return
        end
        local elapsed = vim.uv.hrtime() / 1e9 - self._agent_start_time
        local secs = math.floor(elapsed)
        self._agent_start_time = nil
        local force_completion = opts and opts.force_completion == true
        if secs < 1 and not force_completion then
            return
        end
        local verb = done_verb or "Completed"
        local duration
        if secs >= 60 then
            duration = math.floor(secs / 60) .. "m " .. (secs % 60) .. "s"
        elseif secs >= 1 then
            duration = secs .. "s"
        else
            duration = "<1s"
        end
        local suffix = force_completion and ("  · " .. verb:lower()) or ("  · " .. duration)
        -- Aborted/errored turns get a prominent highlight instead of the muted
        -- completion color, so the final state is easy to spot in the history.
        local stop_reason = opts and opts.stop_reason
        local completion_hl = "PiBusyTime"
        if stop_reason == "aborted" then
            completion_hl = "PiAborted"
        elseif stop_reason == "error" then
            completion_hl = "PiError"
        end
        -- Attach completion as virtual text on the last non-empty prose line
        local last_line_idx = vim.api.nvim_buf_line_count(self._buf) - 1
        local last_text = vim.api.nvim_buf_get_lines(self._buf, last_line_idx, last_line_idx + 1, false)[1] or ""
        local win_width = self._win and vim.api.nvim_win_is_valid(self._win) and vim.api.nvim_win_get_width(self._win)
            or 80
        if last_text ~= "" and (#last_text + #suffix) < win_width then
            vim.api.nvim_buf_set_extmark(self._buf, ns, last_line_idx, #last_text, {
                virt_text = { { suffix, completion_hl } },
                virt_text_pos = "inline",
            })
        else
            -- Fallback: standalone line
            local text = verb .. " in " .. duration
            local start = self:_append_lines({ "", text })
            vim.api.nvim_buf_set_extmark(self._buf, ns, start + 1, 0, {
                end_col = #text,
                hl_group = completion_hl,
            })
        end
    end)
end

---@param error_message string
---@param opts? pi.ChatErrorOpts
function History:on_error(error_message, opts)
    self:_seal_stream_text()
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self:_pop_text_batch()
        local icon = Config.options.labels.error
        local error_lines = vim.split(error_message, "\n", { plain = true })
        local indent = string.rep(" ", vim.fn.strdisplaywidth(icon) + 1)
        error_lines[1] = icon .. " " .. error_lines[1]
        for i = 2, #error_lines do
            error_lines[i] = indent .. error_lines[i]
        end

        local lines = {}
        if opts and opts.pad_top then
            lines[#lines + 1] = ""
        end
        local first_error_row = #lines + 1
        for _, line in ipairs(error_lines) do
            lines[#lines + 1] = line
        end
        if opts and opts.pad_bottom then
            lines[#lines + 1] = ""
        end

        local start = self:_append_lines(lines)
        for i, line in ipairs(error_lines) do
            local row = start + first_error_row + i - 2
            vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
                end_col = #line,
                hl_group = "PiError",
            })
            -- Error alarm rail
            vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
                virt_text = { { "▌ ", "PiErrorRail" } },
                virt_text_pos = "inline",
                hl_mode = "replace",
            })
        end
        self:_maybe_scroll()
    end)
end

---@param error_message string
---@param timestamp integer
---@param opts? pi.ChatErrorOpts
function History:_append_system_error_block(error_message, timestamp, opts)
    local icon = Config.options.labels.system_error
    local time_str = format_time(timestamp)
    local time_sep = " "
    local label_line = icon .. time_sep .. time_str
    local error_lines = vim.split(error_message, "\n", { plain = true })

    local lines = {}
    if opts and opts.pad_top then
        lines[#lines + 1] = ""
    end
    local label_row_offset = #lines
    lines[#lines + 1] = label_line
    for _, line in ipairs(error_lines) do
        lines[#lines + 1] = line
    end
    if opts and opts.pad_bottom then
        lines[#lines + 1] = ""
    end

    local start = self:_append_lines(lines)
    local label_row = start + label_row_offset
    vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, 0, {
        end_col = #icon,
        hl_group = "PiSystemErrorIcon",
        priority = STARTUP_HL_PRIORITY,
    })
    local time_start = #icon + #time_sep
    vim.api.nvim_buf_set_extmark(self._buf, ns, label_row, time_start, {
        end_col = #label_line,
        hl_group = "PiMessageDateTime",
        priority = STARTUP_HL_PRIORITY,
    })
    for i, line in ipairs(error_lines) do
        local row = label_row + i
        vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
            end_col = #line,
            hl_group = "PiStartupError",
            priority = STARTUP_HL_PRIORITY,
        })
        -- Error alarm rail on body lines (not the pill label line)
        vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
            virt_text = { { "▌ ", "PiErrorRail" } },
            virt_text_pos = "inline",
            hl_mode = "replace",
            priority = STARTUP_HL_PRIORITY,
        })
    end
    self:_maybe_scroll()
end

---@param sections table[]
---@return pi.StartupSection[]
function History:_normalize_startup_sections(sections)
    local normalized = {} ---@type pi.StartupSection[]
    for _, section in ipairs(sections or {}) do
        local header = section.header or section.title
        local items = section.items or section.lines or {}
        if type(header) == "string" and type(items) == "table" then
            local normalized_items = {} ---@type string[]
            for _, item in ipairs(items) do
                if type(item) == "string" then
                    normalized_items[#normalized_items + 1] = item
                end
            end
            if #normalized_items > 0 then
                normalized[#normalized + 1] = {
                    header = header,
                    items = normalized_items,
                    hl = section.hl,
                }
            end
        end
    end
    return normalized
end

function History:_begin_conversation_content()
    if self._has_conversation_content then
        return
    end
    self._has_conversation_content = true
    self:clear_placeholder()
end

--- Build the welcome header used by both compact and expanded startup views.
---@return string[], pi.HighlightMark[]
function History:_build_startup_header()
    local lines = {} ---@type string[]
    local marks = {} ---@type pi.HighlightMark[]

    -- Welcome lines (always shown)
    local label = " " .. Config.options.labels.agent_response .. " "
    local body = "  Hi! Ask me anything or describe what you'd like to build."
    local hint_prefix = "     Use "
    local mention = "@file"
    local hint_middle = " to mention files or "
    local command = "/command"
    local hint_suffix = " for shortcuts."

    lines[#lines + 1] = ""
    lines[#lines + 1] = label .. body
    local welcome_row = #lines - 1
    marks[#marks + 1] = { row = welcome_row, col_start = 0, col_end = #label, hl = "PiAgentResponseLabel" }
    marks[#marks + 1] = { row = welcome_row, col_start = #label, col_end = #lines[#lines], hl = "PiWelcome" }

    lines[#lines + 1] = ""
    local hint_line = hint_prefix .. mention .. hint_middle .. command .. hint_suffix
    lines[#lines + 1] = hint_line
    local hint_row = #lines - 1
    local col = 0
    marks[#marks + 1] = { row = hint_row, col_start = col, col_end = col + #hint_prefix, hl = "PiWelcomeHint" }
    col = col + #hint_prefix
    marks[#marks + 1] = { row = hint_row, col_start = col, col_end = col + #mention, hl = "PiMention" }
    col = col + #mention
    marks[#marks + 1] = { row = hint_row, col_start = col, col_end = col + #hint_middle, hl = "PiWelcomeHint" }
    col = col + #hint_middle
    marks[#marks + 1] = { row = hint_row, col_start = col, col_end = col + #command, hl = "PiCommand" }
    col = col + #command
    marks[#marks + 1] = { row = hint_row, col_start = col, col_end = col + #hint_suffix, hl = "PiWelcomeHint" }

    lines[#lines + 1] = ""

    return lines, marks
end

--- Build the compact (collapsed) startup block: header + summary line.
---@return string[], pi.HighlightMark[]
function History:_build_compact_startup()
    local lines, marks = self:_build_startup_header()

    -- Build summary from known categories; count startup announcement sections separately.
    local known_headers = { ["[Skills]"] = "skills", ["[Prompts]"] = "prompts", ["[Extensions]"] = "extensions" }
    local parts = {} ---@type string[]
    local announcement_count = 0
    for _, section in ipairs(self._startup_sections) do
        local label = known_headers[section.header]
        if label then
            parts[#parts + 1] = #section.items .. " " .. label
        else
            announcement_count = announcement_count + 1
        end
    end
    if announcement_count > 0 then
        parts[#parts + 1] = announcement_count
            .. " extension"
            .. (announcement_count > 1 and "s" or "")
            .. " reported startup info"
    end
    local summary = "     Loaded resources: " .. table.concat(parts, ", ")
    lines[#lines + 1] = summary
    marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #summary, hl = "PiStartupDetail" }

    local hint = "     Run :PiToggleStartupDetails to expand the details or focus this block and hit Tab"
    lines[#lines + 1] = hint
    marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #hint, hl = "PiStartupHint" }

    return lines, marks
end

--- Build the expanded startup block: header + full section listing.
---@return string[], pi.HighlightMark[]
function History:_build_expanded_startup()
    local lines, marks = self:_build_startup_header()

    local intro = "     Loaded resources:"
    lines[#lines + 1] = intro
    marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #intro, hl = "PiStartupDetail" }

    for _, section in ipairs(self._startup_sections) do
        lines[#lines + 1] = ""
        local header_line = "     " .. section.header
        lines[#lines + 1] = header_line
        marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #header_line, hl = "PiStartupDetail" }
        for _, item in ipairs(section.items) do
            local item_line = "     " .. item
            lines[#lines + 1] = item_line
            marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #item_line, hl = "PiStartupDetail" }
        end
    end

    return lines, marks
end

--- Build error lines/marks for startup errors.
---@param base_row integer row offset for marks
---@return string[], pi.HighlightMark[]
function History:_build_startup_error_lines(base_row)
    local lines = {} ---@type string[]
    local marks = {} ---@type pi.HighlightMark[]
    for _, entry in ipairs(self._startup_errors) do
        if base_row + #lines > 0 then
            lines[#lines + 1] = ""
        end
        local icon = Config.options.labels.system_error
        local time_str = format_time(entry.timestamp)
        local time_sep = " "
        local label_line = icon .. time_sep .. time_str
        lines[#lines + 1] = label_line
        marks[#marks + 1] = {
            row = base_row + #lines - 1,
            col_start = 0,
            col_end = #icon,
            hl = "PiSystemErrorIcon",
        }
        marks[#marks + 1] = {
            row = base_row + #lines - 1,
            col_start = #icon + #time_sep,
            col_end = #label_line,
            hl = "PiMessageDateTime",
        }
        local error_lines = vim.split(entry.message, "\n", { plain = true })
        for _, line in ipairs(error_lines) do
            lines[#lines + 1] = line
            marks[#marks + 1] = {
                row = base_row + #lines - 1,
                col_start = 0,
                col_end = #line,
                hl = "PiStartupError",
            }
        end
    end
    return lines, marks
end

--- Write lines and highlight marks into the buffer, replacing the startup block region.
---@param lines string[]
---@param marks pi.HighlightMark[]
---@param scroll_to_bottom boolean
function History:_apply_startup_block(lines, marks, scroll_to_bottom)
    local start_row = 0
    local old_count = self._startup_block_line_count
    if old_count > 0 then
        vim.api.nvim_buf_clear_namespace(self._buf, ns, start_row, start_row + old_count)
    end
    self:_with_modifiable(function()
        if #lines == 0 then
            if old_count == 0 then
                return
            end
            local line_count = vim.api.nvim_buf_line_count(self._buf)
            if start_row == 0 and line_count == old_count then
                vim.api.nvim_buf_set_lines(self._buf, 0, old_count, false, { "" })
            else
                vim.api.nvim_buf_set_lines(self._buf, start_row, start_row + old_count, false, {})
            end
            return
        end

        if old_count > 0 then
            vim.api.nvim_buf_set_lines(self._buf, start_row, start_row + old_count, false, lines)
            return
        end

        local line_count = vim.api.nvim_buf_line_count(self._buf)
        local first = vim.api.nvim_buf_get_lines(self._buf, 0, 1, false)[1]
        if start_row == 0 and line_count == 1 and first == "" then
            vim.api.nvim_buf_set_lines(self._buf, 0, 1, false, lines)
        else
            vim.api.nvim_buf_set_lines(self._buf, start_row, start_row, false, lines)
        end
    end)

    self._startup_block_line_count = #lines
    for _, mark in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(self._buf, ns, start_row + mark.row, mark.col_start, {
            end_col = mark.col_end,
            hl_group = mark.hl,
            priority = STARTUP_HL_PRIORITY,
        })
    end
    self:_update_status_extmark()
    if scroll_to_bottom then
        self:_scroll_to_bottom()
    end
end

function History:_render_startup_block(scroll_to_bottom)
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return
    end

    -- Build and cache both views. Compact/expanded only differ when sections exist.
    if #self._startup_sections > 0 then
        self._startup_block_compact_lines, self._startup_block_compact_marks = self:_build_compact_startup()
        self._startup_block_expanded_lines, self._startup_block_expanded_marks = self:_build_expanded_startup()
    else
        self._startup_block_compact_lines = nil
        self._startup_block_compact_marks = nil
        self._startup_block_expanded_lines = nil
        self._startup_block_expanded_marks = nil
    end

    -- Pick active view. Always start with the welcome header.
    local lines, marks
    if self._startup_block_expanded and self._startup_block_expanded_lines then
        lines = vim.deepcopy(self._startup_block_expanded_lines)
        marks = vim.deepcopy(self._startup_block_expanded_marks)
    elseif self._startup_block_compact_lines then
        lines = vim.deepcopy(self._startup_block_compact_lines)
        marks = vim.deepcopy(self._startup_block_compact_marks)
    else
        lines, marks = self:_build_startup_header()
        if not self._startup_loaded then
            -- Still waiting for startup data — show loading hint.
            local loading = "     Loading resources…"
            lines[#lines + 1] = loading
            marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #loading, hl = "PiStartupHint" }
        end
    end

    -- Append startup errors after the startup block.
    if #self._startup_errors > 0 then
        local err_lines, err_marks = self:_build_startup_error_lines(#lines)
        vim.list_extend(lines, err_lines)
        vim.list_extend(marks, err_marks)
    end

    self:_apply_startup_block(lines, marks, scroll_to_bottom)
end

--- Toggle the startup block between compact and expanded.
--- With check_cursor=true (default), only toggles if the cursor is on the block.
--- With check_cursor=false, toggles unconditionally (for commands).
---@param check_cursor? boolean default true
---@return boolean toggled true if the block was toggled
function History:toggle_startup_block(check_cursor)
    if not self._startup_block_compact_lines or not self._startup_block_expanded_lines then
        return false
    end
    if check_cursor ~= false then
        local win = self:win()
        if not win then
            return false
        end
        local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1 -- 0-indexed
        local end_row = self._startup_block_line_count
        if cursor_row >= end_row then
            return false
        end
    end
    return self:_set_startup_block_expanded(not self._startup_block_expanded)
end

---@param expanded boolean
---@return boolean changed
function History:_set_startup_block_expanded(expanded)
    if self._startup_block_expanded == expanded then
        return false
    end
    self._startup_block_expanded = expanded
    if self._startup_block_compact_lines and self._startup_block_expanded_lines then
        self:_render_startup_block(false)
    end
    return true
end

---@param block pi.CompactionBlock
---@return string[], pi.HighlightMark[]
function History:_build_compaction_lines(block)
    local tokens = format_number(block.tokens_before)
    local icon = Config.options.labels.compaction
    local dashes = "──────"
    local header = dashes .. " " .. icon .. " compacted · " .. tokens .. " tokens " .. dashes
    local lines = { "", header } ---@type string[]
    local marks = {
        { row = 1, col_start = 0, col_end = #header, hl = "PiCompactionText" },
    } ---@type pi.HighlightMark[]

    if block.expanded then
        local summary_lines = vim.split(block.summary or "", "\n", { plain = true })
        for _, line in ipairs(summary_lines) do
            lines[#lines + 1] = "  " .. line
            marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #lines[#lines], hl = "PiCompactionText" }
        end
    else
        local hint = "  Tab to expand"
        lines[#lines + 1] = hint
        marks[#marks + 1] = { row = #lines - 1, col_start = 0, col_end = #hint, hl = "PiCompactionHint" }
    end

    return lines, marks
end

---@param start_row integer
---@param marks pi.HighlightMark[]
function History:_apply_compaction_marks(start_row, marks)
    for _, mark in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(self._buf, ns, start_row + mark.row, mark.col_start, {
            end_col = mark.col_end,
            hl_group = mark.hl,
            priority = STARTUP_HL_PRIORITY,
        })
    end
end

---@param block pi.CompactionBlock
function History:_replace_compaction_block(block)
    local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.anchor, {})
    local start_row = pos[1]
    if not start_row then
        return
    end

    local lines, marks = self:_build_compaction_lines(block)
    vim.api.nvim_buf_clear_namespace(self._buf, ns, start_row, start_row + block.line_count)
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, start_row, start_row + block.line_count, false, lines)
    end)
    block.line_count = #lines
    block.anchor = vim.api.nvim_buf_set_extmark(self._buf, ns, start_row, 0, {})
    self:_apply_compaction_marks(start_row, marks)
    self:_update_status_extmark()
    self:_maybe_scroll()
end

---@param summary string
---@param tokens_before integer
function History:_append_compaction_summary(summary, tokens_before)
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return
    end
    self:_begin_conversation_content()
    local block = {
        summary = summary,
        tokens_before = tokens_before,
        anchor = 0,
        line_count = 0,
        expanded = self._blocks_expanded,
    }
    local lines, marks = self:_build_compaction_lines(block)
    local start = self:_append_lines(lines)
    block.anchor = vim.api.nvim_buf_set_extmark(self._buf, ns, start, 0, {})
    block.line_count = #lines
    self._compaction_blocks[#self._compaction_blocks + 1] = block
    self:_apply_compaction_marks(start, marks)
    self:_scroll_to_bottom()
end

---@param summary string
---@param tokens_before integer
function History:append_compaction_summary(summary, tokens_before)
    self:_seal_stream_text()
    vim.schedule(function()
        self:_pop_text_batch()
        self:_append_compaction_summary(summary, tokens_before)
    end)
end

---@param block pi.CompactionBlock
---@param expanded boolean
---@return boolean changed
function History:_set_compaction_block_expanded(block, expanded)
    if block.expanded == expanded then
        return false
    end
    block.expanded = expanded
    self:_replace_compaction_block(block)
    return true
end

---@return boolean toggled
function History:toggle_compaction_block()
    local win = self:win()
    if not win then
        return false
    end
    local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1
    for _, block in ipairs(self._compaction_blocks) do
        local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.anchor, {})
        local start_row = pos[1]
        if start_row and cursor_row >= start_row and cursor_row < start_row + block.line_count then
            return self:_set_compaction_block_expanded(block, not block.expanded)
        end
    end
    return false
end

---@param error_message string
---@param opts? pi.ChatErrorOpts
function History:on_system_error(error_message, opts)
    self:_seal_stream_text()
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self:_pop_text_batch()
        local timestamp = now_ms()
        if not self._has_conversation_content then
            self._startup_errors[#self._startup_errors + 1] = {
                message = error_message,
                timestamp = timestamp,
            }
            if self._placeholder_mode == "loading" then
                self:clear_placeholder()
            end
            self:_render_startup_block(true)
            return
        end
        self:_append_system_error_block(error_message, timestamp, opts)
    end)
end

--- Render the welcome header with "Loading resources…" hint.
--- Used on initial chat show to provide feedback while startup data is being fetched.
function History:show_loading_startup()
    self:_render_startup_block(false)
end

---@param opts { sections: pi.StartupSection[], errors?: pi.SystemErrorEntry[] }
function History:show_startup_block(opts)
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return
    end
    self._startup_sections = self:_normalize_startup_sections(opts.sections)
    self._startup_loaded = true
    self._startup_errors = vim.deepcopy(opts.errors or {})
    if #self._startup_sections > 0 then
        self._startup_timestamp = self._startup_timestamp or now_ms()
    else
        self._startup_timestamp = nil
    end
    if not self._has_conversation_content and self._placeholder_mode == "loading" then
        self:clear_placeholder()
    end
    self:_render_startup_block(#self._startup_errors > 0 and not self._has_conversation_content)
end

--- Render a custom block inline in the history.
--- Each line is an array of chunks: { {text, hl?}, ... }.
---@param block pi.CustomBlock
function History:append_custom_block(block)
    self:_seal_stream_text()
    vim.schedule(function()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self:_pop_text_batch()
        if not block.content or #block.content == 0 then
            return
        end
        for _, line_chunks in ipairs(block.content) do
            -- Build the plain text for the buffer line
            local parts = {} ---@type string[]
            for _, chunk in ipairs(line_chunks) do
                parts[#parts + 1] = chunk[1] or ""
            end
            local text = table.concat(parts)
            local row = self:_append_lines({ text })

            -- Apply chunk highlights
            local col = 0
            for _, chunk in ipairs(line_chunks) do
                local chunk_text = chunk[1] or ""
                local hl = chunk[2]
                if hl and #chunk_text > 0 then
                    vim.api.nvim_buf_set_extmark(self._buf, ns, row, col, {
                        end_col = col + #chunk_text,
                        hl_group = hl,
                    })
                end
                col = col + #chunk_text
            end
        end
    end)
end

---@param tool_name string
---@param tool_call_id string
---@param tool_input? table
function History:on_tool_start(tool_name, tool_call_id, tool_input)
    if type(tool_call_id) == "string" then
        -- Set synchronously so live updates for this tool accumulate before
        -- this scheduled callback creates the block.
        self._tool_start_pending[tool_call_id] = true
    end
    self:_seal_stream_text()
    vim.schedule(function()
        self:_pop_text_batch() -- land pending text before the block
        if type(tool_call_id) == "string" then
            self._tool_start_pending[tool_call_id] = nil
        end
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self:_begin_conversation_content()
        self._needs_separator = false
        self._needs_breathing_line = false
        local icon = Tools.get_tool_icon(tool_name)
        local renderer = Tools.get_renderer(tool_name)

        -- Inline tools render as a single line: indent + icon + tool_name + detail
        if renderer.inline then
            local detail = renderer.inline_text and renderer.inline_text(tool_input) or nil
            local indent = Tools.GLYPHS.INDENT
            local line = indent .. icon .. " " .. tool_name .. (detail and ("  " .. detail) or "")

            -- Skip blank line between consecutive inline tools
            local need_gap = not self._last_was_inline
            local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
            local cur = vim.api.nvim_buf_get_lines(self._buf, last_line, last_line + 1, false)[1] or ""
            local lines = (cur == "" or not need_gap) and { line } or { "", line }
            local start = self:_append_lines(lines)
            local row = lines[1] == "" and start + 1 or start

            local icon_start = #indent
            local icon_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, row, icon_start, {
                end_col = icon_start + #icon,
                hl_group = "PiToolHeader",
            })
            -- Tool name
            local name_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, row, icon_start + #icon, {
                end_col = icon_start + #icon + 1 + #tool_name,
                hl_group = "PiToolHeader",
            })
            -- Detail (path etc.) in subdued color
            if detail then
                local detail_start = icon_start + #icon + 1 + #tool_name + 2
                vim.api.nvim_buf_set_extmark(self._buf, ns, row, detail_start, {
                    end_col = #line,
                    hl_group = "PiToolCall",
                })
            end

            if tool_call_id then
                self._tool_blocks[tool_call_id] = {
                    tool_name = tool_name,
                    icon_extmark = icon_extmark,
                    name_extmark = name_extmark,
                    tool_input = tool_input,
                    inline = true,
                }
            end

            self._last_was_inline = true
            self:_update_status_extmark()
            self:_maybe_scroll()
            return
        end

        self._last_was_inline = false

        -- Standard multi-line tool block
        local fold = Tools.GLYPHS.FOLD_OPEN
        local header = fold .. icon .. " " .. tool_name

        local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
        local cur = vim.api.nvim_buf_get_lines(self._buf, last_line, last_line + 1, false)[1] or ""
        -- Ensure exactly one blank line before block tool header
        local lines = cur == "" and { header } or { "", header }
        local start = self:_append_lines(lines)
        local header_row = lines[1] == "" and start + 1 or start
        Tools.set_line_bg(self, header_row)

        local icon_start = #fold
        -- Fold indicator highlight
        vim.api.nvim_buf_set_extmark(self._buf, ns, header_row, 0, {
            end_col = icon_start,
            hl_group = "PiToolBorder",
        })
        local icon_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, header_row, icon_start, {
            end_col = icon_start + #icon,
            hl_group = "PiToolHeader",
        })
        vim.api.nvim_buf_set_extmark(self._buf, ns, header_row, icon_start + #icon, {
            end_col = #header,
            hl_group = "PiToolHeader",
        })
        -- Spinner virtual text on header (removed on tool end)
        local spinner_virt = vim.api.nvim_buf_set_extmark(self._buf, ns, header_row, #header, {
            virt_text = { { "  " .. self._spinner_frames[self._spinner_index], "PiToolRunning" } },
            virt_text_pos = "inline",
        })

        if renderer.on_start then
            renderer.on_start(self, tool_input)
        end

        if tool_call_id then
            -- tail_extmark marks the last row of the block after on_start.
            -- on_tool_end uses it to insert output at the right position
            -- when multiple tools run in parallel.
            local tail_row = vim.api.nvim_buf_line_count(self._buf) - 1
            self._tool_blocks[tool_call_id] = {
                tool_name = tool_name,
                icon_extmark = icon_extmark,
                spinner_extmark = spinner_virt,
                tail_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, tail_row, 0, {}),
                tool_input = tool_input,
                expanded = true,
            }
        end
        -- Live updates that arrived before the block existed land now.
        self:_flush_tool_updates()
    end)
end

---@param tool_name string
---@param tool_call_id string
---@param result? table
---@param is_error? boolean
function History:on_tool_end(tool_name, tool_call_id, result, is_error)
    self:_seal_stream_text()
    vim.schedule(function()
        self:_pop_text_batch() -- land pending text before closing the block
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self:_flush_tool_updates() -- latest live update lands before teardown

        local should_scroll = self:_should_auto_scroll()

        local block = tool_call_id and self._tool_blocks[tool_call_id]

        -- Guard: skip if this tool already finished (race between
        -- tool_execution_end and mark_pending_tools_errored, both scheduled).
        if block and block.finished then
            return
        end
        if block then
            block.finished = true
            self:_delete_tool_live_update(block)
            -- Remove spinner virtual text from header
            if block.spinner_extmark then
                pcall(vim.api.nvim_buf_del_extmark, self._buf, ns, block.spinner_extmark)
                block.spinner_extmark = nil
            end
        end

        -- Inline tools: append status indicator to the existing line
        if block and block.inline then
            local labels = Config.options.labels
            local status = Tools.resolve_status(result, is_error)
            local is_success = status == "completed"
            -- Keep completed inline tools highlighted; errors stay loud
            local icon_hl = is_success and "PiToolHeader" or "PiToolError"
            local status_icon = is_success and labels.tool_success or labels.tool_failure
            local status_hl = is_success and "PiToolStatus" or "PiToolError"

            -- Update icon + name color
            local icon = Tools.get_tool_icon(tool_name)
            local indent = Tools.GLYPHS.INDENT
            local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.icon_extmark, {})
            if not pos[1] then
                return
            end
            vim.api.nvim_buf_set_extmark(self._buf, ns, pos[1], #indent, {
                id = block.icon_extmark,
                end_col = #indent + #icon,
                hl_group = icon_hl,
            })
            -- Fade tool name too
            if block.name_extmark then
                local name_pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.name_extmark, {})
                if name_pos[1] then
                    local name_end = #indent + #icon + 1 + #tool_name
                    vim.api.nvim_buf_set_extmark(self._buf, ns, name_pos[1], #indent + #icon, {
                        id = block.name_extmark,
                        end_col = name_end,
                        hl_group = icon_hl,
                    })
                end
            end

            -- Append status as virtual text at end of line (silent on success)
            local renderer = Tools.get_renderer(tool_name)
            local extra = renderer.inline_status and renderer.inline_status(result, is_error) or nil
            local row = pos[1]
            local line = vim.api.nvim_buf_get_lines(self._buf, row, row + 1, false)[1] or ""
            local virt = {}
            if extra then
                virt[#virt + 1] = { " " .. extra, "PiToolStatus" }
            end
            if not is_success then
                virt[#virt + 1] = { "  " .. status_icon, status_hl }
            end
            if #virt > 0 then
                vim.api.nvim_buf_set_extmark(self._buf, ns, row, #line, {
                    virt_text = virt,
                    virt_text_pos = "inline",
                })
            end

            self._needs_breathing_line = true
            self:_update_status_extmark()
            if should_scroll then
                self:_scroll_to_bottom()
            end
            return
        end

        -- Compute insertion point: after the tool block's on_start content.
        -- When tools run in parallel, multiple headers are appended before
        -- any on_tool_end fires, so we must insert output at the correct
        -- position rather than appending at the buffer end.
        local insert_at ---@type integer?
        if block and block.tail_extmark then
            local tail_pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.tail_extmark, {})
            if tail_pos[1] then
                insert_at = tail_pos[1] + 1
            end
        end

        local output_start = insert_at or vim.api.nvim_buf_line_count(self._buf)

        local renderer = Tools.get_renderer(tool_name)
        if renderer.on_end then
            insert_at = renderer.on_end(self, block and block.tool_input, result, is_error, insert_at)
        end

        -- Mark the first output line (if renderer.on_end added anything)
        local output_end = insert_at or vim.api.nvim_buf_line_count(self._buf)
        if block and output_end > output_start then
            block.output_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, output_start, 0, {})
        end

        local labels = Config.options.labels
        local status = Tools.resolve_status(result, is_error)
        local is_success = status == "completed"
        -- Silent success: blank line as structural end marker + breathing room.
        -- Error: indented error text, no border.
        local footer = is_success and "" or (Tools.GLYPHS.INDENT .. labels.tool_failure .. " " .. status)
        local footer_hl = is_success and "PiToolStatus" or "PiToolError"
        local start
        if insert_at then
            start, insert_at = self:_insert_lines(insert_at, { footer })
        else
            start = self:_append_lines({ footer })
        end
        local footer_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, start, 0, {
            end_col = #footer,
            hl_group = footer_hl,
            line_hl_group = "PiToolBody",
        })

        if block then
            local icon_hl = is_success and "PiToolHeader" or "PiToolError"
            local icon = Tools.get_tool_icon(tool_name)
            local fold = Tools.GLYPHS.FOLD_OPEN
            local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.icon_extmark, {})
            if pos[1] then
                vim.api.nvim_buf_set_extmark(self._buf, ns, pos[1], #fold, {
                    id = block.icon_extmark,
                    end_col = #fold + #icon,
                    hl_group = icon_hl,
                })
            end
            block.end_extmark = footer_extmark
            block.end_hl_group = footer_hl
            block.expanded = true
            self:_maybe_collapse_tool(tool_call_id)
        end

        self._needs_breathing_line = true

        if should_scroll then
            self:_scroll_to_bottom()
        end
    end)
end

--- Collapse a tool block based on per-renderer visible line thresholds.
---@param tool_call_id string
function History:_maybe_collapse_tool(tool_call_id)
    local block = self._tool_blocks[tool_call_id]
    if not block or not block.end_extmark then
        return
    end

    local header_pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.icon_extmark, {})
    local footer_pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.end_extmark, {})
    local header_row = header_pos[1]
    local footer_row = footer_pos[1]
    if not header_row or not footer_row then
        return
    end
    local inner_start = header_row + 1

    local renderer = Tools.get_renderer(block.tool_name)
    local input_vis = renderer.input_visible or math.huge
    local output_vis = renderer.output_visible or math.huge

    local input_lines, output_lines, has_output = Tools.extract_tool_sections(self, block)
    -- Subtract indent width so truncation accounts for body line prefix
    local win_width = self._win and vim.api.nvim_win_is_valid(self._win) and vim.api.nvim_win_get_width(self._win) or 0
    local indent_w = vim.fn.strdisplaywidth(Tools.GLYPHS.INDENT)
    local gutters = (self._win and vim.wo[self._win].foldcolumn or "0")
    local gutter_w = tonumber(gutters) or 0
    local max_width = win_width > 0 and (win_width - indent_w - gutter_w) or 0
    if not Tools.should_collapse(input_lines, output_lines, input_vis, output_vis, max_width) then
        return
    end
    local collapsed, specs =
        Tools.build_collapsed_view(input_lines, output_lines, has_output, input_vis, output_vis, max_width)

    -- Save expanded state
    block.expanded_inner_lines = vim.api.nvim_buf_get_lines(self._buf, inner_start, footer_row, false)
    block.expanded_inner_extmarks = capture_extmarks(self._buf, ns, inner_start, footer_row - 1)
    block.collapsed_inner_lines = collapsed
    block.collapsed_specs = specs

    if self._blocks_expanded then
        block.expanded = true
        return
    end

    -- Replace inner content
    vim.api.nvim_buf_clear_namespace(self._buf, ns, inner_start, footer_row)
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, inner_start, footer_row, false, collapsed)
    end)
    Tools.apply_collapsed_extmarks(self, inner_start, specs, collapsed)
    reanchor_end_extmark(self, block, inner_start + #collapsed)

    block.expanded = false
    -- Update fold indicator on header
    self:_with_modifiable(function()
        local line = vim.api.nvim_buf_get_lines(self._buf, header_row, header_row + 1, false)[1] or ""
        if line:sub(1, #Tools.GLYPHS.FOLD_OPEN) == Tools.GLYPHS.FOLD_OPEN then
            vim.api.nvim_buf_set_text(
                self._buf,
                header_row,
                0,
                header_row,
                #Tools.GLYPHS.FOLD_OPEN,
                { Tools.GLYPHS.FOLD_CLOSE }
            )
        end
    end)
end

---@param target_block pi.ToolBlock
---@param expanded boolean
---@return boolean changed true if a tool block was changed
function History:_set_tool_block_expanded(target_block, expanded)
    if not target_block.end_extmark or not target_block.collapsed_inner_lines then
        return false
    end
    if target_block.expanded == expanded then
        return false
    end

    local header_row = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, target_block.icon_extmark, {})[1]
    local footer_row = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, target_block.end_extmark, {})[1]
    if not header_row or not footer_row then
        return false
    end
    local inner_start = header_row + 1

    vim.api.nvim_buf_clear_namespace(self._buf, ns, inner_start, footer_row)
    self:_with_modifiable(function()
        if expanded then
            vim.api.nvim_buf_set_lines(self._buf, inner_start, footer_row, false, target_block.expanded_inner_lines)
            restore_extmarks(self._buf, ns, inner_start, target_block.expanded_inner_extmarks)
        else
            vim.api.nvim_buf_set_lines(self._buf, inner_start, footer_row, false, target_block.collapsed_inner_lines)
            Tools.apply_collapsed_extmarks(
                self,
                inner_start,
                target_block.collapsed_specs,
                target_block.collapsed_inner_lines
            )
        end
    end)
    local written = expanded and target_block.expanded_inner_lines or target_block.collapsed_inner_lines
    reanchor_end_extmark(self, target_block, inner_start + #written)
    target_block.expanded = expanded
    -- Toggle fold indicator on header line
    self:_with_modifiable(function()
        local line = vim.api.nvim_buf_get_lines(self._buf, header_row, header_row + 1, false)[1] or ""
        local new_fold = expanded and Tools.GLYPHS.FOLD_OPEN or Tools.GLYPHS.FOLD_CLOSE
        local old_fold = expanded and Tools.GLYPHS.FOLD_CLOSE or Tools.GLYPHS.FOLD_OPEN
        if line:sub(1, #old_fold) == old_fold then
            vim.api.nvim_buf_set_text(self._buf, header_row, 0, header_row, #old_fold, { new_fold })
        end
    end)
    return true
end

--- Toggle expand/collapse for the tool block under the cursor.
---@return boolean toggled true if a tool block was toggled
function History:toggle_tool_block()
    local win = self:win()
    if not win then
        return false
    end
    local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1 -- 0-indexed

    -- Find the block containing the cursor
    for _, block in pairs(self._tool_blocks) do
        if block.end_extmark and block.collapsed_inner_lines then
            local h = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.icon_extmark, {})[1]
            local f = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.end_extmark, {})[1]
            if h and f and cursor_row >= h and cursor_row <= f then
                return self:_set_tool_block_expanded(block, not block.expanded)
            end
        end
    end

    return false
end

---@return boolean expanded true when all currently toggleable blocks are expanded
function History:_all_blocks_expanded()
    local saw_block = false

    if self._startup_block_compact_lines and self._startup_block_expanded_lines then
        saw_block = true
        if not self._startup_block_expanded then
            return false
        end
    end

    for _, block in ipairs(self._compaction_blocks) do
        saw_block = true
        if not block.expanded then
            return false
        end
    end

    for _, block in pairs(self._tool_blocks) do
        if block.end_extmark and block.collapsed_inner_lines then
            saw_block = true
            if not block.expanded then
                return false
            end
        end
    end

    for _, block in ipairs(self._thinking_blocks) do
        if block.visible then
            saw_block = true
            if not block.expanded then
                return false
            end
        end
    end

    return saw_block and true or self._blocks_expanded
end

--- Set the global expanded state for history blocks.
---@param expanded boolean
---@return boolean changed true if any block state changed
function History:set_blocks_expanded(expanded)
    self._blocks_expanded = expanded
    local changed = self:_set_startup_block_expanded(expanded)

    for _, block in ipairs(self._compaction_blocks) do
        changed = self:_set_compaction_block_expanded(block, expanded) or changed
    end

    for _, block in pairs(self._tool_blocks) do
        changed = self:_set_tool_block_expanded(block, expanded) or changed
    end

    for _, block in ipairs(self._thinking_blocks) do
        if block.visible and block.expanded ~= expanded then
            -- Use the same toggle logic as toggle_thinking_block
            local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.anchor, {})
            local anchor_row = pos[1]
            if anchor_row then
                if expanded then
                    -- Expand
                    if block.virt_id then
                        pcall(vim.api.nvim_buf_del_extmark, self._buf, ns, block.virt_id)
                        block.virt_id = nil
                    end
                    local block_lines = self:_build_thinking_block(block.header, block.lines)
                    self:_with_modifiable(function()
                        vim.api.nvim_buf_set_lines(
                            self._buf,
                            anchor_row,
                            anchor_row + block.line_count,
                            false,
                            block_lines
                        )
                    end)
                    self:_apply_thinking_hl(anchor_row + 1, #block_lines - 2)
                    block.line_count = #block_lines
                    block.expanded = true
                    changed = true
                else
                    -- Collapse
                    local label = Config.options.labels.thinking
                    local header_text = label .. " " .. block.header
                    self:_with_modifiable(function()
                        vim.api.nvim_buf_set_lines(
                            self._buf,
                            anchor_row,
                            anchor_row + block.line_count,
                            false,
                            { "", header_text }
                        )
                    end)
                    self:_apply_thinking_hl(anchor_row + 1, 1)
                    local flat = Text.thinking_flat(block.lines)
                    local pw = self:_thinking_preview_width(header_text)
                    block.virt_id =
                        self:_set_thinking_preview(anchor_row + 1, Text.thinking_head(flat, pw), block.virt_id)
                    block.line_count = 2
                    block.expanded = false
                    changed = true
                end
            end
        end
    end

    return changed
end

--- Toggle the global expanded state for history blocks.
---@return boolean changed true if any block state changed
function History:toggle_blocks_expanded()
    return self:set_blocks_expanded(not self:_all_blocks_expanded())
end

---@param msg table?
---@return string?
local function extract_tool_update_text(msg)
    local partial = msg and msg.partialResult
    local content = partial and partial.content
    if type(content) == "string" then
        local trimmed = vim.trim(Tools.sanitize_text(content))
        return trimmed ~= "" and trimmed or nil
    end
    if type(content) ~= "table" then
        return nil
    end
    local parts = {}
    for _, item in ipairs(content) do
        if type(item) == "table" and item.type == "text" and type(item.text) == "string" then
            parts[#parts + 1] = Tools.sanitize_text(item.text)
        elseif type(item) == "string" then
            parts[#parts + 1] = Tools.sanitize_text(item)
        end
    end
    if #parts == 0 then
        return nil
    end
    local trimmed = vim.trim(table.concat(parts, "\n"))
    return trimmed ~= "" and trimmed or nil
end

---@param text string
---@return string[]
local function build_tool_live_update_lines(text)
    local output_lines = vim.split(Tools.sanitize_text(text), "\n", { plain = true })
    local fences = 0
    for _, line in ipairs(output_lines) do
        if line:match("^```") then
            fences = fences + 1
        end
    end
    if fences % 2 == 1 then
        output_lines[#output_lines + 1] = "```"
    end

    local lines = { "" }
    vim.list_extend(lines, output_lines)
    return lines
end

---@param start_row integer
---@param lines string[]
function History:_apply_tool_live_update_extmarks(start_row, lines)
    Tools.set_border(self, start_row, Tools.GLYPHS.INDENT)
    for i = 2, #lines do
        local row = start_row + i - 1
        Tools.set_border(self, row, Tools.GLYPHS.INDENT)
        local line = lines[i] or ""
        if #line > 0 then
            vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
                end_col = #line,
                hl_group = "PiToolOutput",
                priority = 200,
            })
        end
    end
end

---@param block pi.ToolBlock
function History:_delete_tool_live_update(block)
    if not block.live_update_extmark or not block.live_update_line_count then
        return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.live_update_extmark, {})
    block.live_update_extmark = nil
    local line_count = block.live_update_line_count
    block.live_update_line_count = nil
    local start_row = pos[1]
    if not start_row then
        return
    end
    local end_row = start_row + line_count
    if end_row > vim.api.nvim_buf_line_count(self._buf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(self._buf, ns, start_row, end_row)
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, start_row, end_row, false, {})
    end)
end

---@param tool_name string
---@param tool_call_id string
---@param msg table
function History:on_tool_update(tool_name, tool_call_id, msg)
    if type(tool_call_id) ~= "string" then
        return
    end
    if not self._tool_blocks[tool_call_id] and not self._tool_start_pending[tool_call_id] then
        return
    end
    -- Latest update wins: intermediate partial outputs are superseded.
    self._pending_tool_updates[tool_call_id] = msg
    self:_ensure_stream_timer()
end

--- Apply the latest coalesced live update for a tool block.
---@param tool_call_id string
---@param msg table
function History:_apply_tool_update(tool_call_id, msg)
    local block = self._tool_blocks[tool_call_id]
    if not block or block.finished or block.inline then
        return
    end

    local text = extract_tool_update_text(msg)
    if not text then
        return
    end

    local should_scroll = self:_should_auto_scroll()
    local lines = build_tool_live_update_lines(text)
    local start_row
    local old_line_count = block.live_update_line_count
    if block.live_update_extmark and old_line_count then
        local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.live_update_extmark, {})
        start_row = pos[1]
        if start_row then
            local end_row = start_row + old_line_count
            if end_row > vim.api.nvim_buf_line_count(self._buf) then
                return
            end
            vim.api.nvim_buf_clear_namespace(self._buf, ns, start_row, end_row)
            self:_with_modifiable(function()
                vim.api.nvim_buf_set_lines(self._buf, start_row, end_row, false, lines)
            end)
        else
            block.live_update_extmark = nil
            block.live_update_line_count = nil
        end
    end

    if not start_row then
        if not block.tail_extmark then
            return
        end
        local tail_pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.tail_extmark, {})
        if not tail_pos[1] then
            return
        end
        start_row = tail_pos[1] + 1
        self:_with_modifiable(function()
            vim.api.nvim_buf_set_lines(self._buf, start_row, start_row, false, lines)
        end)
    end

    block.live_update_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, start_row, 0, {})
    block.live_update_line_count = #lines
    self:_apply_tool_live_update_extmarks(start_row, lines)
    self:_update_status_extmark()
    if should_scroll then
        self:_scroll_to_bottom()
    end
end

--- Mark all pending (unfinished) tool blocks as errored.
--- Called on message_end when the assistant message was aborted or errored,
--- mirroring TUI behaviour that closes out hanging tool blocks.
---@param error_message string
function History:mark_pending_tools_errored(error_message)
    ---@type { id: string, name: string }[]
    local pending = {}
    for id, block in pairs(self._tool_blocks) do
        if not block.finished then
            pending[#pending + 1] = { id = id, name = block.tool_name }
        end
    end
    if #pending == 0 then
        return
    end
    local error_result = { content = { { type = "text", text = error_message } } }
    for _, p in ipairs(pending) do
        self:on_tool_end(p.name, p.id, error_result, true)
    end
end

-- ---------------------------------------------------------------------------
-- Direct bash execution blocks (! commands, RPC `bash`)
-- ---------------------------------------------------------------------------

--- Display cap for streamed bash output, mirroring the TUI's DEFAULT_MAX_LINES.
--- Once hit, rendering stops (with a note) until the final response replaces
--- the region with the backend-truncated tail.
local BASH_DISPLAY_MAX = 2000

---@class pi.BashBlock
---@field id string
---@field command string
---@field exclude_from_context boolean
---@field header_extmark integer header row anchor
---@field inner_offset integer lines from header to first output row (header + command body)
---@field spinner_extmark integer?
---@field end_extmark integer footer row anchor (trails the last output row)
---@field partial string unflushed incomplete output line
---@field partial_rendered boolean partial is currently rendered as a line
---@field rendered_lines integer completed output lines rendered so far
---@field display_capped boolean display cap hit; rendering paused
---@field finished boolean

--- Insert output lines into a bash block just before its footer marker.
---@param block pi.BashBlock
---@param lines string[]
---@param hl_group? string
function History:_bash_insert_output(block, lines, hl_group)
    local footer_pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.end_extmark, {})
    if not footer_pos[1] then
        return
    end
    local row = footer_pos[1]
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, row, row, false, lines)
    end)
    hl_group = hl_group or "PiBashOutput"
    for i, line in ipairs(lines) do
        local r = row + i - 1
        Tools.set_border(self, r, Tools.GLYPHS.INDENT)
        if #line > 0 then
            vim.api.nvim_buf_set_extmark(self._buf, ns, r, 0, {
                end_col = #line,
                hl_group = hl_group,
                priority = 200,
            })
        end
    end
end

--- Delete the rendered partial line (if any) from a bash block.
---@param block pi.BashBlock
function History:_bash_clear_partial(block)
    if not block.partial_rendered then
        return
    end
    block.partial_rendered = false
    local footer_pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.end_extmark, {})
    if not footer_pos[1] or footer_pos[1] == 0 then
        return
    end
    local row = footer_pos[1] - 1
    vim.api.nvim_buf_clear_namespace(self._buf, ns, row, row + 1)
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, row, row + 1, false, {})
    end)
end

--- Render the header of a direct bash execution block and register the block.
---@param id string
---@param command string
---@param exclude_from_context? boolean
function History:on_bash_start(id, command, exclude_from_context)
    -- Set synchronously so streamed output for this block accumulates before
    -- this scheduled callback creates the block.
    self._bash_start_pending[id] = true
    self:_seal_stream_text()
    vim.schedule(function()
        -- Land pending text before the block. Queued output survives: it
        -- drains after the block exists (below), while the flag is still set.
        self:_pop_text_batch()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            self._bash_start_pending[id] = nil
            return
        end
        self:_begin_conversation_content()
        self._needs_separator = false
        self._needs_breathing_line = false
        self._last_was_inline = false

        local fold = Tools.GLYPHS.FOLD_OPEN
        local cmd_lines = vim.split(Tools.sanitize_text(command), "\n", { plain = true })
        local header = fold .. "$ " .. cmd_lines[1]

        local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
        local cur = vim.api.nvim_buf_get_lines(self._buf, last_line, last_line + 1, false)[1] or ""
        -- Ensure exactly one blank line before the block header
        local lines = cur == "" and { header } or { "", header }
        local start = self:_append_lines(lines)
        local header_row = lines[1] == "" and start + 1 or start
        Tools.set_line_bg(self, header_row)

        vim.api.nvim_buf_set_extmark(self._buf, ns, header_row, 0, {
            end_col = #fold,
            hl_group = "PiToolBorder",
        })
        -- Excluded-from-context commands (!!) render dim, like the TUI's dim
        -- border. PiToolCall is the main body level now (normal text color), so
        -- the dim header borrows the border group instead to stay receded.
        local header_hl = exclude_from_context and "PiToolBorder" or "PiBashHeader"
        vim.api.nvim_buf_set_extmark(self._buf, ns, header_row, #fold, {
            end_col = #header,
            hl_group = header_hl,
        })
        local spinner_virt = vim.api.nvim_buf_set_extmark(self._buf, ns, header_row, #header, {
            virt_text = { { "  " .. self._spinner_frames[self._spinner_index], "PiToolRunning" } },
            virt_text_pos = "inline",
        })

        -- Multi-line commands: remaining lines render as indented input body.
        for i = 2, #cmd_lines do
            local row = self:_append_lines({ cmd_lines[i] })
            Tools.set_border(self, row, Tools.GLYPHS.INDENT)
            if #cmd_lines[i] > 0 then
                vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
                    end_col = #cmd_lines[i],
                    hl_group = "PiToolCall",
                })
            end
        end

        -- Footer placeholder line: output grows above it. The end_extmark
        -- trails the last output row (inserts happen at its row, pushing it
        -- down). The output start is derived from the header anchor plus the
        -- fixed command-body offset, since plain row anchors move with the
        -- footer on line insertion regardless of gravity.
        local footer_row = self:_append_lines({ "" })
        ---@type pi.BashBlock
        self._bash_blocks[id] = {
            id = id,
            command = command,
            exclude_from_context = exclude_from_context == true,
            header_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, header_row, 0, {}),
            inner_offset = #cmd_lines,
            spinner_extmark = spinner_virt,
            end_extmark = vim.api.nvim_buf_set_extmark(
                self._buf,
                ns,
                footer_row,
                0,
                { right_gravity = true, line_hl_group = "PiToolBody" }
            ),
            partial = "",
            partial_rendered = false,
            rendered_lines = 0,
            display_capped = false,
            finished = false,
        }

        -- Output that streamed in before the block existed lands now.
        self:_flush_stream_bash()
        self._bash_start_pending[id] = nil
        self:_update_status_extmark()
        self:_maybe_scroll()
    end)
end

--- Append a streamed output chunk to a bash block. Chunks accumulate and
--- are coalesced into one flush (see the stream flush machinery above); an
--- incomplete trailing line is kept as `partial` and rendered as a live line
--- until the next chunk completes it (TUI behavior).
---@param id string
---@param delta string
function History:on_bash_output(id, delta)
    if delta == "" then
        return
    end
    local block = self._bash_blocks[id]
    if (not block or block.finished) and not self._bash_start_pending[id] then
        return
    end
    local chunks = self._pending_bash[id]
    if chunks then
        chunks[#chunks + 1] = delta
    else
        self._pending_bash[id] = { delta }
    end
    self:_ensure_stream_timer()
end

--- Render a coalesced output chunk into a bash block.
---@param block pi.BashBlock
---@param delta string
function History:_apply_bash_output(block, delta)
    local clean = Tools.sanitize_text(delta):gsub("\r\n", "\n"):gsub("\r", "\n")
    local chunk_lines = vim.split(clean, "\n", { plain = true })

    -- Join the first piece onto the pending partial; the last piece is the
    -- new partial. Everything in between is a completed line.
    block.partial = block.partial .. chunk_lines[1]
    local completed = {} ---@type string[]
    if #chunk_lines > 1 then
        completed[1] = block.partial
        for i = 2, #chunk_lines - 1 do
            completed[#completed + 1] = chunk_lines[i]
        end
        block.partial = chunk_lines[#chunk_lines]
    end

    local should_scroll = self:_should_auto_scroll()

    self:_bash_clear_partial(block)

    if #completed > 0 and not block.display_capped then
        local room = BASH_DISPLAY_MAX - block.rendered_lines
        if #completed > room then
            if room > 0 then
                local head = {}
                for i = 1, room do
                    head[i] = completed[i]
                end
                self:_bash_insert_output(block, head)
                block.rendered_lines = block.rendered_lines + room
            end
            block.display_capped = true
            self:_bash_insert_output(
                block,
                { "… output truncated in chat (showing first " .. BASH_DISPLAY_MAX .. " lines)" },
                "PiWarning"
            )
        else
            self:_bash_insert_output(block, completed)
            block.rendered_lines = block.rendered_lines + #completed
        end
    end

    if block.partial ~= "" and not block.display_capped then
        self:_bash_insert_output(block, { block.partial })
        block.partial_rendered = true
    end

    self:_update_status_extmark()
    if should_scroll then
        self:_scroll_to_bottom()
    end
end

--- Replace a bash block's output region with the final (backend-truncated)
--- output and render status lines. Called from on_bash_end when the response
--- carries authoritative output (truncated runs, display cap hit).
---@param block pi.BashBlock
---@param output string
---@param status_lines { text: string, hl: string }[]
function History:_bash_finalize_output(block, output, status_lines)
    local header_pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.header_extmark, {})
    local end_pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.end_extmark, {})
    if not header_pos[1] or not end_pos[1] then
        return
    end
    local start_row, footer_row = header_pos[1] + block.inner_offset, end_pos[1]
    if start_row > footer_row then
        return
    end

    local out_lines = vim.split(Tools.sanitize_text(output), "\n", { plain = true })
    -- Drop a single trailing empty line (commands usually end with \n).
    if #out_lines > 1 and out_lines[#out_lines] == "" then
        out_lines[#out_lines] = nil
    end

    local final = {} ---@type string[]
    for _, line in ipairs(out_lines) do
        final[#final + 1] = line
    end
    for _, status in ipairs(status_lines) do
        final[#final + 1] = status.text
    end

    vim.api.nvim_buf_clear_namespace(self._buf, ns, start_row, footer_row)
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, start_row, footer_row, false, final)
    end)
    local status_start = #final - #status_lines + 1
    for i, line in ipairs(final) do
        local row = start_row + i - 1
        Tools.set_border(self, row, Tools.GLYPHS.INDENT)
        if #line > 0 then
            local hl = i >= status_start and status_lines[i - status_start + 1].hl or "PiBashOutput"
            vim.api.nvim_buf_set_extmark(self._buf, ns, row, 0, {
                end_col = #line,
                hl_group = hl,
                priority = 200,
            })
        end
    end
    block.partial_rendered = false
end

--- Complete a bash block: stop the spinner, apply authoritative output when
--- the run was truncated (or the display cap was hit), and render status.
--- `result` is the RPC BashResult (output/exitCode/cancelled/truncated/
--- fullOutputPath) or `{ error = "..." }` when the RPC call itself failed.
---@param id string
---@param result table
function History:on_bash_end(id, result)
    self:_seal_stream_text()
    vim.schedule(function()
        self:_pop_text_batch()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self:_flush_stream_bash() -- land pending output before finalizing
        local block = self._bash_blocks[id]
        if not block or block.finished then
            return
        end
        block.finished = true

        local should_scroll = self:_should_auto_scroll()

        if block.spinner_extmark then
            pcall(vim.api.nvim_buf_del_extmark, self._buf, ns, block.spinner_extmark)
            block.spinner_extmark = nil
        end

        local exit_code = result.exitCode
        local cancelled = result.cancelled == true
        local truncated = result.truncated == true
        local rpc_error = type(result.error) == "string" and result.error or nil

        -- Status lines rendered inside the output region (TUI shows them
        -- below the output, inside the block).
        local status_lines = {} ---@type { text: string, hl: string }[]
        if rpc_error then
            status_lines[#status_lines + 1] = { text = rpc_error, hl = "PiToolError" }
        end
        if truncated then
            local warn = "Output truncated."
            if type(result.fullOutputPath) == "string" and result.fullOutputPath ~= "" then
                warn = warn .. " Full output: " .. result.fullOutputPath
            end
            status_lines[#status_lines + 1] = { text = warn, hl = "PiWarning" }
        end
        if cancelled then
            status_lines[#status_lines + 1] = { text = "(cancelled)", hl = "PiWarning" }
        elseif type(exit_code) == "number" and exit_code ~= 0 then
            status_lines[#status_lines + 1] = { text = "(exit " .. exit_code .. ")", hl = "PiToolError" }
        end

        local output = type(result.output) == "string" and result.output or nil
        if output and (truncated or block.display_capped or rpc_error) then
            -- Authoritative backend output replaces the streamed region (this
            -- also drops the in-flight cap note and any stale partial).
            self:_bash_finalize_output(block, output, status_lines)
            status_lines = {}
        else
            -- Keep streamed lines; drop a dangling partial only when the
            -- response disagrees with it (rpc error path).
            if rpc_error then
                self:_bash_clear_partial(block)
            end
            for _, status in ipairs(status_lines) do
                self:_bash_insert_output(block, { status.text }, status.hl)
            end
        end

        self._needs_breathing_line = true
        self:_update_status_extmark()
        if should_scroll then
            self:_scroll_to_bottom()
        end
    end)
end

--- Render a completed bash execution from session replay (bashExecution msg).
---@param msg table
function History:on_bash_replay(msg)
    self._bash_replay_counter = self._bash_replay_counter + 1
    local id = "replay:bash:" .. self._bash_replay_counter
    local command = type(msg.command) == "string" and msg.command or ""
    self:on_bash_start(id, command, msg.excludeFromContext == true)
    local output = type(msg.output) == "string" and msg.output or ""
    if output ~= "" then
        self:on_bash_output(id, output)
    end
    self:on_bash_end(id, {
        output = output,
        exitCode = msg.exitCode,
        cancelled = msg.cancelled == true,
        truncated = msg.truncated == true,
        fullOutputPath = msg.fullOutputPath,
    })
end

function History:on_thinking_start()
    -- Set synchronously so thinking deltas accumulate (and on_thinking_end's
    -- fast path stays correct) before this scheduled callback runs.
    self._thinking_requested = true
    self:_seal_stream_text()
    vim.schedule(function()
        self._thinking_requested = nil
        -- Land pending text before anchoring the block relative to the last line.
        self:_pop_text_batch()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        self._is_thinking = true
        self:_emit_status()
        local label = Config.options.labels.thinking
        local last_line = vim.api.nvim_buf_line_count(self._buf) - 1
        local last_text = vim.api.nvim_buf_get_lines(self._buf, last_line, last_line + 1, false)[1] or ""
        -- The thinking block is placed as [blank breathing line, header]. Anchor
        -- it after all existing content so it renders in stream order. Normally
        -- the buffer ends with a blank breathing line, so anchor there and insert
        -- before it (that blank then stays after the header). Inline tools (and
        -- any content that doesn't end in a blank) leave the last line as real
        -- content; anchoring there would insert the block *before* that content
        -- and push it down, reordering the turn (thinking rendered before the
        -- tool). Anchor just past the last line in that case so the block lands
        -- at the end, where it belongs.
        local anchor_row = last_text == "" and last_line or (last_line + 1)
        local anchor = vim.api.nvim_buf_set_extmark(self._buf, ns, anchor_row, 0, {
            right_gravity = false,
        })
        self._thinking_accum = {
            lines = { "" },
            anchor = anchor,
            start_time = vim.uv.hrtime() / 1e9,
            buf_lines = 0,
        }
        if self._show_thinking then
            -- Single-line presentation: a blank breathing line + one header line.
            -- The streaming preview is drawn as end-of-line virtual text on the
            -- header (a rolling tail window), so thinking never grows vertically.
            local header_text = label .. " Thinking…"
            local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, anchor, {})
            local row = pos[1]
            -- Trailing margin: leave exactly one blank line after the header
            -- and set the breathing-line flag, mirroring how a tool block ends
            -- (blank footer + _needs_breathing_line). The next text delta then
            -- prepends a newline (_render_text_deltas) so exactly one blank of
            -- separation remains, while a following tool/bash block sees the
            -- blank last line and adds none of its own. Previously the block
            -- left two blanks and relied on the next text delta reusing one; a
            -- following tool block reused none, leaving a two-line gap (#48).
            -- When the buffer already ended in a breathing blank, that blank is
            -- the one trailing line (insert none); after real content (e.g. an
            -- inline tool) we insert it.
            local margin = last_text == "" and 0 or 1
            local block = { "", header_text }
            for _ = 1, margin do
                block[#block + 1] = ""
            end
            self:_with_modifiable(function()
                vim.api.nvim_buf_set_lines(self._buf, row, row, false, block)
            end)
            self:_apply_thinking_hl(row + 1, 1)
            self._needs_breathing_line = true
            self._thinking_accum.buf_lines = 2
            self._thinking_accum.header_text = header_text
        end
        -- Deltas that arrived before the accumulator existed land now.
        self:_flush_stream_thinking()
        self:_update_status_extmark()
        self:_maybe_scroll()
    end)
end

---@param delta string
function History:on_thinking_delta(delta)
    -- Accumulate only when a thinking block exists or is about to be created
    -- (mirrors the old early-return inside the scheduled callback).
    if not self._thinking_accum and not self._thinking_requested then
        return
    end
    local pending = self._pending_thinking
    if pending then
        pending[#pending + 1] = delta
    else
        self._pending_thinking = { delta }
    end
    self:_ensure_stream_timer()
end

function History:on_thinking_end()
    -- Fast path: the session manager calls this before every text_delta;
    -- stay synchronous (no vim.schedule) when no thinking block is active.
    if not self._thinking_accum and not self._thinking_requested then
        return
    end
    self:_seal_stream_text()
    vim.schedule(function()
        -- Text sealed before thinking_end renders first; the block freeze
        -- below rewrites only its own header row, preserving order.
        self:_pop_text_batch()
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        -- Land queued thinking deltas before freezing the block.
        self:_flush_stream_thinking()
        if not self._thinking_accum then
            return
        end
        self._is_thinking = false
        self:_emit_status()
        local elapsed = math.floor(vim.uv.hrtime() / 1e9 - self._thinking_accum.start_time)
        local header
        if elapsed >= 60 then
            header = "Thought for " .. math.floor(elapsed / 60) .. "m " .. (elapsed % 60) .. "s"
        else
            header = "Thought for " .. elapsed .. "s"
        end

        local visible = self._show_thinking
        local line_count

        local virt_id = self._thinking_accum.virt_id
        -- Delete streaming preview extmark before replacing the header line;
        -- otherwise gravity causes it to drift to the wrong row.
        if virt_id then
            pcall(vim.api.nvim_buf_del_extmark, self._buf, ns, virt_id)
            virt_id = nil
        end
        if visible then
            local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, self._thinking_accum.anchor, {})
            local header_row = pos[1] + 1
            local label = Config.options.labels.thinking
            local header_text = label .. " " .. header
            self:_with_modifiable(function()
                vim.api.nvim_buf_set_lines(self._buf, header_row, header_row + 1, false, { header_text })
            end)
            self:_apply_thinking_hl(header_row, 1)
            -- Freeze the rolling preview into a static head summary.
            local flat = Text.thinking_flat(self._thinking_accum.lines)
            local pw = self:_thinking_preview_width(header_text)
            virt_id = self:_set_thinking_preview(header_row, Text.thinking_head(flat, pw), virt_id)
            line_count = 2
        else
            line_count = 0
        end

        self._thinking_blocks[#self._thinking_blocks + 1] = {
            header = header,
            lines = self._thinking_accum.lines,
            anchor = self._thinking_accum.anchor,
            line_count = line_count,
            visible = visible,
            expanded = false,
            virt_id = virt_id,
        }
        self._thinking_accum = nil
        self:_update_status_extmark()
    end)
end

function History:toggle_thinking()
    vim.schedule(function()
        self._show_thinking = not self._show_thinking
        if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
            return
        end
        for _, block in ipairs(self._thinking_blocks) do
            if self._show_thinking and not block.visible then
                -- Show as single-line header + preview (not expanded)
                local label = Config.options.labels.thinking
                local header_text = label .. " " .. block.header
                local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.anchor, {})
                local row = pos[1]
                self:_with_modifiable(function()
                    vim.api.nvim_buf_set_lines(self._buf, row, row, false, { "", header_text })
                end)
                self:_apply_thinking_hl(row + 1, 1)
                local flat = Text.thinking_flat(block.lines)
                local pw = self:_thinking_preview_width(header_text)
                block.virt_id = self:_set_thinking_preview(row + 1, Text.thinking_head(flat, pw), block.virt_id)
                block.line_count = 2
                block.visible = true
                block.expanded = false
            elseif not self._show_thinking and block.visible then
                self:_remove_thinking_block(block.line_count, block.anchor)
                if block.virt_id then
                    pcall(vim.api.nvim_buf_del_extmark, self._buf, ns, block.virt_id)
                    block.virt_id = nil
                end
                block.visible = false
                block.expanded = false
            end
        end
    end)
end

--- Toggle expand/collapse for the thinking block under the cursor.
---@return boolean toggled
function History:toggle_thinking_block()
    local win = self:win()
    if not win then
        return false
    end
    local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1

    for _, block in ipairs(self._thinking_blocks) do
        if not block.visible then
            goto continue
        end
        local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.anchor, {})
        local anchor_row = pos[1]
        if not anchor_row then
            goto continue
        end
        local block_start = anchor_row
        local block_end = anchor_row + block.line_count - 1
        if cursor_row >= block_start and cursor_row <= block_end then
            if block.expanded then
                -- Collapse: replace multi-line with single-line + preview
                local label = Config.options.labels.thinking
                local header_text = label .. " " .. block.header
                self:_with_modifiable(function()
                    vim.api.nvim_buf_set_lines(
                        self._buf,
                        anchor_row,
                        anchor_row + block.line_count,
                        false,
                        { "", header_text }
                    )
                end)
                self:_apply_thinking_hl(anchor_row + 1, 1)
                local flat = Text.thinking_flat(block.lines)
                local pw = self:_thinking_preview_width(header_text)
                block.virt_id = self:_set_thinking_preview(anchor_row + 1, Text.thinking_head(flat, pw), block.virt_id)
                block.line_count = 2
                block.expanded = false
            else
                -- Expand: replace single-line with multi-line block
                if block.virt_id then
                    pcall(vim.api.nvim_buf_del_extmark, self._buf, ns, block.virt_id)
                    block.virt_id = nil
                end
                local block_lines = self:_build_thinking_block(block.header, block.lines)
                self:_with_modifiable(function()
                    vim.api.nvim_buf_set_lines(self._buf, anchor_row, anchor_row + block.line_count, false, block_lines)
                end)
                self:_apply_thinking_hl(anchor_row + 1, #block_lines - 2)
                block.line_count = #block_lines
                block.expanded = true
            end
            return true
        end
        ::continue::
    end
    return false
end

---@return boolean
function History:has_conversation_content()
    return self._has_conversation_content
end

--- Show a placeholder message (virtual text) on the history buffer.
--- Replaces any existing placeholder.
---@param virt_lines table[] virt_lines spec for nvim_buf_set_extmark
---@param opts? { force?: boolean, mode?: "loading" }
function History:set_placeholder(virt_lines, opts)
    self:clear_placeholder()
    if not (opts and opts.force) then
        local line_count = vim.api.nvim_buf_line_count(self._buf)
        if line_count ~= 1 then
            return
        end
        local first = vim.api.nvim_buf_get_lines(self._buf, 0, 1, false)[1]
        if first ~= "" then
            return
        end
    end
    self._placeholder_extmark = vim.api.nvim_buf_set_extmark(self._buf, ns, 0, 0, {
        virt_lines = virt_lines,
    })
    self._placeholder_mode = opts and opts.mode or nil
end

---@param virt_lines table[]
function History:show_loading_placeholder(virt_lines)
    self:set_placeholder(virt_lines, { mode = "loading" })
end

--- Remove the placeholder message if present.
function History:clear_placeholder()
    if not self._placeholder_extmark then
        self._placeholder_mode = nil
        return
    end
    pcall(vim.api.nvim_buf_del_extmark, self._buf, ns, self._placeholder_extmark)
    self._placeholder_extmark = nil
    self._placeholder_mode = nil
end

--- Add a message to the pending queue (displayed as virtual text at the bottom).
---@param queue_type "steer"|"follow_up"
---@param display_text string raw user text (for display)
---@param expanded_text string expanded text (for matching on delivery)
---@param image_count? integer
function History:add_pending_queue_entry(queue_type, display_text, expanded_text, image_count)
    self._pending_queue[#self._pending_queue + 1] = {
        queue_type = queue_type,
        text = display_text,
        expanded_text = expanded_text,
        image_count = image_count,
    }
    self:_update_status_extmark()
    self:_emit_queue_count()
    if self:_should_auto_scroll() then
        self:_scroll_to_bottom()
    end
end

--- Remove the first pending queue entry whose expanded_text matches.
--- Called when `message_start` arrives for a delivered steering/follow-up message.
---@param text string the user message text from the event
---@return pi.PendingQueueEntry? entry the removed entry, or nil if not found
function History:remove_pending_queue_entry(text)
    for i, entry in ipairs(self._pending_queue) do
        if entry.expanded_text == text then
            table.remove(self._pending_queue, i)
            self:_update_status_extmark()
            self:_emit_queue_count()
            return entry
        end
    end
    return nil
end

--- Get a shallow copy of pending queue entries.
---@return pi.PendingQueueEntry[]
function History:get_pending_queue()
    return { unpack(self._pending_queue) }
end

--- Clear all pending queue entries.
function History:clear_pending_queue()
    if #self._pending_queue == 0 then
        return
    end
    self._pending_queue = {}
    self:_update_status_extmark()
    self:_emit_queue_count()
end

--- Reconcile the pending queue with pi's authoritative queue state
--- (payload of a `queue_update` event).
---
--- Entries present in the payload but missing locally are synthesized
--- (the payload text serves as both display and expanded text); this covers
--- messages queued from outside the plugin (e.g. extensions).
---
--- Local entries missing from the payload are NOT removed while `active`
--- (agent streaming or compacting): they are either mid-delivery (pi emits
--- queue_update right before the delivering message_start) or about to be
--- flushed into history by on_agent_end (abort clears pi's queues first).
--- Removing them here would break both flows. When idle, however, no
--- delivery can arrive anymore, so unmatched entries are ghosts and are
--- swept.
---@param steering_texts string[]
---@param followup_texts string[]
---@param active boolean true while the agent is streaming or compacting
function History:sync_pending_queue(steering_texts, followup_texts, active)
    ---@param texts any
    ---@return string[]
    local function normalize(texts)
        local out = {}
        if type(texts) == "table" then
            for _, text in ipairs(texts) do
                if type(text) == "string" then
                    out[#out + 1] = text
                end
            end
        end
        return out
    end
    steering_texts = normalize(steering_texts)
    followup_texts = normalize(followup_texts)

    -- Remaining unmatched payload copies per (queue_type, text).
    ---@type table<string, integer>
    local payload_counts = {}
    local function count_payload(queue_type, texts)
        for _, text in ipairs(texts) do
            local key = queue_type .. "\0" .. text
            payload_counts[key] = (payload_counts[key] or 0) + 1
        end
    end
    count_payload("steer", steering_texts)
    count_payload("follow_up", followup_texts)

    -- Keep locally tracked entries that pi still holds (consuming one payload
    -- copy each). While active, keep the rest too — their removal is handled
    -- by message_start (delivery) or on_agent_end (abort flush).
    local kept = {}
    local swept = false
    for _, entry in ipairs(self._pending_queue) do
        local key = entry.queue_type .. "\0" .. entry.expanded_text
        if (payload_counts[key] or 0) > 0 then
            payload_counts[key] = payload_counts[key] - 1
            kept[#kept + 1] = entry
        elseif active then
            kept[#kept + 1] = entry
        else
            swept = true
        end
    end
    if swept then
        self._pending_queue = kept
        self:_update_status_extmark()
        self:_emit_queue_count()
    end

    -- Synthesize entries for payload items the plugin never saw.
    local function add_missing(queue_type, texts)
        for _, text in ipairs(texts) do
            local key = queue_type .. "\0" .. text
            if (payload_counts[key] or 0) > 0 then
                payload_counts[key] = payload_counts[key] - 1
                self:add_pending_queue_entry(queue_type, text, text)
            end
        end
    end
    add_missing("steer", steering_texts)
    add_missing("follow_up", followup_texts)
end

function History:clear()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return
    end
    if self._spinner_timer then
        self._spinner_timer:stop()
        self._spinner_timer:close()
        self._spinner_timer = nil
    end
    if self._stream_timer then
        self._stream_timer:stop()
        self._stream_timer:close()
        self._stream_timer = nil
    end
    self._pending_stream_text = nil
    self._pending_thinking = nil
    self._pending_bash = {}
    self._pending_tool_updates = {}
    self._bash_start_pending = {}
    self._tool_start_pending = {}
    self._text_batches = { {} } -- invariant: always ends with one open batch
    self._structural_inflight = 0
    self._thinking_requested = nil
    self:_clear_status_virt_lines()
    self._status_text = nil
    self._status_extmark_id = nil
    self._pending_queue = {}
    self._pending_queue_extmark_id = nil
    self._thinking_accum = nil
    self._thinking_blocks = {}
    self._tool_blocks = {}
    self._bash_blocks = {}
    self._bash_replay_counter = 0
    self._compaction_blocks = {}
    self._blocks_expanded = false
    self._has_conversation_content = false
    self._startup_block_line_count = 0
    self._startup_block_expanded = Config.options.expand_startup_details
    self._startup_block_expanded_lines = nil
    self._startup_block_expanded_marks = nil
    self._startup_block_compact_lines = nil
    self._startup_block_compact_marks = nil
    self._startup_timestamp = nil
    self._startup_sections = {}
    self._startup_loaded = false
    self._startup_errors = {}
    self:clear_placeholder()
    self._placeholder_mode = nil
    self._agent_text_start_row = nil
    self._agent_text_chunks = nil
    self._current_turn_first_agent_response_extmark_id = nil
    self._current_turn_last_agent_response_extmark_id = nil
    vim.api.nvim_buf_clear_namespace(self._buf, ns, 0, -1)
    self:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, { "" })
    end)
    self:_emit_status()
    self:_emit_queue_count()
end

-- ---------------------------------------------------------------------------
-- Open file under cursor
-- ---------------------------------------------------------------------------

--- Resolve a path candidate to an absolute path when it exists as a file.
---@param candidate string
---@return string?
local function resolve_file(candidate)
    if candidate == "" then
        return nil
    end
    local abs = vim.fn.fnamemodify(candidate, ":p")
    local stat = vim.uv.fs_stat(abs)
    if stat and stat.type == "file" then
        return abs
    end
    return nil
end

--- Extract a file path (and optional line number) from a history line. Handles
--- @mentions (with optional #L<start>), path:line suffixes, and bare paths
--- (tool body lines contain exactly the path).
---@param line string
---@return string? path
---@return integer? lnum
local function extract_path(line)
    local trimmed = vim.trim(line)
    if trimmed == "" then
        return nil, nil
    end

    -- @mention with #L<start>[-<end>]
    local mention, lnum = trimmed:match("@(%S-)#L(%d+)")
    if mention and mention ~= "" then
        return mention, tonumber(lnum)
    end

    -- @mention without a line range
    local m = trimmed:match("@(%S+)")
    if m then
        m = m:gsub("[.,;:)]+$", "")
        return m, nil
    end

    -- bare path with a :<line> suffix
    local p, ln = trimmed:match("^(%S+):(%d+)$")
    if p then
        return p, tonumber(ln)
    end

    -- whole line as a path
    return trimmed, nil
end

local PI_PANEL_FILETYPES = {
    [Ft.history] = true,
    [Ft.prompt] = true,
    [Ft.attachments] = true,
    [Ft.dialog] = true,
}

--- Open the file referenced on the history line under the cursor in an editor
--- window (never a π panel, so the chat stays visible), jumping to a line when
--- one is indicated. Returns true when a file was opened.
---@return boolean
function History:goto_path_at_cursor()
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
        return false
    end
    local win = self._win
    if not win or not vim.api.nvim_win_is_valid(win) then
        return false
    end
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local line = vim.api.nvim_buf_get_lines(self._buf, row - 1, row, false)[1] or ""
    local candidate, lnum = extract_path(line)
    if not candidate then
        return false
    end
    local abs = resolve_file(candidate)
    if not abs then
        return false
    end

    -- Prefer an existing non-π window in the current tab.
    local target
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local b = vim.api.nvim_win_get_buf(w)
        if not PI_PANEL_FILETYPES[vim.bo[b].filetype] then
            target = w
            break
        end
    end
    if target then
        vim.api.nvim_set_current_win(target)
    else
        vim.cmd("botright vsplit")
    end
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
    if lnum and lnum > 0 then
        pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
    end
    return true
end

return History
