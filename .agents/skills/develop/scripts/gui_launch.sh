#!/usr/bin/env bash
# Launch a FRESH, ISOLATED pi.nvim GUI test instance on its own i3 workspace so
# the window tiles full-screen (legible screenshots) and never crowds the user's
# windows. Records the user's current workspace so a later step can restore it.
#
# Usage:  bash gui_launch.sh [extra nvim args, e.g. a file to open]
#   RUN=/tmp/my_run bash gui_launch.sh /tmp/my_run/sample.lua
#
# This file's cmdline is clean (no test feature string); it never pgrep-matches
# itself (G16). It only ever kills by window id / socket lsof, never by pattern.
set -u
RUN=${RUN:-/tmp/pi_dev_test}
SOCK=${SOCK:-$RUN.sock}
WIN_FILE=$RUN.WIN
WS_FILE=$RUN.user_ws
TEST_WS=${TEST_WS:-9}

# Clean a previous instance launched by THIS harness (safe no-ops if absent).
OLDWIN=$(cat "$WIN_FILE" 2>/dev/null)
[ -n "$OLDWIN" ] && xdotool windowkill "$OLDWIN" 2>/dev/null
if [ -S "$SOCK" ]; then
  SPID=$(lsof -t "$SOCK" 2>/dev/null | head -1)
  [ -n "$SPID" ] && kill "$SPID" 2>/dev/null
fi
sleep 1.5
rm -f "$SOCK" "$WIN_FILE"

# Remember the user's workspace to restore later.
i3-msg -t get_workspaces 2>/dev/null |
  python3 -c "import sys,json; ws=[w['name'] for w in json.load(sys.stdin) if w['focused']]; print(ws[0] if ws else '1')" \
    >"$WS_FILE"

# Move to a dedicated empty workspace -> a single window fills the screen.
i3-msg "workspace $TEST_WS" >/dev/null 2>&1
sleep 0.3

# Launch a dedicated wezterm+nvim (lands on TEST_WS, full-screen tiling).
BEFORE=$(wmctrl -l | awk '{print $1}' | sort)
wezterm start --always-new-process -- nvim --listen "$SOCK" "$@" &

# Wait for socket, then the new X window, then RPC readiness.
for i in $(seq 1 60); do
  [ -S "$SOCK" ] && break
  sleep 0.25
done
for i in $(seq 1 60); do
  AFTER=$(wmctrl -l | awk '{print $1}' | sort)
  NEW=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | head -1)
  [ -n "$NEW" ] && {
    echo "$NEW" >"$WIN_FILE"
    break
  }
  sleep 0.25
done
for i in $(seq 1 60); do
  nvim --server "$SOCK" --remote-expr '1' >/dev/null 2>&1 && break
  sleep 0.25
done

WIN=$(cat "$WIN_FILE" 2>/dev/null)
echo "RUN=$RUN  WIN=$WIN  user_workspace=$(cat "$WS_FILE")"
echo "RPC buf=$(nvim --server "$SOCK" --remote-expr 'luaeval("vim.api.nvim_buf_get_name(0)")' 2>/dev/null)"
xwininfo -id "$WIN" 2>/dev/null | grep -E "Width|Height" | sed 's/^/  /'
