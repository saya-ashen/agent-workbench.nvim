-- Unit tests for lua/pi/quickfix.lua

describe("pi.quickfix", function()
    local Quickfix
    local cwd

    before_each(function()
        package.loaded["pi.quickfix"] = nil
        package.loaded["pi.config"] = nil
        Quickfix = require("pi.quickfix")
        Quickfix._reset()
        cwd = vim.fn.getcwd()
        -- Start from an empty quickfix list
        vim.fn.setqflist({}, "r")
    end)

    after_each(function()
        vim.fn.setqflist({}, "r")
    end)

    local function qf()
        return vim.fn.getqflist()
    end

    describe("parse_grep", function()
        it("parses `path:line: text` (ripgrep format with trailing space)", function()
            local items = Quickfix.parse_grep("src/a.ts:1: export function alpha() {")
            assert.are.equal(1, #items)
            assert.are.equal(cwd .. "/src/a.ts", items[1].filename)
            assert.are.equal(1, items[1].lnum)
            assert.are.equal("export function alpha() {", items[1].text)
            assert.is_nil(items[1].col)
        end)

        it("parses multiple lines across files", function()
            local text = table.concat({
                "src/a.ts:1: export function alpha() {",
                "src/a.ts:4: export function beta() {",
                "src/c.ts:2: export function gamma() { return 3; }",
            }, "\n")
            local items = Quickfix.parse_grep(text)
            assert.are.equal(3, #items)
            assert.are.equal(cwd .. "/src/a.ts", items[1].filename)
            assert.are.equal(4, items[2].lnum)
            assert.are.equal(cwd .. "/src/c.ts", items[3].filename)
            assert.are.equal(2, items[3].lnum)
        end)

        it("parses `path:line:col:text` with a column", function()
            local items = Quickfix.parse_grep("src/a.ts:3:7:const x = 1")
            assert.are.equal(1, #items)
            assert.are.equal(3, items[1].lnum)
            assert.are.equal(7, items[1].col)
            assert.are.equal("const x = 1", items[1].text)
        end)

        it("parses `path:line:text` without a trailing space", function()
            local items = Quickfix.parse_grep("src/a.ts:3:const x = 1")
            assert.are.equal(1, #items)
            assert.are.equal(3, items[1].lnum)
            assert.is_nil(items[1].col)
            assert.are.equal("const x = 1", items[1].text)
        end)

        it("does not treat digit-leading text as a column when a space separates", function()
            -- The matched line itself starts with digits; the space after the line
            -- number marks it as text, not a column.
            local items = Quickfix.parse_grep("src/a.ts:5: 123: not a column")
            assert.are.equal(1, #items)
            assert.are.equal(5, items[1].lnum)
            assert.is_nil(items[1].col)
            assert.are.equal("123: not a column", items[1].text)
        end)

        it("keeps absolute paths untouched", function()
            local items = Quickfix.parse_grep("/etc/hosts:1:127.0.0.1 localhost")
            assert.are.equal("/etc/hosts", items[1].filename)
        end)

        it("skips lines that do not match the pattern", function()
            local text = table.concat({
                "src/a.ts:1: match",
                "some random notice line",
                "",
            }, "\n")
            local items = Quickfix.parse_grep(text)
            assert.are.equal(1, #items)
        end)
    end)

    describe("parse_files", function()
        it("parses one path per line", function()
            local items = Quickfix.parse_files("src/a.ts\nsrc/b.py")
            assert.are.equal(2, #items)
            assert.are.equal(cwd .. "/src/a.ts", items[1].filename)
            assert.are.equal(1, items[1].lnum)
            assert.are.equal(cwd .. "/src/b.py", items[2].filename)
        end)

        it("skips blank lines", function()
            local items = Quickfix.parse_files("src/a.ts\n\n  \nsrc/b.py\n")
            assert.are.equal(2, #items)
        end)
    end)

    describe("on_tool_end", function()
        local grep_result
        local find_result

        before_each(function()
            grep_result = {
                content = {
                    {
                        type = "text",
                        text = "src/a.ts:1: export function alpha() {\nsrc/a.ts:4: export function beta() {",
                    },
                },
            }
            find_result = { content = { { type = "text", text = "src/a.ts\nsrc/b.py" } } }
        end)

        it("fills the quickfix list for grep by default", function()
            Quickfix.on_tool_start("grep", "call_1", { pattern = "function" })
            Quickfix.on_tool_end("grep", "call_1", grep_result, false)

            local list = qf()
            assert.are.equal(2, #list)
            assert.are.equal(1, list[1].lnum)
            assert.are.equal("export function alpha() {", list[1].text)
            assert.are.equal(cwd .. "/src/a.ts", vim.fn.bufname(list[1].bufnr))
        end)

        it("titles the list with the stashed pattern", function()
            Quickfix.on_tool_start("grep", "call_1", { pattern = "function" })
            Quickfix.on_tool_end("grep", "call_1", grep_result, false)

            assert.are.equal("pi grep: function", vim.fn.getqflist({ title = 1 }).title)
        end)

        it("falls back to a plain title when no pattern was stashed", function()
            Quickfix.on_tool_end("grep", "call_x", grep_result, false)
            assert.are.equal("pi grep", vim.fn.getqflist({ title = 1 }).title)
        end)

        it("does not fill for find by default", function()
            Quickfix.on_tool_start("find", "call_1", { pattern = "**/*.py" })
            Quickfix.on_tool_end("find", "call_1", find_result, false)
            assert.are.equal(0, #qf())
        end)

        it("fills for find when enabled", function()
            require("pi.config").setup({ quickfix = { find = true } })
            Quickfix.on_tool_start("find", "call_1", { pattern = "**/*.py" })
            Quickfix.on_tool_end("find", "call_1", find_result, false)

            local list = qf()
            assert.are.equal(2, #list)
            assert.are.equal(cwd .. "/src/a.ts", vim.fn.bufname(list[1].bufnr))
            assert.are.equal("pi find: **/*.py", vim.fn.getqflist({ title = 1 }).title)
        end)

        it("treats glob as its own config key (alias of find)", function()
            -- glob stays disabled by default even when find is enabled
            require("pi.config").setup({ quickfix = { find = true } })
            Quickfix.on_tool_start("glob", "call_1", { pattern = "**/*.py" })
            Quickfix.on_tool_end("glob", "call_1", find_result, false)
            assert.are.equal(0, #qf())

            require("pi.config").setup({ quickfix = { glob = true } })
            Quickfix.on_tool_start("glob", "call_2", { pattern = "**/*.py" })
            Quickfix.on_tool_end("glob", "call_2", find_result, false)
            assert.are.equal(2, #qf())
        end)

        it("does not fill when grep is disabled", function()
            require("pi.config").setup({ quickfix = { grep = false } })
            Quickfix.on_tool_end("grep", "call_1", grep_result, false)
            assert.are.equal(0, #qf())
        end)

        it("does not fill on error", function()
            Quickfix.on_tool_end("grep", "call_1", grep_result, true)
            assert.are.equal(0, #qf())
        end)

        it("ignores non-search tools", function()
            Quickfix.on_tool_end("bash", "call_1", grep_result, false)
            assert.are.equal(0, #qf())
        end)

        it("does not fill when the result has no parseable entries", function()
            Quickfix.on_tool_end("grep", "call_1", { content = { { type = "text", text = "no matches" } } }, false)
            assert.are.equal(0, #qf())
        end)

        it("accepts string result content (replay format)", function()
            Quickfix.on_tool_end("grep", "call_1", { content = "src/a.ts:1: hello" }, false)
            assert.are.equal(1, #qf())
        end)
    end)
end)
