-- Tests for the history-side of the statusline refactor:
-- * the history status extmark renders ONLY the pending-queue preview
--   (spinner/abort rows moved to the prompt statusline), with no bottom
--   padding and no whole-buffer scans on the hot path (G22);
-- * the busy display model and queue count are pushed to listeners.

local Config = require "pi.config"
local History = require "pi.ui.chat.history"

local ns = vim.api.nvim_create_namespace("pi-chat")
local TAB = 960

local function pump(ms)
  vim.wait(ms or 30)
end

describe("history queue status rendering", function()
  local saved_spinner

  before_each(function()
    saved_spinner = Config.options.spinner
  end)

  after_each(function()
    Config.options.spinner = saved_spinner
  end)

  local function setup_history(line_count)
    local h = History.new(TAB)
    vim.api.nvim_win_set_buf(0, h:buf())
    h:set_win(0)
    if line_count and line_count > 1 then
      h:_with_modifiable(function()
        local lines = {}
        for i = 1, line_count do
          lines[i] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(h:buf(), 0, -1, false, lines)
      end)
    end
    return h
  end

  local function status_virt_lines(h)
    local marks = vim.api.nvim_buf_get_extmarks(h:buf(), ns, 0, -1, { details = true })
    for _, m in ipairs(marks) do
      if m[4].virt_lines then
        return m[4].virt_lines
      end
    end
    return nil
  end

  it("renders no status extmark when the queue is empty", function()
    local h = setup_history(5)
    h:set_status({ type = "agent", text = "Working…" })
    pump(50)
    h:_update_status_extmark()
    assert.is_nil(status_virt_lines(h))
    assert.are.equal(0, h._status_virt_line_count)
  end)

  it("never calls nvim_win_text_height on the append hot path (G22)", function()
    local h = setup_history(200)
    h:set_status({ type = "agent", text = "Working…" })
    pump(50)

    local orig = vim.api.nvim_win_text_height
    local calls = 0
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_win_text_height = function(...)
      calls = calls + 1
      return orig(...)
    end
    local ok = pcall(function()
      h:_append_lines({ "streamed" })
      h:_update_status_extmark()
    end)
    vim.api.nvim_win_text_height = orig
    assert.is_true(ok)
    assert.are.equal(0, calls)
  end)

  it("renders a blank margin line plus one row per queue entry", function()
    local h = setup_history(3)
    h:add_pending_queue_entry("follow_up", "first queued", "first queued")
    h:add_pending_queue_entry("steer", "second queued", "second queued")
    local virt_lines = status_virt_lines(h)
    assert.is_not_nil(virt_lines)
    assert.are.equal(3, #virt_lines) -- 1 blank + 2 rows
    local row_text = ""
    for _, chunk in ipairs(virt_lines[2]) do
      row_text = row_text .. chunk[1]
    end
    assert.is_not_nil(row_text:find("first queued", 1, true))

    h:remove_pending_queue_entry("first queued")
    virt_lines = status_virt_lines(h)
    assert.are.equal(2, #virt_lines) -- 1 blank + 1 row

    h:clear_pending_queue()
    assert.is_nil(status_virt_lines(h))
  end)

  it("pushes the busy display model to the status listener", function()
    Config.options.spinner = { refresh_rate = 10, frames = { "a", "b", "c" } }
    local h = setup_history(3)
    -- NB: models[#models + 1] = nil would be a no-op, so mark clears.
    ---@type (pi.StatusLineBusy|string)[]
    local models = {}
    h:set_status_listener(function(model)
      models[#models + 1] = model or "CLEARED"
    end)

    h:set_status({ type = "agent", text = "Working…" })
    pump(50)
    assert.is_true(#models >= 1)
    assert.are.equal("Working…", models[1].text)
    assert.are.equal("a", models[1].frame)
    assert.is_false(models[1].thinking)

    -- Spinner ticks push updated frames.
    vim.wait(60)
    assert.is_true(#models >= 2)

    h:set_status(nil)
    pump(50)
    assert.are.equal("CLEARED", models[#models])
  end)

  it("marks the busy model as thinking during thinking blocks", function()
    local h = setup_history(3)
    ---@type pi.StatusLineBusy?[]
    local models = {}
    h:set_status_listener(function(model)
      models[#models + 1] = model
    end)
    h:set_status({ type = "agent", text = "Working…" })
    pump(50)

    h:on_thinking_start()
    pump(50)
    assert.is_true(models[#models].thinking)

    h:on_thinking_end()
    pump(50)
    assert.is_false(models[#models].thinking)
  end)

  it("pushes queue counts to the queue listener", function()
    local h = setup_history(3)
    local counts = {}
    h:set_queue_listener(function(count)
      counts[#counts + 1] = count
    end)
    h:add_pending_queue_entry("follow_up", "one", "one")
    h:add_pending_queue_entry("steer", "two", "two")
    h:remove_pending_queue_entry("one")
    h:clear_pending_queue()
    assert.are.same({ 1, 2, 1, 0 }, counts)
  end)

  it("keeps a two-blank margin after the thinking header (settles to one)", function()
    Config.options.show_thinking = true
    -- Case 1: buffer ends with a breathing blank — it becomes the 2nd margin.
    local h = setup_history(1)
    h:on_thinking_start()
    pump(50)
    local lines = vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
    assert.are.equal(4, #lines) -- blank, header, 2 margin blanks
    assert.are.equal("", lines[3])
    assert.are.equal("", lines[4])

    -- The next text delta reuses the final blank, leaving exactly one blank
    -- line of separation after the header.
    h:_append_text("answer")
    lines = vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
    assert.are.equal(4, #lines)
    assert.are.equal("", lines[3])
    assert.are.equal("answer", lines[4])

    -- Case 2: buffer ends with real content (e.g. an inline tool) — both
    -- margin blanks are inserted.
    local h2 = setup_history(1)
    h2:_with_modifiable(function()
      vim.api.nvim_buf_set_lines(h2:buf(), 0, -1, false, { "read tool output" })
    end)
    h2:on_thinking_start()
    pump(50)
    lines = vim.api.nvim_buf_get_lines(h2:buf(), 0, -1, false)
    assert.are.equal(5, #lines) -- content, blank, header, 2 margin blanks
    assert.are.equal("", lines[4])
    assert.are.equal("", lines[5])
  end)
end)
