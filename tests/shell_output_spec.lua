local Output = require("agent-workbench.ui.chat.terminal.output")

describe("shell output decorations", function()
    after_each(function()
        Output._reset()
    end)

    it("projects ANSI styles only when parsed text matches terminal text", function()
        local styled = Output.analyze({ "RED" }, "\27[31mRED\27[0m\r\n", vim.uv.cwd())
        local unsafe = Output.analyze({ "20%" }, "10%\r20%\n", vim.uv.cwd())

        assert.are.equal(1, #styled.spans)
        assert.are.equal(1, styled.spans[1].style.fg)
        assert.are.equal(0, #unsafe.spans)

        local text = string.rep("x", 128 * 1024)
        local large = Output.analyze({ text }, "\27[31m" .. text .. "\27[0m", vim.uv.cwd())
        assert.are.equal(0, #large.spans)
    end)

    it("detects JSON and diff output without rewriting it", function()
        local json = Output.analyze({ '{"ok":true}' }, '{"ok":true}\n', vim.uv.cwd())
        local diff = Output.analyze({
            "diff --git a/a b/a",
            "@@ -1,3 +1,3 @@",
            "-old",
            "--value",
            "--- value",
            "+new",
            "++value",
            "+++ value",
        }, "", vim.uv.cwd())

        assert.are.equal("json", json.kind)
        assert.are.equal("diff", diff.kind)
        local additions = 0
        local deletions = 0
        for _, span in ipairs(diff.spans) do
            additions = additions + (span.hl_group == "PiDiffAdd" and 1 or 0)
            deletions = deletions + (span.hl_group == "PiDiffDelete" and 1 or 0)
        end
        assert.are.equal(3, additions)
        assert.are.equal(3, deletions)
    end)

    it("validates filesystem paths and identifies URLs", function()
        local cwd = vim.fn.tempname()
        vim.fn.mkdir(cwd, "p")
        vim.fn.mkdir(cwd .. "/src")
        vim.fn.writefile({ "return true" }, cwd .. "/main.lua")

        local decorations = Output.analyze({ "src main.lua missing.lua https://example.com" }, "", cwd)
        local groups = vim.tbl_map(function(span)
            return span.hl_group
        end, decorations.spans)

        assert.is_true(vim.tbl_contains(groups, "Directory"))
        assert.is_true(vim.tbl_contains(groups, "PiShellPath"))
        assert.is_true(vim.tbl_contains(groups, "PiShellUrl"))
        vim.fn.delete(cwd, "rf")
    end)

    it("resolves relative paths against command-end then command-start cwd", function()
        local before = vim.fn.tempname()
        local after = vim.fn.tempname()
        vim.fn.mkdir(before .. "/old-entry", "p")
        vim.fn.mkdir(after .. "/new-entry", "p")

        local decorations = Output.analyze({ "new-entry old-entry" }, "", { after, before })
        local directories = vim.tbl_filter(function(span)
            return span.hl_group == "Directory"
        end, decorations.spans)

        assert.are.equal(2, #directories)
        vim.fn.delete(before, "rf")
        vim.fn.delete(after, "rf")
    end)

    it("prioritizes ls filename fields before metadata under the probe cap", function()
        local original_stat = vim.uv.fs_stat
        local original_devicons = package.loaded["nvim-web-devicons"]
        local calls = 0
        vim.uv.fs_stat = function(path)
            calls = calls + 1
            return path:match("/entry%-%d+$") and { type = "directory" } or nil
        end
        package.loaded["nvim-web-devicons"] = { get_icon = function() end }
        local lines = {}
        for index = 1, 200 do
            lines[index] = ("drwxr-xr-x 1 saya users 1 Aug 7 19:41 entry-%d"):format(index)
        end
        local ok, decorations = pcall(Output.analyze, lines, "", vim.uv.cwd())
        vim.uv.fs_stat = original_stat
        package.loaded["nvim-web-devicons"] = original_devicons

        assert.is_true(ok, decorations)
        assert.is_true(calls >= 200 and calls <= 256)
        assert.are.equal(200, #decorations.spans)
        assert.are.equal(200, #decorations.icons)
    end)

    it("avoids partial path decoration for high-cardinality output", function()
        local original = vim.uv.fs_stat
        local calls = 0
        vim.uv.fs_stat = function()
            calls = calls + 1
            return { type = "directory" }
        end
        local lines = {}
        for index = 1, 300 do
            lines[index] = "entry-" .. index
        end
        local ok, decorations = pcall(Output.analyze, lines, "", vim.uv.cwd())
        vim.uv.fs_stat = original

        assert.is_true(ok, decorations)
        assert.are.equal(0, calls)
        assert.are.equal(0, #decorations.spans)
        assert.are.equal(0, #decorations.icons)
    end)

    it("caps synchronous filesystem probes for hostile plain-text output", function()
        local original = vim.uv.fs_stat
        local calls = 0
        vim.uv.fs_stat = function()
            calls = calls + 1
            return nil
        end
        local tokens = {}
        for index = 1, 400 do
            tokens[index] = "missing-" .. index
        end
        local ok, err = pcall(Output.analyze, { table.concat(tokens, " ") }, "", vim.uv.cwd())
        vim.uv.fs_stat = original

        assert.is_true(ok, err)
        assert.are.equal(256, calls)
    end)

    it("renders extmarks while preserving exact buffer text", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "RED" })
        local decorations = Output.analyze({ "RED" }, "\27[1;31mRED\27[0m\n", vim.uv.cwd())

        Output.render(buf, 0, decorations)

        assert.are.same({ "RED" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        local marks = vim.api.nvim_buf_get_extmarks(buf, Output.namespace(), 0, -1, { details = true })
        assert.are.equal(1, #marks)
        assert.is_true(assert(marks[1][4].hl_group):match("^PiShellAnsi_") ~= nil)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("bounds dynamic ANSI groups and refreshes their palette on ColorScheme", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", 600) })
        local spans = {}
        for col = 0, 599 do
            spans[#spans + 1] = {
                row = 0,
                start_col = col,
                end_col = col + 1,
                style = { fg = ("#%06x"):format(col + 1) },
                priority = 220,
            }
        end
        Output.render(buf, 0, { kind = "text", spans = spans, icons = {} })
        assert.are.equal(512, #vim.api.nvim_buf_get_extmarks(buf, Output.namespace(), 0, -1, {}))

        Output._reset()
        vim.api.nvim_buf_clear_namespace(buf, Output.namespace(), 0, -1)
        local original_red = vim.g.terminal_color_1
        vim.g.terminal_color_1 = "#010203"
        local decorations = Output.analyze({ "x" }, "\27[31mx\27[0m", vim.uv.cwd())
        Output.render(buf, 0, decorations)
        local mark = vim.api.nvim_buf_get_extmarks(buf, Output.namespace(), 0, -1, { details = true })[1]
        local group = assert(mark[4].hl_group)
        assert.are.equal(0x010203, vim.api.nvim_get_hl(0, { name = group, link = false }).fg)

        vim.g.terminal_color_1 = "#040506"
        vim.api.nvim_exec_autocmds("ColorScheme", {})
        assert.are.equal(0x040506, vim.api.nvim_get_hl(0, { name = group, link = false }).fg)

        Output.clear(buf)
        local faint = Output.analyze({ "x" }, "\27[2;31mx\27[0m", vim.uv.cwd())
        Output.render(buf, 0, faint)
        local faint_mark = vim.api.nvim_buf_get_extmarks(buf, Output.namespace(), 0, -1, { details = true })[1]
        local faint_group = assert(faint_mark[4].hl_group)
        assert.are_not.equal(0x040506, vim.api.nvim_get_hl(0, { name = faint_group, link = false }).fg)
        vim.g.terminal_color_1 = original_red
        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)
