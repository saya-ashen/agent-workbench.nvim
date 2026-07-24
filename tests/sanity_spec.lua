-- Sanity: proves the hermetic test harness can load pi.nvim modules from the
-- repo root (i.e. runtimepath is wired correctly by tests/minimal_init.lua).

describe("test harness sanity", function()
  it("loads a pi.nvim module", function()
    local ft = require "pi.filetypes"
    assert.are.equal("pi-chat-prompt", ft.prompt)
    assert.are.equal("pi-chat-history", ft.history)
  end)
end)
