set dotenv-load := false
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Run full local gate.
default: check

check: test smoke markdown-e2e style lint docs-links

test:
    PLENARY_PATH="${PLENARY_PATH:-$HOME/.local/share/nvim/lazy/plenary.nvim}" "${NVIM_BIN:-nvim}" --headless -i NONE -u tests/minimal_init.lua -c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = 'tests/minimal_init.lua' })"

smoke:
    "${NVIM_BIN:-nvim}" --headless -i NONE -u tests/minimal_init.lua -l tests/smoke.lua

markdown-e2e:
    agent-workbench-demo-nvim --headless -i NONE -u tests/minimal_init.lua -l tests/markdown_real_e2e.lua

format:
    stylua .

style:
    stylua --check .

lint:
    lua-language-server --check lua --configpath "{{justfile_directory()}}/.luarc.json" --loglevel error

docs-links:
    python3 scripts/check_docs_links.py

demo-overview:
    scripts/record-demo.sh overview

demo-shell:
    scripts/record-demo.sh shell

nvim *args:
    ./scripts/nvim-dev {{ args }}

clean-demo:
    rm -f /tmp/agent-workbench-vhs/overview.gif /tmp/agent-workbench-vhs/overview.mp4 /tmp/agent-workbench-vhs/shell.gif /tmp/agent-workbench-vhs/shell.mp4
