-- Minimal init for running pi.nvim's plenary test suite hermetically.
-- Adds plenary and this plugin to 'runtimepath' without loading the user's
-- full Neovim config, so unit tests stay fast and deterministic.
--
-- Usage (see Makefile `test` target):
--   nvim --headless -u tests/minimal_init.lua -c "lua require('plenary.test_harness').test_directory('tests')"

local function repo_root()
  -- tests/minimal_init.lua lives in <root>/tests/
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
end

local root = repo_root()

-- plenary: prefer a sibling checkout (lazy.nvim layout), fall back to a
-- user-provided PLENARY_PATH env var.
local plenary = vim.env.PLENARY_PATH
  or vim.fn.expand "~/.local/share/nvim/lazy/plenary.nvim"

for _, path in ipairs { plenary, root } do
  if vim.uv.fs_stat(path) then
    vim.opt.runtimepath:prepend(path)
  end
end
