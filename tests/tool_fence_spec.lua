-- Unit tests: tool output code-fence wrapping for the render-markdown engine.
--
-- When render.engine == "render-markdown", render_output() wraps tool output
-- in a fenced code block so render-markdown.nvim does not misinterpret shell
-- comments (# ...) as markdown headings.  The fence length adapts to the
-- content (fence nesting).  The builtin engine keeps the existing behaviour
-- (no wrapping, auto-close odd fences).

local Config = require "pi.config"
local History = require "pi.ui.chat.history"
local Render = require "pi.ui.render"

local TAB = 910

local function pump(ms)
  vim.wait(ms or 50)
end

local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Rows (0-indexed) of every buffer line containing `sub` (plain match).
local function rows_with(buf, sub)
  local out = {}
  for i, l in ipairs(lines_of(buf)) do
    if l:find(sub, 1, true) then
      out[#out + 1] = i - 1
    end
  end
  return out
end

--- Rows (0-indexed) of buffer lines exactly equal to `text`.
local function rows_exact(buf, text)
  local out = {}
  for i, l in ipairs(lines_of(buf)) do
    if l == text then
      out[#out + 1] = i - 1
    end
  end
  return out
end

--- Create a History with tool-block collapsing disabled so buffer lines
--- are the raw rendered output (easier to assert on).
---@return pi.ChatHistory
local function new_history()
  local h = History.new(TAB)
  h._blocks_expanded = true
  return h
end

--- Fire a bash tool call through the standard on_tool_start / on_tool_end path.
---@param h pi.ChatHistory
---@param output string  tool result text
local function bash_tool(h, output)
  h:on_tool_start("bash", "call1", { command = "echo hi" })
  pump()
  h:on_tool_end("bash", "call1", {
    content = { { type = "text", text = output } },
  }, false)
  pump()
end

--- Fire an unknown tool (hits the default renderer) through on_tool_start/end.
---@param h pi.ChatHistory
---@param output string
local function unknown_tool(h, output)
  h:on_tool_start("my_custom_tool", "call2", { query = "test" })
  pump()
  h:on_tool_end("my_custom_tool", "call2", {
    content = { { type = "text", text = output } },
  }, false)
  pump()
end

describe("tool output fence wrapping", function()
  after_each(function()
    Config.options.render = { engine = "builtin" }
    Render._reset()
  end)

  -- ── builtin engine: existing behaviour, no wrapping ──────────────

  describe("builtin engine", function()
    before_each(function()
      Config.options.render = { engine = "builtin" }
    end)

    it("does not wrap output in code fences", function()
      local h = new_history()
      bash_tool(h, "hello\n# a comment\nworld")
      local buf = h:buf()
      assert.is_true(#rows_with(buf, "# a comment") == 1, "comment line present")
      assert.is_true(#rows_with(buf, "```") == 0, "no fence lines")
    end)

    it("auto-closes odd fences in output", function()
      local h = new_history()
      bash_tool(h, "before\n```lua\nprint(1)")
      local buf = h:buf()
      -- The odd fence gets an auto-closing ``` appended
      local fence_rows = rows_with(buf, "```")
      assert.is_true(#fence_rows >= 2, "original + auto-closed fence")
    end)
  end)

  -- ── render-markdown engine: fence wrapping ───────────────────────

  describe("render-markdown engine", function()
    before_each(function()
      Config.options.render = { engine = "render-markdown" }
    end)

    it("wraps bash output in a bare code fence (no language tag)", function()
      local h = new_history()
      bash_tool(h, "hello\n# a comment\nworld")
      local buf = h:buf()
      -- Both opening and closing fences are bare ``` (no language tag),
      -- so exactly two lines equal "```".
      assert.is_true(#rows_exact(buf, "```") == 2, "open + close bare fences")
      assert.is_true(#rows_with(buf, "```bash") == 0, "no language tag on fence")
      -- content is between the fences
      assert.is_true(#rows_with(buf, "# a comment") == 1, "content preserved")
    end)

    it("does not auto-close fences inside the wrapper", function()
      local h = new_history()
      -- Output has one ``` line — inside the wrapper it is literal text.
      bash_tool(h, "before\n```lua\nprint(1)")
      local buf = h:buf()
      -- No "← auto-closed" annotation should appear
      assert.is_true(#rows_with(buf, "auto-closed") == 0, "no auto-close inside wrapper")
    end)

    it("uses longer fences when output contains ```", function()
      local h = new_history()
      bash_tool(h, "line1\n```\nsome code\n```\nline2")
      local buf = h:buf()
      -- Output contains ``` (3 backticks), so wrapper must use ```` (4),
      -- bare on both open and close.
      assert.is_true(#rows_exact(buf, "````") == 2, "open + close use 4 backticks")
      assert.is_true(#rows_with(buf, "````bash") == 0, "no language tag")
    end)

    it("uses even longer fences for output with ````", function()
      local h = new_history()
      bash_tool(h, "line1\n````\ncode\n````\nline2")
      local buf = h:buf()
      assert.is_true(#rows_exact(buf, "`````") == 2, "open + close use 5 backticks")
      assert.is_true(#rows_with(buf, "`````bash") == 0, "no language tag")
    end)

    it("wraps default-renderer output without a language tag", function()
      local h = new_history()
      unknown_tool(h, "# heading-like\nplain text")
      local buf = h:buf()
      -- Opening fence should be bare ``` (no language)
      assert.is_true(#rows_exact(buf, "```") >= 1, "bare fence present")
      -- Should NOT have ```text or similar — just bare fences
      assert.is_true(#rows_with(buf, "```text") == 0, "no language tag for unknown tools")
      assert.is_true(#rows_with(buf, "# heading-like") == 1, "content preserved")
    end)

    -- Regression: collapsed view must not leak orphan fence lines.
    -- When output_visible < #actual_output, the collapsed summary shows
    -- "…N lines" + the last visible line(s).  The render-markdown engine
    -- intentionally wraps the visible output in a paired code fence to
    -- prevent setext-heading misparsing (e.g. === lines).  The key
    -- invariant is that fences always come in pairs — an odd count means
    -- an orphan leaked from the expanded view's render_output() fences.
    it("collapsed view has no orphan fence lines", function()
      -- Use a NON-expanded history so _maybe_collapse_tool fires.
      local h = History.new(TAB)
      -- 10 lines of output → exceeds bash output_visible (1) → collapses
      local output = table.concat({
        "line1", "line2", "line3", "line4", "line5",
        "line6", "line7", "line8", "line9", "line10",
      }, "\n")
      bash_tool(h, output)
      local buf = h:buf()
      local lines = lines_of(buf)
      -- Fence lines must come in pairs (no orphans)
      local fence_count = 0
      for _, l in ipairs(lines) do
        if l:match("^%s*`+$") then
          fence_count = fence_count + 1
        end
      end
      assert.is_true(fence_count % 2 == 0,
        ("orphan fence: %d fence lines (odd)"):format(fence_count))
      -- The visible output line should be real content, not a fence
      assert.is_true(#rows_with(buf, "line10") == 1, "last real output line visible")
      -- Summary count should reflect 10 real lines minus 1 visible = 9
      assert.is_true(#rows_with(buf, "…9 lines") == 1, "correct collapsed count")
    end)

    it("collapsed view for inline+block pair has no orphan fences", function()
      local h = History.new(TAB)
      -- inline read followed by bash with collapsible output
      h:on_tool_start("read", "r1", { path = "/tmp/x.lua" })
      pump()
      h:on_tool_end("read", "r1", {
        content = { { type = "text", text = "a\nb\nc" } },
      }, false)
      pump()
      local output = table.concat({
        "o1", "o2", "o3", "o4", "o5",
      }, "\n")
      bash_tool(h, output)
      local buf = h:buf()
      local fence_count = 0
      for _, l in ipairs(lines_of(buf)) do
        if l:match("^%s*`+$") then
          fence_count = fence_count + 1
        end
      end
      assert.is_true(fence_count % 2 == 0,
        ("orphan fence: %d fence lines (odd)"):format(fence_count))
    end)
  end)
end)
