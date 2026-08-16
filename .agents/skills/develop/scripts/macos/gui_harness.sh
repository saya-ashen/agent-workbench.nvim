#!/usr/bin/env bash
# GUI automation harness for pi.nvim, macOS variant. `source` it from your run
# script. Drives a real WezTerm+nvim window (started by gui_launch.sh) by
# injecting input as TERMINAL BYTES via `wezterm cli send-text`, queries state
# over the nvim RPC socket as ground truth, and screenshots with screencapture.
#
# The RPC side (q/qlua/runlua/find_buf/check/wait_for/normal/...) is identical
# to the Linux harness — only input (send/type_text) and output (shot) differ:
#
#   * send/type_text write the same byte stream a real keypress would produce
#     (Esc=\x1b, Up=\x1b[A, ctrl+g=\x07) straight into the test pane's pty via
#     the instance's own mux socket (WEZTERM_UNIX_SOCKET=gui-sock-<pid>). For
#     nvim — which consumes bytes, not OS key events — this exercises the same
#     real keybindings, but is IMMUNE to macOS focus problems (fullscreen-Space
#     bounce, G28) and needs NO Accessibility permission. What it deliberately
#     does NOT cover is WezTerm's key→byte translation, which is not our code.
#     --no-paste is mandatory: nvim enables bracketed paste, and a paste-wrapped
#     leader sequence would insert as text instead of firing mappings.
#   * shot uses `screencapture -x -o -l <CGWindowID>`: renders the window even
#     occluded/unfocused/on another Space, but REQUIRES the Screen Recording
#     permission for the terminal running the script. Denied => launch found
#     no CGWindowID and shot SKIPs with a loud message instead of silently
#     passing (G27).
#
# All paths derive from $RUN so one variable wires everything:
#   RUN=/tmp/my_run bash run.sh
# Override WIN/PANE/WSOCK/SOCK/SHOTDIR via environment when not using the
# standard gui_launch.sh state files.
#
# WHY each helper looks the way it does (see references/gotchas.md / testing.md):
#   * Lua is executed by writing it to a file and :luafile-ing it over RPC
#     (qlua/runlua) — this dodges shell-quoting hell entirely. `q` is the
#     one-liner convenience (single-quote the expr).
#   * `normal` sends Esc until mode is normal/visual: the prompt auto-enters
#     insert mode, so any leader/normal key needs this first (G12).
#   * `type_text` first focuses the prompt and enters insert via RPC: byte
#     injection produces no OS focus events, so the layout's focus autocmds
#     never fire and the prompt would stay in normal mode.
#   * This file's own cmdline is clean (no test feature string), so sourcing it
#     is safe; keep cleanup/observation in files too (G16).

# WTPID / WIN / PANE / WSOCK are read LAZILY at use time (with an exported
# override winning), never cached at source time: a run script that sources
# this harness BEFORE gui_launch.sh must still see the files launch creates.
RUN=${RUN:-/tmp/pi_dev_test}
SOCK=${SOCK:-$RUN.sock}
SHOTDIR=${SHOTDIR:-$RUN/shots}
CMD=${RUN}.cmd.lua
OUT=${RUN}.out
mkdir -p "$SHOTDIR"
PASS=0
FAIL=0

# _state VARNAME BASENAME: exported VARNAME if non-empty, else the launch file.
# `${!1:-}`: indirect expansion with a default, safe under the caller's `set -u`.
_state() {
  local v="${!1:-}"
  [ -n "$v" ] && printf '%s' "$v" || cat "$RUN.$2" 2>/dev/null
}

_exec() { nvim --server "$SOCK" --remote-expr 'execute("luafile '"$CMD"'")' >/dev/null 2>&1; }

# q '<lua-expr>': evaluate one expression, print its value. Single-quote it.
q() {
  printf 'RESULT = %s\n' "$1" >"$CMD"
  printf 'local __f=io.open("%s","w") __f:write(tostring(RESULT)) __f:close()\n' "$OUT" >>"$CMD"
  _exec
  cat "$OUT" 2>/dev/null
}

# runlua: read lua from a QUOTED heredoc, run for side effects.
runlua() {
  cat >"$CMD"
  _exec
}

# qlua: read lua from a QUOTED heredoc that sets RESULT, print RESULT.
qlua() {
  cat >"$CMD"
  printf 'local __f=io.open("%s","w") __f:write(tostring(RESULT)) __f:close()\n' "$OUT" >>"$CMD"
  _exec
  cat "$OUT" 2>/dev/null
}

# find_buf <filetype>: bufnr of first buffer with that filetype, else -1.
find_buf() {
  cat >"$CMD" <<LUA
local ft, r = "$1", -1
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == ft then r = b; break end
end
RESULT = r
LUA
  printf 'local __f=io.open("%s","w") __f:write(tostring(RESULT)) __f:close()\n' "$OUT" >>"$CMD"
  _exec
  cat "$OUT" 2>/dev/null
}

# --- macOS input: terminal bytes via wezterm cli ---------------------------

_send_bytes() {
  local wsock pane
  wsock=$(_state WSOCK WSOCK)
  pane=$(_state PANE PANE)
  WEZTERM_UNIX_SOCKET=$wsock wezterm cli send-text --pane-id "$pane" --no-paste -- "$1"
}

