-- Unit spec template (hermetic plenary). Copy to tests/<name>_spec.lua.
--
-- RULES (see references/gotchas.md G14, references/testing.md "Layer 1"):
--   * before_each / after_each MUST live inside a describe() — at top level they
--     silently no-op AND fail the run with no clear message.
--   * Keep the module under test free of UI; redirect any file it writes to a
--     temp path via its _set_path-style hook so the real stdpath is untouched.
--   * Reset singletons in after_each so specs don't leak state.

describe("pi.<module>", function()
  local Mod = require "pi.<module>"

  before_each(function()
    -- If the module persists to disk, point it at a throwaway file:
    -- Mod._set_path(vim.fn.tempname() .. "/x.json")
    if Mod._reset then
      Mod._reset()
    end
  end)

  after_each(function()
    -- Mod._set_path(nil)
    if Mod._reset then
      Mod._reset()
    end
  end)

  describe("behavior", function()
    it("does the thing", function()
      assert.are.equal("want", "want")
    end)

    it("returns nil when empty", function()
      assert.is_nil(nil)
    end)
  end)
end)
