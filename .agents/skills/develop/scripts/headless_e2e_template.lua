-- Headless end-to-end template. Copy to /tmp/<run>/e2e.lua and run with:
--   nvim --headless -u ~/.config/nvim/init.lua -l /tmp/<run>/e2e.lua
--
-- PITFALLS this template already handles (see references/gotchas.md):
--   * G-stub: replace the agent backend so no real LLM call and no transcript
--     write happen (the stub returns before the RPC send).
--   * G4: headless -l does NOT fire TextChanged for programmatic edits. If you
--     need to verify a "save on edit" path, call the module's callable save
--     method directly instead of waiting on the autocmd.
--   * G5: insert mode doesn't persist across feedkeys/wait; feed "i<key>" in one
--     call, or rely on keys bound in { "i", "n" }.
--   * Exit with cq 0 / cq 1 so the shell sees pass/fail.

local results = {}
local function check(name, ok, detail)
  results[#results + 1] = { name = name, ok = ok, detail = detail or "" }
end
local function eq(name, got, want)
  check(name, got == want, got == want and "" or ("got=" .. vim.inspect(got) .. " want=" .. vim.inspect(want)))
end

local function find_buf(ft)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].filetype == ft then
      return b
    end
  end
end

-- Open the real chat and wait for its buffers.
require("agent-workbench").show { layout = "side" }
vim.wait(4000, function()
  return find_buf "pi-chat-prompt" ~= nil
end, 50)

local chat = require("agent-workbench.sessions.manager").get().chat
check("chat instance available", chat ~= nil)

-- Stub the backend BEFORE any submit.
chat._agent.send = function(_) end

-- ... drive the feature under test, assert with eq()/check() ...
-- e.g. for a "save on edit" feature, call the callable directly (G4):
--   chat._prompt:_save_draft()

-- Report and exit.
local failed = 0
for _, r in ipairs(results) do
  print(string.format("[%s] %s %s", r.ok and "PASS" or "FAIL", r.name, r.detail))
  if not r.ok then
    failed = failed + 1
  end
end
print(failed == 0 and "E2E: ALL GREEN" or ("E2E: " .. failed .. " FAILED"))
vim.cmd(failed == 0 and "cq 0" or "cq 1")
