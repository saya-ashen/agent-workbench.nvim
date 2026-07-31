# pi.nvim development helpers.
#
#   make test    — run the plenary unit test suite (hermetic, -u tests/minimal_init.lua)
#   make smoke   — headless end-to-end smoke check (loads the user config, opens the chat)
#   make format  — reformat lua/ and tests/ in place with stylua
#   make style   — check formatting only (stylua --check); non-zero exit on drift, for CI/hooks
#   make lint    — static/type check lua/ with lua-language-server (--check); non-zero on problems
#
# The suite is intentionally runnable without the user's full Neovim config so
# it stays fast and deterministic; PLENARY_PATH overrides the plenary location.

NVIM_BIN ?= nvim
PLENARY_PATH ?= $(HOME)/.local/share/nvim/lazy/plenary.nvim
MIN_INIT := tests/minimal_init.lua
STYLUA_BIN ?= stylua
LUA_LS_BIN ?= lua-language-server

.PHONY: test smoke format style lint

test:
	PLENARY_PATH=$(PLENARY_PATH) $(NVIM_BIN) --headless -u $(MIN_INIT) \
		-c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = '$(MIN_INIT)' })"

smoke:
	$(NVIM_BIN) --headless -u $(HOME)/.config/nvim/init.lua -l /tmp/pi_smoke.lua

# NOTE: stylua's built-in default indent is Tabs; .stylua.toml pins the 4-space
# convention used here, so always format through this target (or `stylua .` with
# the config present), never a bare `stylua` invocation that ignores the config.
#
# Runs stylua twice: 2.5.2 is not single-pass idempotent on some constructs
# (e.g. `require "x"` -> `require("x")` changes line width and triggers a
# re-wrap), so a second pass is needed to reach the stable fixed point that
# `make style` checks against.
format:
	$(STYLUA_BIN) .
	$(STYLUA_BIN) .

style:
	$(STYLUA_BIN) --check .

# lua-language-server exits non-zero when diagnostics are found, so this gates
# directly. Config is .luarc.json (portable: bundled luv types only; vim runtime
# types are intentionally not loaded so the check is environment-independent).
lint:
	$(LUA_LS_BIN) --check lua --configpath $(CURDIR)/.luarc.json --loglevel error
