local Ansi = require("agent-workbench.ui.chat.terminal.ansi")

describe("shell ANSI parser", function()
    it("keeps text exact while recording basic styles", function()
        local result = Ansi.parse("plain \27[1;31mred\27[0m end\r\n")

        assert.is_true(result.valid)
        assert.are.same({ "plain red end" }, result.lines)
        assert.are.equal(1, #result.spans)
        assert.are.same({ row = 0, start_col = 6, end_col = 9, style = { fg = 1, bold = true } }, result.spans[1])
    end)

    it("supports indexed colors, true color, and intentional blank lines", function()
        local result = Ansi.parse("\27[38;5;208mA\27[38;2;1;2;3mB\27[0m\r\n\r\n")

        assert.is_true(result.valid)
        assert.are.same({ "AB", "" }, result.lines)
        assert.are.same({
            { row = 0, start_col = 0, end_col = 1, style = { fg = 208 } },
            { row = 0, start_col = 1, end_col = 2, style = { fg = "#010203" } },
        }, result.spans)
    end)

    it("records faint intensity independently from color", function()
        local result = Ansi.parse("\27[2;31mdim\27[22m normal\27[0m")

        assert.is_true(result.valid)
        assert.are.same({ "dim normal" }, result.lines)
        assert.are.same({
            { row = 0, start_col = 0, end_col = 3, style = { fg = 1, faint = true } },
            { row = 0, start_col = 3, end_col = 10, style = { fg = 1 } },
        }, result.spans)
    end)

    it("records OSC 8 links without exposing control bytes", function()
        local result = Ansi.parse("\27]8;;https://example.com\7link\27]8;;\7\n")

        assert.is_true(result.valid)
        assert.are.same({ "link" }, result.lines)
        assert.are.same({
            {
                row = 0,
                start_col = 0,
                end_col = 4,
                style = { link = "https://example.com" },
            },
        }, result.spans)
    end)

    it("caps style spans while preserving all parsed text", function()
        local chunks = {}
        for index = 1, 100 do
            chunks[#chunks + 1] = ("\27[38;5;%dmx\27[0m"):format(index)
        end
        local result = Ansi.parse(table.concat(chunks), 5)

        assert.is_true(result.valid)
        assert.are.equal(string.rep("x", 100), result.lines[1])
        assert.are.equal(5, #result.spans)
    end)

    it("marks cursor-moving output unsafe for style projection", function()
        local result = Ansi.parse("10%\r20%\n")

        assert.is_false(result.valid)
    end)
end)
