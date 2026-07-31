-- Regression: session listing must stay fast and correct for large sessions.
--
-- Commit 30b5177 (session naming) changed parse_session_file() from reading the
-- first ~20 lines to JSON-decoding *every* line of *every* session file, just to
-- find the latest `session_info` name. With multi-MB sessions that made the
-- resume picker / continue-session lookup take many seconds.
--
-- The fix keeps "latest name wins" but only decodes rare, small `session_info`
-- lines (cheap substring prefilter) and stops decoding message lines once the
-- first user message is found. These specs pin the parsing behaviour so a future
-- change cannot silently reintroduce the full-decode or drop the name semantics.

local Config = require "pi.config"
local SessionHistory = require "pi.sessions.history"

--- Mirror of the private encode_cwd() so the test can lay out the sessions dir.
local function encode_cwd(cwd)
  local encoded = cwd:gsub("^[\\/]", ""):gsub("[\\/:]", "-")
  return "--" .. encoded .. "--"
end

local function write_jsonl(path, entries)
  local f = assert(io.open(path, "w"))
  for _, e in ipairs(entries) do
    f:write(vim.json.encode(e) .. "\n")
  end
  f:close()
end

describe("session listing parser", function()
  local agent_dir
  local cwd
  local saved_agent_dir
  local saved_cwd

  before_each(function()
    agent_dir = vim.fn.tempname()
    cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    -- getcwd() resolves macOS tempdir symlinks (/var → /private/var) after cd,
    -- while tempname() does not; encode_cwd must mirror the resolved form the
    -- module will see.
    cwd = assert(vim.uv.fs_realpath(cwd))
    vim.fn.mkdir(agent_dir .. "/sessions/" .. encode_cwd(cwd), "p")
    saved_agent_dir = Config.options.agent_dir
    saved_cwd = vim.fn.getcwd()
    Config.options.agent_dir = agent_dir
    vim.cmd("cd " .. vim.fn.fnameescape(cwd))
  end)

  after_each(function()
    Config.options.agent_dir = saved_agent_dir
    vim.cmd("cd " .. vim.fn.fnameescape(saved_cwd))
    vim.fn.delete(agent_dir, "rf")
    vim.fn.delete(cwd, "rf")
  end)

  local function sessions_dir()
    return agent_dir .. "/sessions/" .. encode_cwd(cwd)
  end

  it("extracts the first user message and truncates it to one line", function()
    write_jsonl(sessions_dir() .. "/a.jsonl", {
      { type = "session", id = "a", timestamp = "t" },
      { type = "message", message = { role = "assistant", content = "ignore me" } },
      { type = "message", message = { role = "user", content = "hello\nworld" } },
      { type = "message", message = { role = "user", content = "second user msg" } },
    })

    local list = SessionHistory.list()
    assert.equals(1, #list)
    assert.equals("hello world", list[1].first_message)
  end)

  it("reads the first user message from multipart content", function()
    write_jsonl(sessions_dir() .. "/a.jsonl", {
      { type = "session", id = "a", timestamp = "t" },
      {
        type = "message",
        message = { role = "user", content = { { type = "text", text = "from part" } } },
      },
    })

    local list = SessionHistory.list()
    assert.equals("from part", list[1].first_message)
  end)

  it("prefers the latest session_info name (latest wins) and trims it", function()
    local entries = {
      { type = "session", id = "a", timestamp = "t" },
      { type = "session_info", name = "  early name  " },
      { type = "message", message = { role = "user", content = "q" } },
    }
    -- Bury the early name under many assistant turns, then rename at the end.
    for _ = 1, 500 do
      entries[#entries + 1] = { type = "message", message = { role = "assistant", content = "x" } }
    end
    entries[#entries + 1] = { type = "session_info", name = "latest name" }
    write_jsonl(sessions_dir() .. "/a.jsonl", entries)

    local list = SessionHistory.list()
    assert.equals("latest name", list[1].name)
  end)

  it("still finds a name that only appears near the top", function()
    local entries = {
      { type = "session", id = "a", timestamp = "t" },
      { type = "message", message = { role = "user", content = "q" } },
      { type = "session_info", name = "buried" },
    }
    for _ = 1, 500 do
      entries[#entries + 1] = { type = "message", message = { role = "assistant", content = "y" } }
    end
    write_jsonl(sessions_dir() .. "/a.jsonl", entries)

    local list = SessionHistory.list()
    assert.equals("buried", list[1].name)
  end)

  it("does not fully decode huge lines to list a session (perf guard)", function()
    -- A handful of very large assistant turns. A full JSON-decode of every line
    -- makes this slow; the prefilter keeps it near pure-I/O speed.
    local f = assert(io.open(sessions_dir() .. "/big.jsonl", "w"))
    f:write(vim.json.encode({ type = "session", id = "big", timestamp = "t" }) .. "\n")
    f:write(vim.json.encode({ type = "message", message = { role = "user", content = "q" } }) .. "\n")
    local big = string.rep("z", 200000) -- 200KB per line
    for _ = 1, 300 do -- ~60MB total
      f:write(vim.json.encode({ type = "message", message = { role = "assistant", content = big } }) .. "\n")
    end
    f:close()

    local start = vim.uv.hrtime()
    local list = SessionHistory.list()
    local ms = (vim.uv.hrtime() - start) / 1e6

    assert.equals(1, #list)
    assert.equals("q", list[1].first_message)
    -- Generous bound: decoding ~60MB of JSON line-by-line takes seconds; the
    -- fixed prefilter scans it in a few hundred ms at most.
    assert.is_true(ms < 1500, string.format("listing took %.1f ms (full-decode regression?)", ms))
  end)

  it("skips files without a valid session header", function()
    local f = assert(io.open(sessions_dir() .. "/bad.jsonl", "w"))
    f:write(vim.json.encode({ type = "not-a-session" }) .. "\n")
    f:close()
    write_jsonl(sessions_dir() .. "/good.jsonl", {
      { type = "session", id = "good", timestamp = "t" },
      { type = "message", message = { role = "user", content = "hi" } },
    })

    local list = SessionHistory.list()
    assert.equals(1, #list)
    assert.equals("good", list[1].id)
  end)
end)
