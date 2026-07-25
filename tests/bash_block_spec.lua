-- Direct bash execution blocks (! commands): header, streamed output with
-- partial-line joining, completion statuses, truncation replacement, replay.

local History = require "pi.ui.chat.history"

local TAB = 902

local function pump(ms)
  vim.wait(ms or 30)
end

local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function text_of(buf)
  return table.concat(lines_of(buf), "\n")
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

describe("bash execution block", function()
  it("renders the command header with a $ prefix", function()
    local h = History.new(TAB)
    h:on_bash_start("b1", "ls -la", false)
    pump(50)
    local buf = h:buf()
    assert.is_true(#rows_with(buf, "$ ls -la") == 1, "expected one header line")
  end)

  it("renders multi-line commands as header plus indented body", function()
    local h = History.new(TAB)
    h:on_bash_start("b1", "for i in 1 2; do\n  echo $i\ndone", false)
    pump(50)
    local buf = h:buf()
    assert.is_true(#rows_with(buf, "$ for i in 1 2; do") == 1)
    assert.is_true(#rows_with(buf, "echo $i") == 1)
    assert.is_true(#rows_with(buf, "done") == 1)
  end)

  it("joins partial lines across streamed chunks", function()
    local h = History.new(TAB)
    h:on_bash_start("b1", "cmd", false)
    pump(50)
    h:on_bash_output("b1", "hel")
    pump(50)
    local buf = h:buf()
    -- Incomplete line is shown live
    assert.is_true(#rows_exact(buf, "hel") == 1, "partial line rendered live")

    h:on_bash_output("b1", "lo\nwor")
    pump(50)
    assert.is_true(#rows_exact(buf, "hello") == 1, "completed line flushed")
    assert.is_true(#rows_exact(buf, "wor") == 1, "next partial rendered")
    assert.is_true(#rows_exact(buf, "hel") == 0, "stale partial replaced")

    h:on_bash_output("b1", "ld\n")
    pump(50)
    assert.is_true(#rows_exact(buf, "world") == 1, "final line flushed")

    h:on_bash_end("b1", { output = "hello\nworld\n", exitCode = 0, cancelled = false, truncated = false })
    pump(50)
    assert.is_true(#rows_with(buf, "(exit") == 0, "silent success footer")
    assert.is_true(#rows_with(buf, "(cancelled)") == 0)
  end)

  it("shows non-zero exit codes", function()
    local h = History.new(TAB)
    h:on_bash_start("b1", "false", false)
    pump(50)
    h:on_bash_end("b1", { output = "", exitCode = 3, cancelled = false, truncated = false })
    pump(50)
    assert.is_true(#rows_with(h:buf(), "(exit 3)") == 1)
  end)

  it("shows cancelled status", function()
    local h = History.new(TAB)
    h:on_bash_start("b1", "sleep 10", false)
    pump(50)
    h:on_bash_end("b1", { output = "", exitCode = vim.NIL, cancelled = true, truncated = false })
    pump(50)
    assert.is_true(#rows_with(h:buf(), "(cancelled)") == 1)
  end)

  it("shows RPC-level errors", function()
    local h = History.new(TAB)
    h:on_bash_start("b1", "cmd", false)
    pump(50)
    h:on_bash_end("b1", { error = "Process not running" })
    pump(50)
    assert.is_true(#rows_with(h:buf(), "Process not running") == 1)
  end)

  it("replaces streamed output with truncated backend output", function()
    local h = History.new(TAB)
    h:on_bash_start("b1", "big", false)
    pump(50)
    h:on_bash_output("b1", "streamed-line-1\nstreamed-line-2\n")
    pump(50)
    h:on_bash_end("b1", {
      output = "tail-line\n",
      exitCode = 0,
      cancelled = false,
      truncated = true,
      fullOutputPath = "/tmp/pi-bash-full.log",
    })
    pump(50)
    local buf = h:buf()
    assert.is_true(#rows_with(buf, "streamed-line-1") == 0, "streamed lines replaced")
    assert.is_true(#rows_with(buf, "tail-line") == 1, "truncated tail rendered")
    assert.is_true(#rows_with(buf, "/tmp/pi-bash-full.log") == 1, "full output path shown")
  end)

  it("ignores updates for unknown or finished blocks", function()
    local h = History.new(TAB)
    h:on_bash_start("b1", "cmd", false)
    pump(50)
    h:on_bash_end("b1", { output = "", exitCode = 0, cancelled = false, truncated = false })
    pump(50)
    h:on_bash_output("b1", "late chunk\n")
    h:on_bash_output("nope", "stray\n")
    pump(50)
    local buf = h:buf()
    assert.is_true(#rows_with(buf, "late chunk") == 0)
    assert.is_true(#rows_with(buf, "stray") == 0)
  end)

  it("replays a completed bashExecution message", function()
    local h = History.new(TAB)
    h:on_bash_replay({
      command = "git status",
      output = "On branch main\n",
      exitCode = 0,
      cancelled = false,
      truncated = false,
      timestamp = 123,
    })
    pump(120)
    local buf = h:buf()
    assert.is_true(#rows_with(buf, "$ git status") == 1, "replay header")
    assert.is_true(#rows_with(buf, "On branch main") == 1, "replay output")
  end)

  it("replays a failed bashExecution message with exit status", function()
    local h = History.new(TAB)
    h:on_bash_replay({
      command = "make",
      output = "error: boom\n",
      exitCode = 2,
      cancelled = false,
      truncated = false,
      timestamp = 123,
    })
    pump(120)
    local buf = h:buf()
    assert.is_true(#rows_with(buf, "$ make") == 1)
    assert.is_true(#rows_with(buf, "error: boom") == 1)
    assert.is_true(#rows_with(buf, "(exit 2)") == 1)
  end)
end)
