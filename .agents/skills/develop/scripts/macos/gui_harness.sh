#!/usr/bin/env bash
# GUI automation harness for pi.nvim, macOS variant. `source` it from your run
# script. Drives a real WezTerm+nvim window (started by gui_launch.sh) with the
# user's actual keybindings via AppleScript System Events, queries state over
# the nvim RPC socket as ground truth, and screenshots with screencapture.
#
# The RPC side (q/qlua/runlua/find_buf/check/wait_for/normal/...) is identical
# to the Linux harness — only input (send/type_text) and output (shot) differ:
#
#   * send/type_text use System Events `key code`/`keystroke`, which reach ONLY
#     the frontmost app (there is no per-window key targeting like
#     `xdotool --window`). `ensure_focus` re-activates the test wezterm-gui by
#     its recorded pid before every send (G28).
#   * shot uses `screencapture -x -o -l <CGWindowID>`: renders the window even
#     occluded/unfocused, but REQUIRES the Screen Recording permission for the
#     terminal running the script. Denied => launch found no CGWindowID and
#     shot SKIPs with a loud message instead of silently passing (G27).
#
# All paths derive from $RUN so one variable wires everything:
#   RUN=/tmp/my_run bash run.sh
# Defaults to /tmp/pi_dev_test. Override SOCK / WTPID / WIN / SHOTDIR as needed.
#
# WHY each helper looks the way it does (see references/gotchas.md / testing.md):
#   * Lua is executed by writing it to a file and :luafile-ing it over RPC
#     (qlua/runlua) — this dodges shell-quoting hell entirely. `q` is the
#     one-liner convenience (single-quote the expr).
#   * `normal` sends Esc until mode is normal/visual: the prompt auto-enters
#     insert mode, so any leader/normal key needs this first (G12).
#   * This file's own cmdline is clean (no test feature string), so sourcing it
#     is safe; keep cleanup/observation in files too (G16).

RUN=${RUN:-/tmp/pi_dev_test}
SOCK=${SOCK:-$RUN.sock}
WTPID=${WTPID:-$(cat "$RUN.WTPID" 2>/dev/null)}
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

# --- macOS input -----------------------------------------------------------

# Keystrokes only reach the frontmost app (G28). Re-activate the test
# wezterm-gui (by pid — never by name, all wezterm instances share one bundle
# id) if the user's focus wandered mid-run.
ensure_focus() {
  [ -z "$WTPID" ] && return 0
  osascript >/dev/null 2>&1 <<AS
tell application "System Events"
  set fp to unix id of first process whose frontmost is true
  if fp is not $WTPID then set frontmost of (first process whose unix id is $WTPID) to true
end tell
AS
}

# One key. Accepts: named keys (Escape/Return/Tab/Space/BSpace/Delete/Up/Down/
# Left/Right), punctuation aliases (comma/period/slash), a single character, or
# `mod+key` with ctrl/shift/alt/cmd (e.g. "ctrl+g", "ctrl+shift+Left").
_send_one() {
  local k="$1" spec
  case "$k" in
    Escape|Esc) spec='key code 53' ;;
    Return|Enter) spec='key code 36' ;;
    Tab) spec='key code 48' ;;
    Space|space) spec='key code 49' ;;
    BSpace|Backspace) spec='key code 51' ;;
    Delete) spec='key code 117' ;;
    Up) spec='key code 126' ;; Down) spec='key code 125' ;;
    Left) spec='key code 123' ;; Right) spec='key code 124' ;;
    comma) spec='keystroke ","' ;;
    period) spec='keystroke "."' ;;
    slash) spec='keystroke "/"' ;;
    *+*)
      local mods="" char="${k##*+}" m IFS='+'
      for m in ${k%+*}; do
        case "$m" in
          ctrl|control) mods="$mods, control down" ;;
          shift) mods="$mods, shift down" ;;
          alt|option) mods="$mods, option down" ;;
          cmd|command) mods="$mods, command down" ;;
        esac
      done
      mods="{${mods#, }}"
      case "$char" in
        Up) spec="key code 126 using $mods" ;; Down) spec="key code 125 using $mods" ;;
        Left) spec="key code 123 using $mods" ;; Right) spec="key code 124 using $mods" ;;
        *) spec="keystroke \"$char\" using $mods" ;;
      esac
      ;;
    *)
      if [ "${#k}" -eq 1 ]; then spec="keystroke \"$k\""
      else echo "send: unknown key '$k'" >&2; return 1; fi
      ;;
  esac
  osascript -e "tell application \"System Events\" to $spec" >/dev/null
}

send() { ensure_focus; local k; for k in "$@"; do _send_one "$k"; sleep 0.05; done; sleep 0.4; }

# Text goes through an ENV VAR, not the script text, so quotes/backslashes in
# the payload can't break the AppleScript (same philosophy as qlua's files).
type_text() {
  ensure_focus
  PI_TYPE_TEXT="$*" osascript -e 'tell application "System Events" to keystroke (system attribute "PI_TYPE_TEXT")' >/dev/null
  sleep 0.4
}

# --- macOS output ----------------------------------------------------------

shot() {
  local out="$SHOTDIR/$1.png"
  if [ -z "$WIN" ]; then
    echo "  [shot SKIP] no CGWindowID — Screen Recording not granted to this terminal (G27)"
    return 1
  fi
  if ! screencapture -x -o -l "$WIN" "$out" 2>/dev/null; then
    echo "  [shot FAIL] screencapture errored — grant Screen Recording to this terminal,"
    echo "              restart the terminal, re-run (G27)"
    return 1
  fi
  # Blank sanity: a denied/buggy capture can still yield a tiny all-one-color
  # PNG. A real 200-col nvim UI at Retina scale is far bigger than this floor.
  local sz; sz=$(stat -f%z "$out" 2>/dev/null || echo 0)
  if [ "$sz" -lt 20000 ]; then
    echo "  [shot WARN] $out is only ${sz}B — looks blank; check Screen Recording (G27)"
    return 1
  fi
  echo "  screenshot: $out"
}

# --- OS-independent assertions ----------------------------------------------

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
local e = require("pi.prompt_history").get():entries(); local n = #e
RESULT = (n >= 2) and (e[n - 1] .. " | " .. e[n]) or ("ONLY:" .. table.concat(e, " | "))
LUA
}

summary() { echo "=================================="; echo "PASS=$PASS FAIL=$FAIL"; echo "=================================="; }
