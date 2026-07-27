-- Regression: render-markdown must not re-render the history buffer during replay.
--
-- render-markdown.nvim re-renders the whole buffer on every TextChanged. A
-- session replay makes hundreds of buffer edits, so leaving it active makes
-- loading a large session hang (each edit re-parses the growing buffer, O(n^2)).
-- The fix pauses render-markdown for the history buffer while replaying and
-- re-enables it (rendering once) afterwards. These specs pin the safe no-op
-- behavior of the pause/resume helpers when the engine is builtin or when
-- render-markdown is not installed, so they can never error in those setups.

local Config = require "pi.config"
local Render = require "pi.ui.render"

describe("render pause/resume", function()
  local saved_engine

  before_each(function()
    saved_engine = Config.options.render and Config.options.render.engine
    Config.options.render = Config.options.render or {}
  end)

  after_each(function()
    Config.options.render.engine = saved_engine
    Render._reset()
  end)

  it("engine defaults to builtin", function()
    Config.options.render.engine = nil
    assert.equals("builtin", Render.engine())
  end)

  it("pause/resume are safe no-ops for the builtin engine", function()
    Config.options.render.engine = "builtin"
    local buf = vim.api.nvim_create_buf(false, true)
    assert.has_no.errors(function()
      Render.pause_history(buf)
      Render.resume_history(buf)
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("pause/resume do not error when render-markdown is requested but missing", function()
    Config.options.render.engine = "render-markdown"
    -- render-markdown is not on the test runtimepath, so the manager require
    -- fails internally; the helpers must swallow that and not raise.
    local buf = vim.api.nvim_create_buf(false, true)
    assert.has_no.errors(function()
      Render.pause_history(buf)
      Render.resume_history(buf)
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("pause/resume ignore an invalid buffer", function()
    Config.options.render.engine = "render-markdown"
    assert.has_no.errors(function()
      Render.pause_history(999999)
      Render.resume_history(999999)
    end)
  end)
end)
