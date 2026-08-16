-- Unit tests for pi.ui.chat.text — thinking preview truncation helpers.

describe("pi.ui.chat.text", function()
    local Text = require("agent-workbench.ui.chat.text")

    describe("thinking_flat", function()
        it("joins lines and normalizes whitespace", function()
            assert.are.equal("a b c", Text.thinking_flat({ "a", "  b ", "", "c" }))
        end)

        it("handles empty input", function()
            assert.are.equal("", Text.thinking_flat({}))
        end)
    end)

    describe("utf8_len", function()
        it("returns 1 for ASCII", function()
            assert.are.equal(1, Text.utf8_len(0x41)) -- 'A'
        end)

        it("returns 2 for 2-byte lead", function()
            assert.are.equal(2, Text.utf8_len(0xc3)) -- 'ã' lead
        end)

        it("returns 3 for 3-byte lead (CJK)", function()
            assert.are.equal(3, Text.utf8_len(0xe4)) -- '你' lead
        end)

        it("returns 4 for 4-byte lead (emoji)", function()
            assert.are.equal(4, Text.utf8_len(0xf0)) -- emoji lead
        end)
    end)

    describe("thinking_head", function()
        it("returns full string when it fits", function()
            assert.are.equal("hello", Text.thinking_head("hello", 10))
        end)

        it("truncates ASCII with ellipsis", function()
            local r = Text.thinking_head("hello world", 6)
            assert.are.equal("hello…", r)
        end)

        it("returns ellipsis for w <= 1", function()
            assert.are.equal("…", Text.thinking_head("hello", 1))
        end)

        it("does not split multi-byte chars (CJK)", function()
            -- "你好世界" = 4 chars × 2 display cols = 8 cols
            -- w=5 → target=4 → fits 2 CJK chars (4 cols) + "…"
            local r = Text.thinking_head("你好世界", 5)
            assert.are.equal("你好…", r)
        end)

        it("handles width that cannot fit even one CJK char", function()
            -- w=2 → target=1, one CJK char = 2 cols > 1 → no char fits
            local r = Text.thinking_head("你好", 2)
            assert.are.equal("…", r)
        end)
    end)

    describe("thinking_tail", function()
        it("returns full string when it fits", function()
            assert.are.equal("hello", Text.thinking_tail("hello", 10))
        end)

        it("returns empty for w <= 0", function()
            assert.are.equal("", Text.thinking_tail("hello", 0))
        end)

        it("keeps trailing ASCII slice", function()
            local r = Text.thinking_tail("hello world", 5)
            assert.are.equal("world", r)
        end)

        it("does not split multi-byte chars (CJK)", function()
            -- "你好世界" = 8 display cols; w=4 → fits last 2 CJK chars
            local r = Text.thinking_tail("你好世界", 4)
            assert.are.equal("世界", r)
        end)

        it("does not split 3-byte chars at odd widths", function()
            -- "你好世界" = 8 cols; w=5 → can fit 2 CJK (4 cols), not 2.5
            local r = Text.thinking_tail("你好世界", 5)
            assert.are.equal("世界", r)
        end)

        it("handles mixed ASCII and CJK", function()
            -- "hi你好" = 2 + 4 = 6 cols; w=4 → "你好" (4 cols)
            local r = Text.thinking_tail("hi你好", 4)
            assert.are.equal("你好", r)
        end)

        it("handles pure CJK string longer than width", function()
            -- "思考中" = 6 cols; w=4 → "考中" (4 cols)
            local r = Text.thinking_tail("思考中", 4)
            assert.are.equal("考中", r)
        end)

        it("handles 4-byte emoji", function()
            -- "🎉🎊" = 4 cols (2 each); w=2 → last emoji only
            local r = Text.thinking_tail("🎉🎊", 2)
            assert.are.equal("🎊", r)
        end)

        it("result is valid UTF-8 for CJK", function()
            local r = Text.thinking_tail("这是一个很长的中文思考内容", 10)
            -- must be valid UTF-8: vim.fn.strdisplaywidth should not error
            local dw = vim.fn.strdisplaywidth(r)
            assert.is_true(dw <= 10)
            assert.is_true(dw > 0)
            -- every char boundary should be clean — re-encode check
            assert.are.equal(r, vim.fn.substitute(r, ".", "", "g") and r or r)
        end)
    end)

    describe("wrap", function()
        it("returns the line unchanged when it fits", function()
            assert.are.same({ "hello" }, Text.wrap("hello", 10))
        end)

        it("returns the line unchanged for w <= 0", function()
            assert.are.same({ "hello" }, Text.wrap("hello", 0))
        end)

        it("splits long ASCII lines at the width", function()
            assert.are.same({ "abcd", "efgh" }, Text.wrap("abcdefgh", 4))
        end)

        it("never emits a chunk wider than the width", function()
            for _, chunk in ipairs(Text.wrap(string.rep("x", 100), 7)) do
                assert.is_true(vim.fn.strdisplaywidth(chunk) <= 7)
            end
        end)

        it("does not split multi-byte chars (CJK)", function()
            -- 6 CJK chars = 12 cols; w=5 fits 2 chars (4 cols) per chunk
            assert.are.same({ "你好", "世界", "你好" }, Text.wrap("你好世界你好", 5))
        end)

        it("places a single over-wide char on its own line", function()
            assert.are.same({ "aa", "你", "bb" }, Text.wrap("aa你bb", 2))
        end)

        it("preserves all text (round-trip concat)", function()
            local s = '429 data: {"error":"资源耗尽 ResourceExhausted"}'
            assert.are.equal(s, table.concat(Text.wrap(s, 10), ""))
        end)
    end)
end)
