--- Session diff review (:PiDiff) — review every file the current session
--- changed, as one unified `git diff`.
---
--- The file list lives in a side window (`pi-diff-review` filetype); moving
--- the cursor there shows the selected file's diff in a floating window
--- (`diff` filetype, native syntax highlighting). <CR>/o jumps to the file
--- and line under the cursor, q closes. Untracked files are shown as
--- full-file additions (git's no-index mode). Window geometry comes from
--- the `diff_review` config.

local M = {}

local Config = require("pi.config")
local Ft = require("pi.filetypes")
local Highlights = require("pi.ui.highlights")
local Notify = require("pi.notify")

local ns = vim.api.nvim_create_namespace("pi-diff-review")

---@type integer? float window/buffer showing the selected file's diff
local win = nil
local buf = nil
---@type integer? side file-list window/buffer
local list_win = nil
local list_buf = nil
---@type pi.DiffReviewSection[] collected sections (list row = index + 1)
local sections = {}
---@type integer index of the section shown in the float
local current_idx = 1
---@type integer number of changed files skipped (outside the git repo)
local skipped_outside = 0
---@type table<integer, { path: string, line: integer }> jump target per float buffer line
local jump_targets = {}

--- Forward-declared (defined in the Jump section): <CR>/o handlers.
local jump_to_target
local list_jump

---@class pi.DiffReviewSection
---@field path string Display path (relative to the repo/cwd).
---@field abs string Absolute path used for jumping.
---@field deleted boolean Whether the file was deleted (no jump target).
---@field status "A"|"M"|"D" File status shown in the list (added/modified/deleted).
---@field body string[] Diff body lines (everything after the `diff --git` header).

--- Diff context (lines of surrounding context per hunk). Mirrors the
--- pre-execution diff review: `'diffopt' context:` wins, default 6.
---@return integer
local function diff_context()
    for _, item in ipairs(vim.split(vim.go.diffopt, ",", { plain = true, trimempty = true })) do
        local value = item:match("^context:(%d+)$")
        if value then
            local n = tonumber(value)
            if n then
                return n
            end
        end
    end
    return 6
end

---@param value number
---@param available integer
---@return integer
local function resolve_dimension(value, available)
    if value < 1 then
        return math.max(1, math.floor(available * value))
    end
    return math.max(1, math.floor(value))
end

-- Pure parsing (unit-tested) ------------------------------------------------

--- Split raw `git diff` output into per-file sections.
--- The `diff --git a/... b/...` header line becomes the section itself;
--- everything after it (index / --- / +++ / @@ / ± lines) goes into `body`.
--- `a/dev/null` means the file is new, `b/dev/null` means deleted.
---@param output string Raw `git diff` output.
---@return pi.DiffReviewSection[]
function M.parse_sections(output)
    ---@type pi.DiffReviewSection[]
    local sections = {}
    local current = nil
    for _, line in ipairs(vim.split(output or "", "\n", { plain = true })) do
        local a_path, b_path = line:match("^diff %-%-git a/(.*) b/(.*)$")
        if a_path then
            local deleted = b_path == "/dev/null"
            local display = deleted and a_path or b_path
            current = {
                path = display,
                abs = vim.fn.fnamemodify(display, ":p"),
                deleted = deleted,
                status = "M",
                body = {},
            }
            sections[#sections + 1] = current
        elseif current then
            -- Deletions keep the same path on both sides of `diff --git`;
            -- the `+++ b/dev/null` body line marks them.
            if line == "+++ b/dev/null" then
                current.deleted = true
                current.status = "D"
            elseif vim.startswith(line, "new file mode") then
                current.status = "A"
            elseif vim.startswith(line, "deleted file mode") then
                current.deleted = true
                current.status = "D"
            end
            current.body[#current.body + 1] = line
        end
    end
    -- Drop the empty line left by the trailing newline of the output.
    for _, section in ipairs(sections) do
        while #section.body > 0 and section.body[#section.body] == "" do
            section.body[#section.body] = nil
        end
    end
    return sections
end

--- Map each body line to the line number it refers to in the new file.
--- Walk the `@@ -a,b +c,d @@` hunk headers: an added (`+`) or context (` `)
--- line advances the counter, a removed (`-`) line keeps it (the deletion
--- point). Lines before the first hunk (index / --- / +++ / new file mode)
--- are not mapped. Non-hunk metadata lines (`\ No newline at end of file`)
--- keep the current counter.
---@param body string[] Section body lines (see pi.DiffReviewSection.body).
---@return table<integer, integer> body line index (1-based) -> new-file line
function M.compute_hunk_lines(body)
    ---@type table<integer, integer>
    local out = {}
    local new_line = nil
    for i, line in ipairs(body) do
        local start = line:match("^@@ .- %+(%d+)")
        if start then
            new_line = tonumber(start)
            out[i] = new_line
        elseif new_line then
            out[i] = new_line
            local prefix = line:sub(1, 1)
            if prefix == "+" or prefix == " " then
                new_line = new_line + 1
            end
        end
    end
    return out
end

--- Close the float window and wipe its buffer.
local function close_float()
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, false)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    win = nil
    buf = nil
end

--- Close the list window and wipe its buffer.
local function close_list()
    if list_win and vim.api.nvim_win_is_valid(list_win) then
        pcall(vim.api.nvim_win_close, list_win, false)
    end
    if list_buf and vim.api.nvim_buf_is_valid(list_buf) then
        pcall(vim.api.nvim_buf_delete, list_buf, { force = true })
    end
    list_win = nil
    list_buf = nil
end

-- Rendering -----------------------------------------------------------------

---@param path string
---@param width integer
---@return string
local function header_line(path, width)
    local left = "── "
    local left_w = vim.fn.strdisplaywidth(left)
    local path_w = vim.fn.strdisplaywidth(path)
    local budget = width - left_w - 2
    if path_w > budget then
        return left .. vim.fn.strcharpart(path, 0, math.max(1, budget - 1)) .. "…"
    end
    local fill = string.rep("─", math.max(1, budget - path_w))
    return left .. path .. " " .. fill
end

--- Build the float lines for one section: the file header plus the diff body.
---@param section pi.DiffReviewSection
---@param width integer
---@return string[]
---@return table<integer, { path: string, line: integer }>
local function build_file_lines(section, width)
    ---@type string[]
    local lines = { header_line(section.path, width) }
    ---@type table<integer, { path: string, line: integer }>
    local targets = {}
    if not section.deleted then
        targets[1] = { path = section.abs, line = 1 }
    end
    local hunk_lines = M.compute_hunk_lines(section.body)
    for i, body_line in ipairs(section.body) do
        lines[#lines + 1] = body_line
        local new_line = hunk_lines[i]
        if new_line and not section.deleted then
            targets[#lines] = { path = section.abs, line = new_line }
        end
    end
    return lines, targets
end

---@param sections pi.DiffReviewSection[]
---@return string[]
local function build_list_lines(sections)
    local count = #sections
    local hint = string.format("─ %d file%s · <CR> jump · q close", count, count == 1 and "" or "s")
    if skipped_outside > 0 then
        hint = hint .. string.format(" · %d outside", skipped_outside)
    end
    ---@type string[]
    local lines = { hint }
    for _, section in ipairs(sections) do
        lines[#lines + 1] = section.status .. " " .. section.path
    end
    return lines
end

---@param section pi.DiffReviewSection
---@return string highlight group for the status letter
local function status_hl(section)
    if section.status == "A" then
        return "PiDiffAddSign"
    end
    if section.status == "D" then
        return "PiDiffDeleteSign"
    end
    return "PiDiffReviewFile"
end

--- Fill the list buffer from `sections` (status letters highlighted).
local function render_list()
    if not list_buf or not vim.api.nvim_buf_is_valid(list_buf) then
        return
    end
    local lines = build_list_lines(sections)
    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
    vim.bo[list_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(list_buf, ns, 0, 0, { hl_group = "PiDiffReviewHint", end_col = #lines[1] })
    for i, section in ipairs(sections) do
        vim.api.nvim_buf_set_extmark(list_buf, ns, i, 0, { hl_group = status_hl(section), end_col = 1 })
    end
end

--- Show the diff of the section at `idx` in the float.
---@param idx integer 1-based section index
function M._show_file(idx)
    if idx < 1 or idx > #sections then
        return
    end
    current_idx = idx
    if not win or not vim.api.nvim_win_is_valid(win) or not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local section = sections[idx]
    local width = vim.api.nvim_win_get_width(win)
    local lines, targets = build_file_lines(section, width)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { hl_group = "PiDiffReviewFile", end_col = #lines[1] })
    jump_targets = targets
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
end

--- List cursor moved: follow the selection into the float.
--- Factored out of the CursorMoved autocmd so tests can call it directly
--- (headless -l mode does not dispatch CursorMoved, see G4).
local function on_list_cursor_moved()
    if not list_win or not vim.api.nvim_win_is_valid(list_win) then
        return
    end
    local idx = vim.api.nvim_win_get_cursor(list_win)[1] - 1
    if idx >= 1 and idx <= #sections and idx ~= current_idx then
        M._show_file(idx)
    end
end

--- Open the side file-list window.
local function open_list_window()
    local list_cfg = Config.options.diff_review.list
    local width = math.max(10, math.floor(list_cfg.width))
    local cmd = list_cfg.position == "right" and ("botright " .. width .. "vsplit") or ("topleft " .. width .. "vsplit")
    vim.cmd(cmd)
    local w = vim.api.nvim_get_current_win()
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, "pi://diff-review-files")
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].swapfile = false
    vim.bo[b].buflisted = false
    vim.bo[b].filetype = Ft.diff_review
    vim.bo[b].modifiable = false
    vim.api.nvim_win_set_buf(w, b)
    vim.wo[w].wrap = false
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].signcolumn = "no"
    vim.wo[w].foldcolumn = "0"
    vim.wo[w].foldenable = false
    vim.wo[w].spell = false
    vim.wo[w].cursorline = true
    vim.wo[w].winfixbuf = true
    list_win = w
    list_buf = b
end

--- Open the float showing the selected file's diff. Focus returns to the
--- file list afterwards; the float stays reachable (click / <C-w>w) for
--- scrolling and line-level jumps.
local function open_float_window()
    local cfg = Config.options.diff_review
    local width = resolve_dimension(cfg.width, vim.o.columns)
    local height = resolve_dimension(cfg.height, vim.o.lines - vim.o.cmdheight - 1)
    local col = math.floor((vim.o.columns - width) / 2)
    local row = math.floor((vim.o.lines - vim.o.cmdheight - 1 - height) / 2)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, "pi://diff-review")
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].swapfile = false
    vim.bo[b].buflisted = false
    vim.bo[b].filetype = "diff"
    vim.bo[b].modifiable = false
    local w = vim.api.nvim_open_win(b, true, {
        relative = "editor",
        width = width,
        height = height,
        col = col,
        row = math.max(0, row),
        style = "minimal",
        border = cfg.border or "rounded",
        title = " diff review ",
        title_pos = "center",
    })
    vim.wo[w].cursorline = true
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].signcolumn = "no"
    vim.wo[w].foldcolumn = "0"
    vim.wo[w].foldenable = false
    vim.wo[w].spell = false
    vim.wo[w].winfixbuf = true
    vim.wo[w].winhighlight = Highlights.DIFF_REVIEW_WINHIGHLIGHT

    vim.keymap.set("n", "q", M.close, { buffer = b, nowait = true, desc = "Close diff review" })
    vim.keymap.set("n", "<CR>", jump_to_target, { buffer = b, nowait = true, desc = "Jump to file" })
    vim.keymap.set("n", "o", jump_to_target, { buffer = b, nowait = true, desc = "Jump to file" })

    buf = b
    win = w
end

--- Render the collected sections: side file list + float with the first file.
--- Closes any existing review windows first.
---@param rendered pi.DiffReviewSection[]
---@param opts? { skipped?: integer } number of changed files outside the git repo
function M.render(rendered, opts)
    opts = opts or {}
    M.close()
    sections = rendered
    current_idx = 1
    skipped_outside = opts.skipped or 0

    open_list_window()
    render_list()
    open_float_window()
    M._show_file(1)
    -- The float takes focus on open; hand it back to the file list.
    pcall(vim.api.nvim_set_current_win, list_win)

    vim.keymap.set("n", "q", M.close, { buffer = list_buf, nowait = true, desc = "Close diff review" })
    vim.keymap.set("n", "<CR>", list_jump, { buffer = list_buf, nowait = true, desc = "Jump to file" })
    vim.keymap.set("n", "o", list_jump, { buffer = list_buf, nowait = true, desc = "Jump to file" })
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = list_buf,
        callback = on_list_cursor_moved,
    })
    -- Closing either window closes the whole review.
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(list_win),
        once = true,
        callback = close_float,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = close_list,
    })

    -- Land the cursor on the first file row.
    pcall(vim.api.nvim_win_set_cursor, list_win, { 2, 0 })
