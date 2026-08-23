-- Block-spacing rhythm for thinking blocks (issue #48).
--
-- A thinking block must leave exactly ONE blank line before whatever follows
-- it — text, a multi-line tool block, a direct `!` bash block, an inline tool,
-- or another thinking block. Previously it left two blanks before a tool/bash
-- block (those don't reuse a breathing blank the way text does), breaking the
-- rhythm. The fix makes the thinking block end like a tool block: one trailing
-- blank + the breathing-line flag.

local Config = require("agent-workbench.config")
local History = require("agent-workbench.ui.chat.history")

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

--- Number of consecutive blank lines immediately after the thinking header.
local function blanks_after_thinking(h)
    local hdr = find_line(h, "Thought for")
    assert.is_not_nil(hdr, "thinking header rendered")
    local lines = lines_of(h)
    local n = 0
    local i = hdr + 1
    while i <= #lines and lines[i] == "" do
        n = n + 1
        i = i + 1
    end
    return n, lines[i]
end

local function think(h)
    h:on_thinking_start()
    pump()
    h:on_thinking_delta("pondering the problem")
    pump(100)
    h:on_thinking_end()
    pump(100)
end

describe("thinking block spacing rhythm (issue #48)", function()
    before_each(function()
        Config.options.render = { markdown = { enabled = false } }
        Config.options.show_thinking = true
        require("agent-workbench.ui.render")._reset()
    end)

    after_each(function()
        Config.options.show_thinking = true
        Config.options.render = { markdown = { enabled = false } }
        require("agent-workbench.ui.render")._reset()
    end)

    it("leaves one blank line before following text", function()
        local h = History.new(940)
        h:on_agent_start(os.time())
        pump()
        think(h)
        h:on_text_delta("Here is the answer.")
        pump(200)

        local blanks, next = blanks_after_thinking(h)
        assert.are.equal(1, blanks, "exactly one blank before text")
        assert.are.equal("Here is the answer.", next)
    end)

    it("leaves one blank line before a following multi-line tool block", function()
        local h = History.new(941)
        h:on_agent_start(os.time())
        pump()
        think(h)
        h:on_tool_start("bash", "t1", { command = "ls -la" })
        pump()
        h:on_tool_end("bash", "t1", { content = { { type = "text", text = "ok" } } }, false)
        pump(150)

        local blanks, next = blanks_after_thinking(h)
        assert.are.equal(1, blanks, "exactly one blank before a tool block")
        assert.is_not_nil(next:find("bash", 1, true), "tool header follows")
    end)

    it("leaves one blank line before a following direct bash block", function()
        local h = History.new(942)
        h:on_agent_start(os.time())
        pump()
        think(h)
        h:on_bash_start("b1", "pwd", false)
        pump()
        h:on_bash_output("b1", "/home\n")
        pump(100)
        h:on_bash_end("b1", { output = "/home\n", exitCode = 0 })
        pump(150)

        local blanks, next = blanks_after_thinking(h)
        assert.are.equal(1, blanks, "exactly one blank before a bash block")
        assert.is_not_nil(next:find("$", 1, true), "bash header follows")
    end)

    it("leaves one blank line before a following inline tool", function()
        local h = History.new(943)
        h:on_agent_start(os.time())
        pump()
        think(h)
        h:on_tool_start("read", "r1", { path = "foo.lua" })
        pump()
        h:on_tool_end("read", "r1", { content = { { type = "text", text = "x\ny" } } }, false)
        pump(150)

        local blanks, next = blanks_after_thinking(h)
        assert.are.equal(1, blanks, "exactly one blank before an inline tool")
        assert.is_not_nil(next:find("read", 1, true), "inline tool follows")
    end)

    it("leaves one blank line between consecutive thinking blocks", function()
        local h = History.new(944)
        h:on_agent_start(os.time())
        pump()
        think(h)
        think(h)
        h:on_text_delta("Done.")
        pump(200)

        -- Gap after the FIRST thinking header (i.e. between the two headers).
        local lines = lines_of(h)
        local first = find_line(h, "Thought for")
        assert.is_not_nil(first)
        local blanks = 0
        local i = first + 1
        while i <= #lines and lines[i] == "" do
            blanks = blanks + 1
            i = i + 1
        end
        assert.are.equal(1, blanks, "exactly one blank between consecutive thinking blocks")
        assert.is_not_nil(lines[i]:find("Thought for", 1, true), "second thinking header follows")
    end)

    it("renders nothing for hidden thinking and does not error", function()
        Config.options.show_thinking = false
        local h = History.new(945)
        h:on_agent_start(os.time())
        pump()
        think(h)
        h:on_text_delta("Visible answer.")
        pump(200)

        assert.is_nil(find_line(h, "Thought for"), "no thinking header when hidden")
        assert.is_not_nil(find_line(h, "Visible answer."), "text still renders")
    end)

    it("still expands and collapses after the spacing change", function()
        local h = History.new(946)
        h:on_agent_start(os.time())
        pump()
        think(h)
        h:on_text_delta("After.")
        pump(200)

        local block = h._thinking_blocks[1]
        assert.is_not_nil(block)
        assert.is_true(block.visible)

        -- Expand: multi-line block replaces the single-line header.
        local changed = h:set_blocks_expanded(true)
        assert.is_true(changed)
        assert.is_true(block.expanded)

        -- Collapse back: single-line header restored, still followed by text.
        h:set_blocks_expanded(false)
        assert.is_false(block.expanded)
        assert.is_not_nil(find_line(h, "Thought for"), "header restored after collapse")
        assert.is_not_nil(find_line(h, "After."), "following text intact")
    end)

    it("thinking -> new turn has the same gap as text -> new turn", function()
        -- The turn-to-turn gap (controlled by turn_separator) must be identical
        -- whether the previous turn ended with thinking or with text (#48).
        local function turn_gap_after_thinking()
            local h = History.new(947)
            h:add_user_message("hi", os.time() * 1000, 0, nil)
            pump()
            h:on_agent_start(os.time() * 1000)
            pump()
            think(h)
            h:on_agent_end("Done")
            pump(100)
            h:on_agent_start(os.time() * 1000)
            pump()
            h:on_text_delta("Reply.")
            pump(200)
            local lines = lines_of(h)
            local hdr
            for i, l in ipairs(lines) do
                if l:find("Thought for", 1, true) then
                    hdr = i
                    break
                end
            end
            local next_agent
            for i = hdr + 1, #lines do
                if lines[i]:find("Reply", 1, true) then
                    -- Walk back to find the agent header above this text
                    for j = i - 1, hdr + 1, -1 do
                        if lines[j] ~= "" then
                            next_agent = j
                            break
                        end
                    end
                    break
                end
            end
            local blanks = 0
            for i = hdr + 1, (next_agent or #lines) - 1 do
                if lines[i] == "" then
                    blanks = blanks + 1
                end
            end
            return blanks
        end

        local function turn_gap_after_text()
            local h = History.new(948)
            h:add_user_message("hi", os.time() * 1000, 0, nil)
            pump()
            h:on_agent_start(os.time() * 1000)
            pump()
            h:on_text_delta("Hello!")
            pump(200)
            h:on_agent_end("Done")
            pump(100)
            h:on_agent_start(os.time() * 1000)
            pump()
            h:on_text_delta("More.")
            pump(200)
            local lines = lines_of(h)
            local text_row
            for i, l in ipairs(lines) do
                if l:find("Hello!", 1, true) then
                    text_row = i
                    break
                end
            end
            local next_agent
            for i = text_row + 1, #lines do
                if lines[i]:find("More", 1, true) then
                    for j = i - 1, text_row + 1, -1 do
                        if lines[j] ~= "" then
                            next_agent = j
                            break
                        end
                    end
                    break
                end
            end
            local blanks = 0
            for i = text_row + 1, (next_agent or #lines) - 1 do
                if lines[i] == "" then
                    blanks = blanks + 1
                end
            end
            return blanks
        end

        assert.are.equal(turn_gap_after_text(), turn_gap_after_thinking(), "turn gap must match")
    end)

    it("renders thinking blocks during session replay", function()
        -- Simulates what replay_messages does for an assistant message that
        -- contains a thinking part (issue: thinking blocks were silently
        -- dropped on resume because replay_messages never called
        -- on_thinking_start/delta/end).
        local h = History.new(949)
        h._replaying = true
        h:add_user_message("hello", os.time() * 1000, nil, nil)
        pump()
        h:on_agent_start(os.time() * 1000)
        pump()
        h:on_thinking_start({ unmeasured = true })
        pump()
        h:on_thinking_delta("Let me think about this.")
        pump(100)
        h:on_thinking_end()
        pump(100)
        h:on_tool_start("bash", "tc1", { command = "echo hi" })
        pump()
        h:on_tool_end("bash", "tc1", { content = { { type = "text", text = "hi" } } }, false)
        pump(150)
        h:on_agent_end()
        pump(100)
        h._replaying = false

        assert.are.equal(1, #h._thinking_blocks, "thinking block registered during replay")
        assert.is_not_nil(find_line(h, "Thought"), "thinking header rendered during replay")
        assert.is_nil(find_line(h, "Thought for"), "replayed header shows no fabricated duration")
    end)

    it("keeps each block's own content when replay dispatches back-to-back", function()
        -- Regression: replay_messages dispatches on_thinking_start/delta/end
        -- for every assistant message synchronously, with no event-loop turns
        -- in between. The pending-delta queue must attribute each delta to its
        -- own block (by generation); previously the first block's start
        -- callback drained ALL queued deltas, so later blocks froze empty and
        -- the first block showed merged content ("thought content disappears
        -- after resume").
        local h = History.new(950)
        h._replaying = true
        h:add_user_message("hello", os.time() * 1000, nil, nil)
        -- turn 1: thinking + tool call, then turn 2: thinking + text,
        -- dispatched consecutively exactly like replay_messages does.
        h:on_agent_start(os.time() * 1000)
        h:on_thinking_start({ unmeasured = true })
        h:on_thinking_delta("first block content")
        h:on_thinking_end()
        h:on_tool_start("bash", "tc1", { command = "echo hi" })
        h:on_tool_end("bash", "tc1", { content = { { type = "text", text = "hi" } } }, false)
        h:on_agent_start(os.time() * 1000)
        h:on_thinking_start({ unmeasured = true })
        h:on_thinking_delta("second block content")
        h:on_thinking_end()
        h:on_text_delta("answer")
        h:on_agent_end()
        pump(300)
        h._replaying = false

        assert.are.equal(2, #h._thinking_blocks, "both thinking blocks registered")
        local first = table.concat(h._thinking_blocks[1].lines, "\n")
        local second = table.concat(h._thinking_blocks[2].lines, "\n")
        assert.are.equal("first block content", first, "block 1 keeps only its own thinking")
        assert.are.equal("second block content", second, "block 2 keeps only its own thinking")

        -- Both frozen headers carry an end-of-line preview (non-empty content).
        assert.is_not_nil(h._thinking_blocks[1].virt_id, "block 1 preview set")
        assert.is_not_nil(h._thinking_blocks[2].virt_id, "block 2 preview set")

        -- Replayed blocks carry no timing data: bare header, no "for 0s".
        assert.are.equal("Thought", h._thinking_blocks[1].header, "block 1 header has no fabricated duration")
        assert.are.equal("Thought", h._thinking_blocks[2].header, "block 2 header has no fabricated duration")
    end)
end)
