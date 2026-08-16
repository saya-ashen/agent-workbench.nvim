#!/usr/bin/env bash
# GUI automation harness for pi.nvim. `source` this from your run script.
# Drives a real WezTerm+nvim window (started by gui_launch.sh) with the user's
# actual keybindings via xdotool, queries state over the nvim RPC socket as
# ground truth, and screenshots with maim.
#
# All paths derive from $RUN so one variable wires everything:
#   RUN=/tmp/my_run bash run.sh
# Defaults to /tmp/pi_dev_test. Override SOCK / WIN / SHOTDIR individually if needed.
#
# WHY each helper looks the way it does (see references/gotchas.md / testing.md):
#   * Lua is executed by writing it to a file and :luafile-ing it over RPC
#     (qlua/runlua) — this dodges shell-quoting hell entirely. Prefer these over
#     clever quoting. `q` is the one-liner convenience (single-quote the expr).
#   * `normal` sends Esc until mode is normal/visual: the prompt auto-enters
#     insert mode, so any leader/normal key needs this first (G12).
#   * This file's own cmdline is clean (no test feature string), so sourcing it
#     is safe; keep cleanup/observation in files too (G16).

RUN=${RUN:-/tmp/pi_dev_test}
SOCK=${SOCK:-$RUN.sock}
WIN=${WIN:-$(cat "$RUN.WIN" 2>/dev/null)}
SHOTDIR=${SHOTDIR:-$RUN/shots}
CMD=${RUN}.cmd.lua
OUT=${RUN}.out
mkdir -p "$SHOTDIR"
PASS=0; FAIL=0

_exec() { nvim --server "$SOCK" --remote-expr 'execute("luafile '"$CMD"'")' >/dev/null 2>&1; }

# q '<lua-expr>': evaluate one expression, print its value. Single-quote it.
q() {
  printf 'RESULT = %s\n' "$1" > "$CMD"
  printf 'local __f=io.open("%s","w") __f:write(tostring(RESULT)) __f:close()\n' "$OUT" >> "$CMD"
  _exec; cat "$OUT" 2>/dev/null
}

# runlua: read lua from a QUOTED heredoc, run for side effects.
runlua() { cat > "$CMD"; _exec; }

# qlua: read lua from a QUOTED heredoc that sets RESULT, print RESULT.
qlua() {
  cat > "$CMD"
  printf 'local __f=io.open("%s","w") __f:write(tostring(RESULT)) __f:close()\n' "$OUT" >> "$CMD"
  _exec; cat "$OUT" 2>/dev/null
}

# find_buf <filetype>: bufnr of first buffer with that filetype, else -1.
find_buf() {
  cat > "$CMD" <<LUA
local ft, r = "$1", -1
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == ft then r = b; break end
end
RESULT = r
LUA
  printf 'local __f=io.open("%s","w") __f:write(tostring(RESULT)) __f:close()\n' "$OUT" >> "$CMD"
  _exec; cat "$OUT" 2>/dev/null
}

send() { xdotool key --window "$WIN" --delay 40 "$@"; sleep 0.4; }
type_text() { xdotool type --window "$WIN" --delay 25 -- "$@"; sleep 0.4; }
shot() { maim -i "$WIN" "$SHOTDIR/$1.png" 2>/dev/null && echo "  screenshot: $SHOTDIR/$1.png"; }

check() {
  if [ "$2" = "$3" ]; then echo "[PASS] $1"; PASS=$((PASS+1));
  else echo "[FAIL] $1  got='$2' want='$3'"; FAIL=$((FAIL+1)); fi
}

# wait_for '<lua-bool-expr>' [tries]: poll until the expression is true.
wait_for() {
  local tries="${2:-40}" i
  for ((i=0;i<tries;i++)); do [ "$(q "$1")" = "true" ] && return 0; sleep 0.25; done
  return 1
}

# normal: leave insert/visual mode so normal-mode/leader mappings fire (G12).
normal() {
  send Escape; local i m
  for ((i=0;i<20;i++)); do
    m=$(q 'vim.api.nvim_get_mode().mode')
    case "$m" in n*|v*) return 0 ;; esac
    send Escape
  done
}

# Convenience readers for the prompt buffer / history store.
prompt_text() { qlua <<'LUA'
local p
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "pi-chat-prompt" then p = b break end
end
RESULT = p and table.concat(vim.api.nvim_buf_get_lines(p, 0, -1, false), "\n") or ""
LUA
}
prompt_empty() { qlua <<'LUA'
local p
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "pi-chat-prompt" then p = b break end
end
RESULT = p and (vim.trim(table.concat(vim.api.nvim_buf_get_lines(p, 0, -1, false), "\n")) == "") and "true" or "false"
LUA
}
last_two_history() { qlua <<'LUA'
local e = require("agent-workbench.prompt_history").get():entries(); local n = #e
RESULT = (n >= 2) and (e[n - 1] .. " | " .. e[n]) or ("ONLY:" .. table.concat(e, " | "))
LUA
}

summary() { echo "=================================="; echo "PASS=$PASS FAIL=$FAIL"; echo "=================================="; }
