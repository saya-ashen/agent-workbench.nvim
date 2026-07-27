-- Regression: _update_status_extmark must not call nvim_win_text_height when
-- the conversation provably fills the window.
--
-- Root cause: nvim_win_text_height(win, {}) scans the whole buffer — O(n) —
-- and _update_status_extmark runs on every appended line (every streamed
-- delta, tool output batch, replay step) and every spinner tick (~80ms).
-- On large histories (~30k lines) each call costs ~17ms, saturating the main
-- loop so the whole window (prompt typing, cursor movement) stutters, and
-- making session replay O(n^2).
--
-- The result is only needed to pad the status block to the viewport bottom
-- when the conversation is SHORTER than the window. Visual height is always
-- >= buffer line count, so once lines fill the window the pad is provably 0.

local History = require "pi.ui.chat.history"

describe("history status extmark pad", function()
  local orig_win_text_height

  before_each(function()
    orig_win_text_height = vim.api.nvim_win_text_height
  end)

  after_each(function()
    vim.api.nvim_win_text_height = orig_win_text_height
  end)

  local function setup_history(tab, line_count)
    local h = History.new(tab)
    vim.api.nvim_win_set_buf(0, h:buf())
    h:set_win(0)
    h._status_text = "Working…"
    h._status_start_time = 1
    h:_with_modifiable(function()
      local lines = {}
      for i = 1, line_count do
        lines[i] = "line " .. i
      end
      vim.api.nvim_buf_set_lines(h:buf(), 0, -1, false, lines)
    end)
    return h
  end

  local function counted_calls(h)
    local calls = 0
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_win_text_height = function(...)
      calls = calls + 1
      return orig_win_text_height(...)
    end
    h:_update_status_extmark()
    return calls
  end

  it("skips nvim_win_text_height when lines fill the window", function()
    local text_rows = vim.api.nvim_win_get_height(0)
    local h = setup_history(960, text_rows + 100)
    assert.are_equal(0, counted_calls(h))
    assert.are_equal(0, h._status_pad)
  end)

  it("still pads via nvim_win_text_height for short conversations", function()
    local h = setup_history(961, 3)
    assert.are_equal(1, counted_calls(h))
    assert.is_true(h._status_pad > 0, "short conversation must be padded to viewport bottom")
  end)
end)
