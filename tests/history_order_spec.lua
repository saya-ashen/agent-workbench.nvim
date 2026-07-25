-- Regression: thinking/tool blocks must render in stream order.
--
-- A thinking block is placed as [blank breathing line, header] and anchored
-- relative to the buffer's last line. Multi-line tools end in a blank footer
-- line, but inline tools (e.g. `read`) leave the last line as real content.
-- The thinking anchor must go *after* that content either way, otherwise a
-- thinking block following an inline tool gets inserted before it, reordering
-- the turn (thinking, thinking, tool instead of thinking, tool, thinking).

local Config = require "pi.config"
local History = require "pi.ui.chat.history"

local TAB = 901

local function pump(ms)
  vim.wait(ms or 30)
end

--- Rows (0-indexed) of every buffer line containing `sub`.
local function rows_with(buf, sub)
  local out = {}
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:find(sub, 1, true) then
      out[#out + 1] = i - 1
    end
  end
  return out
end

--- Drive: thinking -> tool -> thinking, return the history buffer.
local function render_thinking_tool_thinking(tool_name, tool_args, tool_result)
  local h = History.new(TAB)
  h:on_agent_start(nil)
  pump(50)

  h:on_thinking_start()
  pump()
  h:on_thinking_delta "first thinking"
  pump()
  h:on_thinking_end()
  pump(50)

  h:on_tool_start(tool_name, "t1", tool_args)
  pump()
  h:on_tool_end(tool_name, "t1", tool_result, false)
  pump(50)

  h:on_thinking_start()
  pump()
  h:on_thinking_delta "second thinking"
  pump()
  h:on_thinking_end()
  pump(80)

  return h:buf()
end

describe("thinking/tool render order", function()
  before_each(function()
    Config.options.show_thinking = true
  end)

  after_each(function()
    Config.options.show_thinking = false
  end)

  it("keeps an inline tool between two thinking blocks", function()
    local buf = render_thinking_tool_thinking("read", { path = "foo.lua" }, "l1\nl2\nl3")
    local thinkings = rows_with(buf, "Thought for")
    local tool = rows_with(buf, "foo.lua")
    assert.are.equal(2, #thinkings, "expected two thinking headers")
    assert.are.equal(1, #tool, "expected one inline tool line")
    assert.is_true(thinkings[1] < tool[1], "first thinking must precede the tool")
    assert.is_true(tool[1] < thinkings[2], "tool must precede the second thinking")
  end)

  it("keeps a multi-line tool between two thinking blocks", function()
    local buf = render_thinking_tool_thinking("bash", { command = "ls -la" }, "file1\nfile2")
    local thinkings = rows_with(buf, "Thought for")
    local tool = rows_with(buf, "bash")
    assert.are.equal(2, #thinkings, "expected two thinking headers")
    assert.is_true(#tool >= 1, "expected a bash tool header")
    assert.is_true(thinkings[1] < tool[1], "first thinking must precede the tool")
    assert.is_true(tool[1] < thinkings[2], "tool must precede the second thinking")
  end)
end)
