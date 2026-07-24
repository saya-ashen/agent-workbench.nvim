# pi.nvim development helpers.
#
#   make test   — run the plenary unit test suite (hermetic, -u tests/minimal_init.lua)
#   make smoke  — headless end-to-end smoke check (loads the user config, opens the chat)
#
# The suite is intentionally runnable without the user's full Neovim config so
# it stays fast and deterministic; PLENARY_PATH overrides the plenary location.

NVIM_BIN ?= nvim
PLENARY_PATH ?= $(HOME)/.local/share/nvim/lazy/plenary.nvim
MIN_INIT := tests/minimal_init.lua

.PHONY: test smoke

test:
	PLENARY_PATH=$(PLENARY_PATH) $(NVIM_BIN) --headless -u $(MIN_INIT) \
		-c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = '$(MIN_INIT)' })"

smoke:
	$(NVIM_BIN) --headless -u $(HOME)/.config/nvim/init.lua -l /tmp/pi_smoke.lua
