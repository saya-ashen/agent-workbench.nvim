-- Unit tests for pi.prompt_history (pure Lua, no UI).

local PH = require "pi.prompt_history"

--- Create an in-memory store.
local function mem(max)
  return PH.Store.new { path = false, max = max }
end

--- Create a file-backed store under a fresh temp path.
local function file_store(max)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/history.json"
  return PH.Store.new { path = path, max = max }, path
end

describe("prompt_history: add", function()
  it("stores entries newest-last", function()
    local s = mem()
    s:add "one"
    s:add "two"
    assert.are.same({ "one", "two" }, s:entries())
    assert.are.equal(2, s:size())
  end)

  it("ignores empty and whitespace-only entries", function()
    local s = mem()
    s:add ""
    s:add "   "
    s:add "\n\t "
    assert.are.equal(0, s:size())
  end)

  it("ignores non-string input", function()
    local s = mem()
    s:add(nil)
    s:add(42)
    assert.are.equal(0, s:size())
  end)

  it("dedupes consecutive duplicates", function()
    local s = mem()
    s:add "same"
    s:add "same"
    s:add "same"
    assert.are.same({ "same" }, s:entries())
    s:add "other"
    s:add "same" -- non-consecutive dup is kept
    assert.are.same({ "same", "other", "same" }, s:entries())
  end)

  it("preserves multi-line entries", function()
    local s = mem()
    s:add "line1\nline2\nline3"
    assert.are.same({ "line1\nline2\nline3" }, s:entries())
  end)

  it("enforces the cap by dropping the oldest", function()
    local s = mem(3)
    for i = 1, 5 do
      s:add("e" .. i)
    end
    assert.are.same({ "e3", "e4", "e5" }, s:entries())
  end)
end)

describe("prompt_history: navigation", function()
  it("prev returns nil on an empty store", function()
    local s = mem()
    assert.is_nil(s:prev "draft")
    assert.is_false(s:navigating())
  end)

  it("prev walks toward older entries and stashes the draft", function()
    local s = mem()
    s:add "one"
    s:add "two"
    s:add "three"
    assert.are.equal("three", s:prev "draft")
    assert.is_true(s:navigating())
    assert.are.equal("two", s:prev())
    assert.are.equal("one", s:prev())
    -- at oldest: no further change
    assert.is_nil(s:prev())
    assert.are.equal("one", s:prev() or "one")
  end)

  it("next walks back and restores the stashed draft at the present", function()
    local s = mem()
    s:add "one"
    s:add "two"
    assert.are.equal("two", s:prev "my draft")
    assert.are.equal("one", s:prev())
    assert.are.equal("two", s:next())
    -- back to present: draft restored, navigation ends
    assert.are.equal("my draft", s:next())
    assert.is_false(s:navigating())
  end)

  it("next is a no-op when not navigating", function()
    local s = mem()
    s:add "one"
    assert.is_nil(s:next())
  end)

  it("add resets navigation", function()
    local s = mem()
    s:add "one"
    s:prev "draft"
    assert.is_true(s:navigating())
    s:add "two"
    assert.is_false(s:navigating())
  end)

  it("reset_nav leaves navigation", function()
    local s = mem()
    s:add "one"
    s:prev "draft"
    s:reset_nav()
    assert.is_false(s:navigating())
    -- a fresh prev starts from newest again
    assert.are.equal("one", s:prev "x")
  end)
end)

describe("prompt_history: persistence", function()
  it("round-trips entries through disk", function()
    local s, path = file_store()
    s:add "alpha"
    s:add "multi\nline"
    -- a brand-new store at the same path loads what was saved
    local s2 = PH.Store.new { path = path }
    assert.are.same({ "alpha", "multi\nline" }, s2:entries())
  end)

  it("enforces the cap on load", function()
    local s, path = file_store()
    for i = 1, 10 do
      s:add("e" .. i)
    end
    local s2 = PH.Store.new { path = path, max = 3 }
    assert.are.same({ "e8", "e9", "e10" }, s2:entries())
  end)

  it("ignores a corrupt file", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/history.json"
    local f = io.open(path, "w")
    f:write "{ this is not valid json ]"
    f:close()
    local s = PH.Store.new { path = path }
    assert.are.equal(0, s:size())
  end)

  it("ignores a missing file", function()
    local s = PH.Store.new { path = vim.fn.tempname() .. "/nope.json" }
    assert.are.equal(0, s:size())
  end)

  it("clear empties and persists", function()
    local s, path = file_store()
    s:add "x"
    s:clear()
    assert.are.equal(0, s:size())
    local s2 = PH.Store.new { path = path }
    assert.are.equal(0, s2:size())
  end)
end)