# The byte stream a real keypress produces. Accepts: named keys (Escape/
# Return/Tab/Space/BSpace/Delete/Up/Down/Left/Right), punctuation aliases
# (comma/period/slash), a single character, or `ctrl+<letter>` / `ctrl+<arrow>`.
_key_bytes() {
  local k="$1"
  case "$k" in
  Escape | Esc) printf '\033' ;;
  Return | Enter) printf '\r' ;;
  Tab) printf '\t' ;;
  Space | space) printf ' ' ;;
  BSpace | Backspace) printf '\177' ;;
  Delete) printf '\033[3~' ;;
  Up) printf '\033[A' ;; Down) printf '\033[B' ;;
  Left) printf '\033[D' ;; Right) printf '\033[C' ;;
  comma) printf ',' ;; period) printf '.' ;; slash) printf '/' ;;
  ctrl+*)
    local c="${k#ctrl+}"
    if [ "${#c}" -eq 1 ]; then
      # control byte = ord(char) & 0x1f (ctrl+g -> \x07, ctrl+p -> \x10)
      printf "\\$(printf '%03o' $(($(printf '%d' "'$c") & 31)))"
    else
      case "$c" in
      Up) printf '\033[1;5A' ;; Down) printf '\033[1;5B' ;;
      Left) printf '\033[1;5D' ;; Right) printf '\033[1;5C' ;;
      *)
        echo "send: unknown 'ctrl+$c'" >&2
        return 1
        ;;
      esac
    fi
    ;;
  *)
    if [ "${#k}" -eq 1 ]; then
      printf '%s' "$k"
    else
      echo "send: unknown key '$k'" >&2
      return 1
    fi
    ;;
  esac
}

send() {
  local k
  for k in "$@"; do
    _send_bytes "$(_key_bytes "$k")"
    sleep 0.05
  done
  sleep 0.4
}

# Byte injection produces no OS focus events, so the layout's focus/insert
# autocmds never run: focus the prompt and enter insert explicitly before
# typing. The KEYS UNDER TEST still travel as terminal bytes.
focus_prompt() {
  runlua <<'LUA'
pcall(function() require("agent-workbench").focus_chat_prompt() end)
vim.cmd("startinsert")
LUA
  sleep 0.3
}

type_text() {
  focus_prompt
  _send_bytes "$*"
  sleep 0.4
}

# --- macOS output ----------------------------------------------------------

shot() {
  local out="$SHOTDIR/$1.png" win
  win=$(_state WIN WIN)
  if [ -z "$win" ]; then
    echo "  [shot SKIP] no CGWindowID — Screen Recording not granted to this terminal (G27)"
    return 1
  fi
  if ! screencapture -x -o -l "$win" "$out" 2>/dev/null; then
    echo "  [shot FAIL] screencapture errored — grant Screen Recording to this terminal,"
    echo "              restart the terminal, re-run (G27)"
    return 1
  fi
  # Blank sanity: a denied/buggy capture can still yield a tiny all-one-color
  # PNG. A real 200-col nvim UI at Retina scale is far bigger than this floor.
  local sz
  sz=$(stat -f%z "$out" 2>/dev/null || echo 0)
  if [ "$sz" -lt 20000 ]; then
    echo "  [shot WARN] $out is only ${sz}B — looks blank; check Screen Recording (G27)"
    return 1
  fi
  echo "  screenshot: $out"
}

# --- OS-independent assertions ----------------------------------------------

check() {
  if [ "$2" = "$3" ]; then
    echo "[PASS] $1"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $1  got='$2' want='$3'"
    FAIL=$((FAIL + 1))
  fi
}

# wait_for '<lua-bool-expr>' [tries]: poll until the expression is true.
wait_for() {
  local tries="${2:-40}" i
  for ((i = 0; i < tries; i++)); do
    [ "$(q "$1")" = "true" ] && return 0
    sleep 0.25
  done
  return 1
}

# normal: leave insert/visual mode so normal-mode/leader mappings fire (G12).
normal() {
  send Escape
  local i m
  for ((i = 0; i < 20; i++)); do
    m=$(q 'vim.api.nvim_get_mode().mode')
    case "$m" in n* | v*) return 0 ;; esac
    send Escape
  done
}

# Convenience readers for the prompt buffer / history store.
prompt_text() {
  qlua <<'LUA'
local p
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "pi-chat-prompt" then p = b break end
end
RESULT = p and table.concat(vim.api.nvim_buf_get_lines(p, 0, -1, false), "\n") or ""
LUA
}
prompt_empty() {
  qlua <<'LUA'
local p
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "pi-chat-prompt" then p = b break end
end
RESULT = p and (vim.trim(table.concat(vim.api.nvim_buf_get_lines(p, 0, -1, false), "\n")) == "") and "true" or "false"
LUA
}
last_two_history() {
  qlua <<'LUA'
local e = require("agent-workbench.prompt_history").get():entries(); local n = #e
RESULT = (n >= 2) and (e[n - 1] .. " | " .. e[n]) or ("ONLY:" .. table.concat(e, " | "))
LUA
}

summary() {
  echo "=================================="
  echo "PASS=$PASS FAIL=$FAIL"
  echo "=================================="
}
