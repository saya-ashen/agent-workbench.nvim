local Framing = require("pi.ui.chat.terminal.shell.framing")
local Completion = require("pi.ui.chat.terminal.shell.completion")

describe("shell frame parser", function()
    it("recognizes control frames split at every byte boundary", function()
        local frame = Framing.new("token")
        local bytes = frame:start_marker() .. "hello\nworld" .. frame:end_prefix() .. "7:/tmp/a%20b\7"
        local events = {}
        for index = 1, #bytes do
            vim.list_extend(events, frame:feed(bytes:sub(index, index)))
        end
        assert.are.same({
            { type = "output", bytes = "hello\nworld" },
            { type = "end", status = 7, cwd = "/tmp/a b" },
        }, events)
    end)

    it("keeps noise out and parses consecutive frames", function()
        local frame = Framing.new("token")
        local bytes = "prompt noise"
            .. frame:start_marker()
            .. "one"
            .. frame:end_prefix()
            .. "0\7"
            .. "more noise"
            .. frame:start_marker()
            .. "two"
            .. frame:end_prefix()
            .. "2\7"
        assert.are.same({
            { type = "output", bytes = "one" },
            { type = "end", status = 0 },
            { type = "output", bytes = "two" },
            { type = "end", status = 2 },
        }, frame:feed(bytes))
    end)

    it("quotes multiline fish eval input without shell interpolation", function()
        assert.are.equal('"echo \\$HOME\n\\"quoted\\""', Framing.quote_fish('echo $HOME\n"quoted"'))
    end)

    it("round-trips quoted multiline commands through fish", function()
        if vim.fn.executable("fish") ~= 1 then
            return
        end
        local frame = Framing.new("token")
        local command = "cd /tmp; printf '%s' '$HOME|\"quoted\"|back\\\\slash|line1\nline2'"
        local raw = vim.fn.system({ "fish", "-c", frame:wrap(command) })
        local events = frame:feed(raw)
        assert.are.same({
            { type = "output", bytes = '$HOME|"quoted"|back\\slash|line1\nline2' },
            { type = "end", status = 0, cwd = "/tmp" },
        }, events)
    end)

    it("does not evaluate parenthesized command text while quoting", function()
        if vim.fn.executable("fish") ~= 1 then
            return
        end
        local path = vim.fn.tempname()
        local frame = Framing.new("token")
        local literal = "(touch " .. path .. ")"
        local raw = vim.fn.system({ "fish", "-c", frame:wrap("printf '%s' '" .. literal .. "'") })
        assert.are.same({
            { type = "output", bytes = literal },
            { type = "end", status = 0, cwd = vim.uv.cwd() },
        }, frame:feed(raw))
        assert.are.equal(0, vim.fn.filereadable(path))
    end)

    it("finds the current fish token in worksheet input", function()
        assert.are.same(
            { commandline = "git che", base = "che", start_col = 7 },
            Completion.context({ "  git che" }, 1, { 1, 9 })
        )
        assert.are.same(
            { commandline = "cat alpha\\ fi", base = "alpha\\ fi", start_col = 7 },
            Completion.context({ "  cat alpha\\ fi" }, 1, { 1, 15 })
        )
        assert.are.same(
            { commandline = 'cat "al', base = '"al', start_col = 7 },
            Completion.context({ '  cat "al' }, 1, { 1, 9 })
        )
    end)

    it("handles multi-line completion without replacing across rows", function()
        assert.are.same(
            { commandline = "for x in one\n    ech", base = "ech", start_col = 5 },
            Completion.context({ "  for x in one", "    ech" }, 1, { 2, 7 })
        )
        assert.is_nil(Completion.context({ '  echo "alpha', "beta" }, 1, { 2, 4 }))
    end)

    it("keeps the currently typed option as a completion candidate", function()
        assert.are.same({
            { word = "-la", abbr = "-la", menu = "[fish]", dup = 0 },
            { word = "-la1", abbr = "-la1", menu = "[fish] list one file per line", dup = 0 },
        }, Completion.parse("-la1\tlist one file per line\r\n", "-la"))
        assert.are.same({
            { word = "-la", abbr = "-la", menu = "[fish] list all", dup = 0 },
        }, Completion.parse("-la\tlist all\r\n", "-la"))
        assert.are.same({
            { word = "-la", abbr = "-la", menu = "[fish] Show hidden", dup = 0 },
            { word = "-la1", abbr = "-la1", menu = "[fish] list one file per line", dup = 0 },
        }, Completion.parse_with_parent("-la1\tlist one file per line\r\n", "-la", "-la\tShow hidden\r\n"))
    end)

    it("parses escaped fish candidates and descriptions", function()
        assert.are.same({
            { word = "alpha\\ file", abbr = "alpha\\ file", menu = "[fish]", dup = 0 },
            { word = "lscpu", abbr = "lscpu", menu = "[fish]", dup = 0 },
            { word = "--version", abbr = "--version", menu = "[fish] display version", dup = 0 },
        }, Completion.parse("alpha\\ file\r\nlscpu\tcommand link\r\n--version\tdisplay version\r\n"))
    end)
end)
