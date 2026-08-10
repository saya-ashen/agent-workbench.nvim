--- Session diff review (:PiDiff) — review every file the current session
--- changed, as one unified `git diff` in a floating window.
---
--- The float renders the raw diff with the `diff` filetype, so the native
--- syntax highlighting applies. Each file gets a header line; <CR>/o jumps
--- to the file's line under the cursor (deleted files have no jump target),
--- q closes. Untracked files are shown as full-file additions (git's
--- no-index mode). The window is sized by the `diff_review` config.

local M = {}

local Config = require("pi.config")
local Ft = require("pi.filetypes")
local Highlights = require("pi.ui.highlights")
local Notify = require("pi.notify")

local ns = vim.api.nvim_create_namespace("pi-diff-review")

---@type integer?
local buf = nil
---@type integer?
local win = nil
---@type table<integer, { path: string, line: integer }> jump target per buffer line
local jump_targets = {}

--- Forward-declared (defined in the Jump section): <CR>/o handler.
local jump_to_target

---@class pi.DiffReviewSection
---@field path string Display path (relative to the repo/cwd).
---@field abs string Absolute path used for jumping.
---@field deleted boolean Whether the file was deleted (no jump target).
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
                body = {},
            }
            sections[#sections + 1] = current
        elseif current then
            -- Deletions keep the same path on both sides of `diff --git`;
            -- the `+++ b/dev/null` body line marks them.
            if line == "+++ b/dev/null" then
                current.deleted = true
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

--- Build the buffer lines, the jump-target map, and the header line numbers.
---@param sections pi.DiffReviewSection[]
---@param width integer
---@return string[]
---@return table<integer, { path: string, line: integer }>
---@return integer[] line numbers of section header lines (1-based)
local function build_lines(sections, width)
    ---@type string[]
    local lines = {}
    ---@type table<integer, { path: string, line: integer }>
    local targets = {}
    ---@type integer[]
    local headers = {}
    local count = #sections
    lines[1] = string.format("─ %d file%s changed · <CR>/o jump to file · q close", count, count == 1 and "" or "s")
    local lnum = 2
    for _, section in ipairs(sections) do
        lines[lnum] = header_line(section.path, width)
        headers[#headers + 1] = lnum
        if not section.deleted then
            targets[lnum] = { path = section.abs, line = 1 }
        end
        lnum = lnum + 1
        local hunk_lines = M.compute_hunk_lines(section.body)
        for i, body_line in ipairs(section.body) do
            lines[lnum] = body_line
            local new_line = hunk_lines[i]
            if new_line and not section.deleted then
                targets[lnum] = { path = section.abs, line = new_line }
            end
            lnum = lnum + 1
        end
    end
    return lines, targets, headers
end

--- Render the sections into a new floating window. Closes any existing
--- review window first.
---@param sections pi.DiffReviewSection[]
---@param opts? { skipped?: integer } number of changed files outside the git repo
function M.render(sections, opts)
    opts = opts or {}
    M.close()

    local cfg = Config.options.diff_review
    local width = resolve_dimension(cfg.width, vim.o.columns)
    local height = resolve_dimension(cfg.height, vim.o.lines - vim.o.cmdheight - 1)

    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, "pi://diff-review")
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].swapfile = false
    vim.bo[b].buflisted = false
    vim.bo[b].filetype = "diff"
    vim.bo[b].modifiable = false

    local lines, targets, headers = build_lines(sections, width)

    vim.bo[b].modifiable = true
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].modifiable = false

    vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(b, ns, 0, 0, { hl_group = "PiDiffReviewHint", end_col = #lines[1] })
    for _, lnum in ipairs(headers) do
        vim.api.nvim_buf_set_extmark(b, ns, lnum - 1, 0, { hl_group = "PiDiffReviewFile", end_col = #lines[lnum] })
    end
    if opts.skipped and opts.skipped > 0 then
        vim.api.nvim_buf_set_extmark(b, ns, 0, 0, {
            virt_text = {
                {
                    string.format("  (%d file%s outside the git repo)", opts.skipped, opts.skipped == 1 and "" or "s"),
                    "PiDiffReviewHint",
                },
            },
            virt_text_pos = "eol",
        })
    end

    local col = math.floor((vim.o.columns - width) / 2)
    local row = math.floor((vim.o.lines - vim.o.cmdheight - 1 - height) / 2)
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
    jump_targets = targets
end

--- Close the review window and wipe its buffer.
function M.close()
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, false)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    win = nil
    buf = nil
    jump_targets = {}
end

---@return boolean
function M.is_open()
    return win ~= nil and vim.api.nvim_win_is_valid(win)
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
    }
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local b = vim.api.nvim_win_get_buf(w)
        if not panel_fts[vim.bo[b].filetype] and not vim.wo[w].winfixbuf then
            return w
        end
    end
    return nil
end

--- Jump to the file/line under the cursor: close the review, then open the
--- file in an editor window (preferring an existing non-π window, mirroring
--- the chat history's gf behavior).
jump_to_target = function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local target = jump_targets[lnum]
    if not target then
        return
    end
    M.close()
    local editor_win = find_editor_win()
    if editor_win then
        vim.api.nvim_set_current_win(editor_win)
    else
        vim.cmd("botright vsplit")
    end
    vim.cmd("edit " .. vim.fn.fnameescape(target.path))
    if target.line and target.line > 0 then
        pcall(vim.api.nvim_win_set_cursor, 0, { target.line, 0 })
    end
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

--- Test hook: jump-target map (buffer line -> { path, line }).
---@return table<integer, { path: string, line: integer }>
function M._targets()
    return jump_targets
end

--- Test hook: close the review window and clear all state.
function M._reset()
    M.close()
end

return M
