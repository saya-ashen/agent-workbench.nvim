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
        assert.are.equal("new file mode 100644", new_file.body[1])

        local gone = sections[3]
        assert.are.equal("gone.txt", gone.path)
        assert.is_true(gone.deleted)
        assert.are.equal("@@ -1,2 +0,0 @@", gone.body[5])
        -- trailing empty line from the final newline is trimmed
        assert.are.equal("-old two", gone.body[#gone.body])
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
    end)

    it("merges partial user config over the defaults", function()
        Config.setup({ diff_review = { width = 0.5 } })
        assert.are.equal(0.5, Config.options.diff_review.width)
        assert.are.equal(0.8, Config.options.diff_review.height)
        assert.are.equal("rounded", Config.options.diff_review.border)
    end)
end)

describe("diff_review render", function()
    after_each(function()
        M._reset()
    end)

    it("creates a diff-typed float with a hint line, headers, and jump targets", function()
        local sections = M.parse_sections(SAMPLE)
        M.render(sections)

        assert.is_true(M.is_open())
        local win = vim.api.nvim_get_current_win()
        local b = vim.api.nvim_win_get_buf(win)
        assert.are.equal("diff", vim.bo[b].filetype)
        assert.are.equal("nofile", vim.bo[b].buftype)
        assert.is_true(vim.wo[win].winfixbuf)

        local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        assert.matches("3 files changed", lines[1])
        assert.is_true(vim.startswith(lines[2], "── README.md"))
        assert.is_true(vim.startswith(lines[3], "index 1234567"))
        assert.is_true(vim.startswith(lines[12], "── lua/pi/init.lua"))
        assert.is_true(vim.startswith(lines[20], "── gone.txt"))

        local targets = M._targets()
        -- header lines jump to line 1 of their file
        assert.are.same({ path = vim.fn.fnamemodify("README.md", ":p"), line = 1 }, targets[2])
        -- body: "-old line" (buffer line 8) keeps the deletion point -> new-file line 2
        assert.are.same({ path = vim.fn.fnamemodify("README.md", ":p"), line = 2 }, targets[8])
        -- the blank added line (buffer line 11) -> new-file line 4
        assert.are.same({ path = vim.fn.fnamemodify("README.md", ":p"), line = 4 }, targets[11])
        -- the first added line of the new file (buffer line 18) -> line 1
        assert.are.same({ path = vim.fn.fnamemodify("lua/pi/init.lua", ":p"), line = 1 }, targets[18])
        -- metadata before the first hunk has no target
        assert.is_nil(targets[16])
        -- deleted-file header and body lines have no jump target
        assert.is_nil(targets[20])
        assert.is_nil(targets[26])
    end)

    it("is closed by M.close and M._reset", function()
        local sections = M.parse_sections(SAMPLE)
        M.render(sections)
        M.close()
        assert.is_false(M.is_open())
        assert.are.same({}, M._targets())
        M.render(sections)
        M._reset()
        assert.is_false(M.is_open())
    end)
end)