end

---@return boolean
function M.is_open()
    return list_win ~= nil and vim.api.nvim_win_is_valid(list_win)
end

---@return integer? the float window handle when the review is open
function M._float_win()
    if win and vim.api.nvim_win_is_valid(win) then
        return win
    end
    return nil
end

--- Close the review (both windows) and clear all state.
function M.close()
    close_float()
    close_list()
    sections = {}
    current_idx = 1
    skipped_outside = 0
    jump_targets = {}
end

-- Jump ----------------------------------------------------------------------

---@return integer? a non-π, non-winfixbuf window in the current tab
local function find_editor_win()
    local panel_fts = {
        [Ft.history] = true,
        [Ft.prompt] = true,
        [Ft.attachments] = true,
        [Ft.dialog] = true,
        [Ft.sessions] = true,
        [Ft.diff_review] = true,
    }
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local b = vim.api.nvim_win_get_buf(w)
        if not panel_fts[vim.bo[b].filetype] and not vim.wo[w].winfixbuf then
            return w
        end
    end
    return nil
end

--- Open `path` in an editor window (preferring an existing non-π window,
--- mirroring the chat history's gf behavior) and jump to `line`.
---@param path string
---@param line integer
local function open_at(path, line)
    local editor_win = find_editor_win()
    if editor_win then
        vim.api.nvim_set_current_win(editor_win)
    else
        vim.cmd("botright vsplit")
    end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    if line > 0 then
        pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    end
end

--- First changed line of a section in the new file (the first hunk target),
--- or 1 for files with no hunks. nil for deleted files.
---@param section pi.DiffReviewSection
---@return integer?
local function first_changed_line(section)
    if section.deleted then
        return nil
    end
    local hunk_lines = M.compute_hunk_lines(section.body)
    for i, line in ipairs(section.body) do
        local new_line = hunk_lines[i]
        if new_line and new_line > 0 then
            return new_line
        end
    end
    return 1
end

--- Float <CR>/o: jump to the file/line under the cursor, closing the review.
jump_to_target = function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local target = jump_targets[lnum]
    if not target then
        return
    end
    M.close()
    open_at(target.path, target.line)
end

--- List <CR>/o: jump to the selected file's first changed line.
list_jump = function()
    local idx = vim.api.nvim_win_get_cursor(0)[1] - 1
    if idx < 1 or idx > #sections then
        return
    end
    local section = sections[idx]
    local line = first_changed_line(section)
    if not line then
        return
    end
    M.close()
    open_at(section.abs, line)
end

-- Collection -----------------------------------------------------------------

---@param files string[] changed-file paths as recorded by the session
---@param toplevel string git work tree root
---@return string[] paths inside the repo (passable to git)
---@return integer number of paths outside the repo (skipped)
local function partition_inside(files, toplevel)
    local inside = {}
    local outside = 0
    local tl = toplevel
    if tl:sub(-1) ~= "/" then
        tl = tl .. "/"
    end
    for _, f in ipairs(files) do
        local abs = vim.fn.fnamemodify(f, ":p")
        if abs:sub(1, #tl) == tl then
            inside[#inside + 1] = f
        else
            outside = outside + 1
        end
    end
    return inside, outside
end

--- For changed files that produced no main-diff section: show tracked files
--- with no diff vs. the index as-is (nothing to show), and untracked files
--- as full-file additions via `git diff --no-index`.
---@param files string[]
---@param cwd string
---@param sections pi.DiffReviewSection[]
---@param skipped integer
local function fetch_untracked_sections(files, cwd, sections, skipped, idx)
    idx = idx or 1
    if idx > #files then
        if #sections == 0 then
            Notify.warn(":PiDiff — no diff output for this session's changed files")
            return
        end
        M.render(sections, { skipped = skipped })
        return
    end
    local path = files[idx]
    vim.system({ "git", "ls-files", "--error-unmatch", "--", path }, { cwd = cwd }, function(res)
        vim.schedule(function()
            if res.code == 0 then
                -- Tracked and identical to the index: nothing to show.
                fetch_untracked_sections(files, cwd, sections, skipped, idx + 1)
                return
            end
            vim.system(
                { "git", "diff", "--no-index", "--no-color", "--", "/dev/null", path },
                { cwd = cwd },
                function(res2)
                    vim.schedule(function()
                        local extra = M.parse_sections(res2.stdout or "")
                        for _, section in ipairs(extra) do
                            sections[#sections + 1] = section
                        end
                        fetch_untracked_sections(files, cwd, sections, skipped, idx + 1)
                    end)
                end
            )
        end)
    end)
end

--- Collect the diff of the session's changed files and render it.
---@param files string[]
local function collect_and_render(files)
    local cwd = vim.uv.cwd()
    vim.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd }, function(res)
        vim.schedule(function()
            local toplevel = vim.trim(res.stdout or "")
            if res.code ~= 0 or toplevel == "" then
                Notify.warn(":PiDiff — current directory is not inside a git work tree")
                return
            end
            local inside, outside = partition_inside(files, toplevel)
            if #inside == 0 then
                Notify.warn(":PiDiff — no changed files are inside the current git repository")
                return
            end
            local ctx = diff_context()
            local cmd = { "git", "diff", "--no-color", "-U" .. ctx, "--" }
            for _, f in ipairs(inside) do
                cmd[#cmd + 1] = f
            end
            vim.system(cmd, { cwd = cwd }, function(res2)
                vim.schedule(function()
                    local sections = M.parse_sections(res2.stdout or "")
                    local covered = {}
                    for _, section in ipairs(sections) do
                        covered[section.abs] = true
                    end
                    ---@type string[]
                    local uncovered = {}
                    for _, f in ipairs(inside) do
                        local abs = vim.fn.fnamemodify(f, ":p")
                        if not covered[abs] then
                            uncovered[#uncovered + 1] = f
                        end
                    end
                    if #uncovered == 0 then
                        if #sections == 0 then
                            Notify.warn(":PiDiff — no diff output for this session's changed files")
                            return
                        end
                        M.render(sections, { skipped = outside })
                        return
                    end
                    fetch_untracked_sections(uncovered, cwd, sections, outside)
                end)
            end)
        end)
    end)
end

--- Open the diff review for the current session's changed files.
--- No-op with a warning when there is no session, nothing was changed, or
--- the working directory is not a git work tree. Re-opening refreshes.
function M.open()
    local Sessions = require("pi.sessions.manager")
    local session = Sessions.get()
    if not session then
        Notify.warn(":PiDiff — no active session")
        return
    end
    local files = vim.tbl_keys(session.changed_files)
    if #files == 0 then
        Notify.warn(":PiDiff — no files changed in this session yet")
        return
    end
    M.close()
    collect_and_render(files)
end

--- Test hook: list cursor moved (drives the float follow; the CursorMoved
--- autocmd calls the same handler).
function M._on_list_cursor_moved()
    on_list_cursor_moved()
end

--- Test hook: jump-target map of the float (buffer line -> { path, line }).
---@return table<integer, { path: string, line: integer }>
function M._targets()
    return jump_targets
end

--- Test hook: index of the section currently shown in the float.
---@return integer
function M._current_idx()
    return current_idx
end

--- Test hook: close the review windows and clear all state.
function M._reset()
    M.close()
end

return M
