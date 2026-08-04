-- Block-spacing rhythm for the agent label line (on_agent_start).
--
-- The agent label must leave exactly ONE blank line before whatever follows
-- it — streamed text, an inline tool, a multi-line tool block, or a thinking
-- block. Previously it left two trailing blanks and relied on the next text
-- delta reusing one (_append_text writes into the last blank line); a
-- tool/bash/thinking follower reused none, so those turns showed a two-line
-- gap under the label while text turns showed one. The fix makes the label
-- end like a tool block (issue #48): one trailing blank + the breathing-line
-- flag.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")

local function pump(ms)
    vim.wait(ms or 60)
end

local function lines_of(h)
    return vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
end

--- Index (1-based) of the first line containing `sub`, or nil.
local function find_line(h, sub)
    for i, l in ipairs(lines_of(h)) do
        if l:find(sub, 1, true) then
            return i
        end
    end
    return nil
end

--- Number of consecutive blank lines immediately after the agent label line.
local function blanks_after_label(h)
    local hdr = find_line(h, "16:49")
    assert.is_not_nil(hdr, "agent label rendered")
    local lines = lines_of(h)
    local n = 0
    local i = hdr + 1
    while i <= #lines and lines[i] == "" do
        n = n + 1
        i = i + 1
    end
    return n, lines[i]
end

local ts = os.time({ year = 2026, month = 8, day = 4, hour = 16, min = 49, sec = 0 }) * 1000

describe("agent label spacing rhythm", function()
    before_each(function()
        Config.options.render = { engine = "builtin" }
        Config.options.show_thinking = true
        require("pi.ui.render")._reset()
    end)

    after_each(function()
        Config.options.show_thinking = true
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    it("leaves one blank line before following text", function()
        local h = History.new(960)
        h:on_agent_start(ts)
        pump()
        h:on_text_delta("Now let me read the design document.")
        pump(200)

        local blanks, next = blanks_after_label(h)
        assert.are.equal(1, blanks, "exactly one blank before text")
        assert.are.equal("Now let me read the design document.", next)
    end)

    it("leaves one blank line before a following inline tool", function()
        local h = History.new(961)
        h:on_agent_start(ts)
        pump()
        h:on_tool_start("read", "r1", { path = "foo.lua" })
        pump()
        h:on_tool_end("read", "r1", { content = { { type = "text", text = "x\ny" } } }, false)
        pump(150)

        local blanks, next = blanks_after_label(h)
        assert.are.equal(1, blanks, "exactly one blank before an inline tool")
        assert.is_not_nil(next:find("read", 1, true), "inline tool follows")
    end)

    it("leaves one blank line before a following multi-line tool block", function()
        local h = History.new(962)
        h:on_agent_start(ts)
        pump()
        h:on_tool_start("bash", "t1", { command = "ls -la" })
        pump()
        h:on_tool_end("bash", "t1", { content = { { type = "text", text = "ok" } } }, false)
        pump(150)

        local blanks, next = blanks_after_label(h)
        assert.are.equal(1, blanks, "exactly one blank before a tool block")
        assert.is_not_nil(next:find("bash", 1, true), "tool header follows")
    end)

    it("leaves one blank line before a following thinking block", function()
        local h = History.new(963)
        h:on_agent_start(ts)
        pump()
        h:on_thinking_start()
        pump()
        h:on_thinking_delta("pondering")
        pump(100)
        h:on_thinking_end()
        pump(100)

        local blanks, next = blanks_after_label(h)
        assert.are.equal(1, blanks, "exactly one blank before a thinking block")
        assert.is_not_nil(next:find("Thought for", 1, true), "thinking header follows")
    end)
end)
