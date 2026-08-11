-- Unit tests for pi.ui.diff_review (:PiDiff): pure diff parsing, hunk
-- line-number walking, config resolution, and float rendering.

local Config = require("pi.config")
local M = require("pi.ui.diff_review")

local SAMPLE = table.concat({
    "diff --git a/README.md b/README.md",
    "index 1234567..89abcde 100644",
    "--- a/README.md",
    "+++ b/README.md",
    "@@ -1,3 +1,4 @@",
    " # Title",
    "-old line",
    "+new line",
    " context line",
    "+",
    "diff --git a/lua/pi/init.lua b/lua/pi/init.lua",
    "new file mode 100644",
    "index 0000000..abcdef0",
    "--- /dev/null",
    "+++ b/lua/pi/init.lua",
    "@@ -0,0 +1,2 @@",
    "+local M = {}",
    "+return M",
    "diff --git a/gone.txt b/gone.txt",
    "deleted file mode 100644",
    "index abc..def 100644",
    "--- a/gone.txt",
    "+++ b/dev/null",
    "@@ -1,2 +0,0 @@",
    "-old one",
    "-old two",
    "",
}, "\n")

describe("diff_review parse_sections", function()
    it("splits output into per-file sections without the diff --git header", function()
        local sections = M.parse_sections(SAMPLE)
        assert.are.equal(3, #sections)

        local readme = sections[1]
        assert.are.equal("README.md", readme.path)
        assert.is_false(readme.deleted)
        assert.are.equal(vim.fn.fnamemodify("README.md", ":p"), readme.abs)
        assert.are.same({
            "index 1234567..89abcde 100644",
            "--- a/README.md",
            "+++ b/README.md",
            "@@ -1,3 +1,4 @@",
            " # Title",
            "-old line",
            "+new line",
            " context line",
            "+",
        }, readme.body)

        local new_file = sections[2]
        assert.are.equal("lua/pi/init.lua", new_file.path)
        assert.is_false(new_file.deleted)
        assert.are.equal("A", new_file.status)
        assert.are.equal("new file mode 100644", new_file.body[1])

        local gone = sections[3]
        assert.are.equal("gone.txt", gone.path)
        assert.is_true(gone.deleted)
        assert.are.equal("D", gone.status)
        assert.are.equal("@@ -1,2 +0,0 @@", gone.body[5])
        -- trailing empty line from the final newline is trimmed
        assert.are.equal("-old two", gone.body[#gone.body])

        -- the plain modified file keeps status M
        assert.are.equal("M", sections[1].status)
    end)

    it("handles a/dev/null (new file) and b/dev/null (deleted) paths", function()
        local new_output = table.concat({
            "diff --git a/dev/null b/added.txt",
            "new file mode 100644",
            "--- /dev/null",
            "+++ b/added.txt",
            "@@ -0,0 +1,1 @@",
            "+hello",
            "",
        }, "\n")
        local added = M.parse_sections(new_output)
        assert.are.equal(1, #added)
        assert.are.equal("added.txt", added[1].path)
        assert.is_false(added[1].deleted)

        local del_output = table.concat({
            "diff --git a/removed.txt b/removed.txt",
            "deleted file mode 100644",
            "--- a/removed.txt",
            "+++ b/dev/null",
            "@@ -1,1 +0,0 @@",
            "-bye",
            "",
        }, "\n")
        local removed = M.parse_sections(del_output)
        assert.are.equal("removed.txt", removed[1].path)
        assert.is_true(removed[1].deleted)
    end)

    it("returns no sections for empty output", function()
        assert.are.same({}, M.parse_sections(""))
    end)
end)

describe("diff_review compute_hunk_lines", function()
    it("walks context/add lines and keeps the deletion point on removed lines", function()
        local body = {
            "index 1234567..89abcde 100644",
            "--- a/README.md",
            "+++ b/README.md",
            "@@ -1,3 +1,4 @@",
            " # Title",
            "-old line",
            "+new line",
            " context line",
            "+",
        }
        local out = M.compute_hunk_lines(body)
        assert.is_nil(out[1]) -- before the first hunk: no target
        assert.is_nil(out[2])
        assert.is_nil(out[3])
        assert.are.equal(1, out[4]) -- hunk header -> hunk start
        assert.are.equal(1, out[5]) -- context "# Title" -> line 1
        assert.are.equal(2, out[6]) -- removed line -> deletion point (line 2)
        assert.are.equal(2, out[7]) -- added "+new line" -> line 2
        assert.are.equal(3, out[8]) -- context -> line 3
        assert.are.equal(4, out[9]) -- added "+" (blank) -> line 4
    end)

    it("maps a new file hunk starting at line 1", function()
        local out = M.compute_hunk_lines({
            "@@ -0,0 +1,2 @@",
            "+local M = {}",
            "+return M",
        })
        assert.are.equal(1, out[1])
        assert.are.equal(1, out[2])
        assert.are.equal(2, out[3])
    end)

    it("maps a deleted file hunk to line 0 (no jump targets built)", function()
        local out = M.compute_hunk_lines({
            "@@ -1,2 +0,0 @@",
            "-old one",
            "-old two",
        })
        assert.are.equal(0, out[1])
        assert.are.equal(0, out[2])
        assert.are.equal(0, out[3])
    end)

    it("keeps the counter on `\\ No newline` metadata lines", function()
        local out = M.compute_hunk_lines({
            "@@ -1,2 +1,2 @@",
            "-a",
            "+b",
            "\\ No newline at end of file",
            "+c",
        })
        assert.are.equal(1, out[1])
        assert.are.equal(1, out[2])
        assert.are.equal(1, out[3])
        assert.are.equal(2, out[4])
        assert.are.equal(2, out[5])
    end)
end)

describe("diff_review config", function()
    after_each(function()
        Config.setup({})
    end)

    it("defaults to 0.8 width/height with a rounded border", function()
        assert.are.equal(0.8, Config.options.diff_review.width)
        assert.are.equal(0.8, Config.options.diff_review.height)
        assert.are.equal("rounded", Config.options.diff_review.border)
        assert.are.equal("left", Config.options.diff_review.list.position)
        assert.are.equal(30, Config.options.diff_review.list.width)
    end)

    it("merges partial user config over the defaults", function()
        Config.setup({ diff_review = { width = 0.5, list = { position = "right", width = 40 } } })
        assert.are.equal(0.5, Config.options.diff_review.width)
        assert.are.equal(0.8, Config.options.diff_review.height)
        assert.are.equal("rounded", Config.options.diff_review.border)
        assert.are.equal("right", Config.options.diff_review.list.position)
        assert.are.equal(40, Config.options.diff_review.list.width)
    end)
end)

describe("diff_review render", function()
    after_each(function()
        M._reset()
    end)

    it("opens a side file list plus a float showing the first file", function()
        local sections = M.parse_sections(SAMPLE)
        M.render(sections)

        assert.is_true(M.is_open())
        -- the review is one panel: an outer container float framing two
        -- borderless inner floats (file list left, diff right)
        local shell_win = assert(M._shell_win())
        local shell_cfg = vim.api.nvim_win_get_config(shell_win)
        assert.are.equal("editor", shell_cfg.relative)
        assert.are.equal(8, #shell_cfg.border) -- rounded border, expanded
        assert.is_true(vim.wo[shell_win].winfixbuf)
        -- the container must sit below the inner floats: a focusable=false
        -- float draws above focusable=true floats with the same zindex and
        -- would hide the diff float (issue #16 follow-up)
        assert.is_true(shell_cfg.zindex < vim.api.nvim_win_get_config(list_win).zindex)
        assert.is_true(shell_cfg.zindex < vim.api.nvim_win_get_config(float_win).zindex)

        -- focus stays in the file list float
        local list_win = vim.api.nvim_get_current_win()
        local list_buf = vim.api.nvim_win_get_buf(list_win)
        assert.are.equal("pi-diff-review", vim.bo[list_buf].filetype)
        assert.are.equal("nofile", vim.bo[list_buf].buftype)
        assert.is_true(vim.wo[list_win].winfixbuf)

        local float_win = assert(M._float_win())
        for _, w in ipairs({ list_win, float_win }) do
            local cfg = vim.api.nvim_win_get_config(w)
            assert.are.equal("editor", cfg.relative)
            assert.are.equal("none", cfg.border)
            -- inner floats sit inside the container bounds
            assert.is_true(cfg.col > shell_cfg.col and cfg.col + cfg.width <= shell_cfg.col + shell_cfg.width)
            assert.is_true(cfg.row > shell_cfg.row and cfg.row + cfg.height <= shell_cfg.row + shell_cfg.height)
        end

        local list_lines = vim.api.nvim_buf_get_lines(list_buf, 0, -1, false)
        assert.matches("3 files", list_lines[1])
        assert.are.equal("M README.md", list_lines[2])
        assert.are.equal("A lua/pi/init.lua", list_lines[3])
        assert.are.equal("D gone.txt", list_lines[4])

        -- the float shows the first file's diff
        local float_win = assert(M._float_win())
        local b = vim.api.nvim_win_get_buf(float_win)
        assert.are.equal("diff", vim.bo[b].filetype)
        assert.are.equal("nofile", vim.bo[b].buftype)
        assert.is_true(vim.wo[float_win].winfixbuf)
        assert.are.equal(1, M._current_idx())

        local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        assert.is_true(vim.startswith(lines[1], "── README.md"))
        assert.is_true(vim.startswith(lines[2], "index 1234567"))

        -- header jumps to line 1; "-old line" (buffer line 7) keeps the deletion point
        local targets = M._targets()
        assert.are.same({ path = vim.fn.fnamemodify("README.md", ":p"), line = 1 }, targets[1])
        assert.are.same({ path = vim.fn.fnamemodify("README.md", ":p"), line = 2 }, targets[7])
        -- the blank added line (buffer line 10) -> new-file line 4
        assert.are.same({ path = vim.fn.fnamemodify("README.md", ":p"), line = 4 }, targets[10])
    end)

    it("switches the float to the selected file", function()
        M.render(M.parse_sections(SAMPLE))
        M._show_file(2)
        assert.are.equal(2, M._current_idx())
        local float_win = assert(M._float_win())
        local b = vim.api.nvim_win_get_buf(float_win)
        local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        assert.is_true(vim.startswith(lines[1], "── lua/pi/init.lua"))
        -- the first added line (buffer line 7) -> new-file line 1
        assert.are.same({ path = vim.fn.fnamemodify("lua/pi/init.lua", ":p"), line = 1 }, M._targets()[7])

        -- a deleted file shows only the header, with no jump targets
        M._show_file(3)
        assert.are.equal(3, M._current_idx())
        local gone_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        assert.is_true(vim.startswith(gone_lines[1], "── gone.txt"))
        assert.are.same({}, M._targets())
    end)

    it("is closed by M.close and M._reset", function()
        M.render(M.parse_sections(SAMPLE))
        M.close()
        assert.is_false(M.is_open())
        assert.is_nil(M._float_win())
        assert.are.same({}, M._targets())
        M.render(M.parse_sections(SAMPLE))
        M._reset()
        assert.is_false(M.is_open())
    end)
end)
