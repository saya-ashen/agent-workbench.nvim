#!/usr/bin/env bash
# Launch a FRESH, ISOLATED Agent Workbench GUI test instance. On i3, use a
# dedicated workspace so the window tiles full-screen. On other X11 window
# managers, launch on the current workspace and maximize after discovery.
#
# Usage:  bash gui_launch.sh [extra nvim args, e.g. a file to open]
#   RUN=/tmp/my_run bash gui_launch.sh /tmp/my_run/sample.lua
#
# This file's cmdline is clean (no test feature string); it never pgrep-matches
# itself (G16). It only ever kills by window id / socket lsof, never by pattern.
set -u
RUN=${RUN:-/tmp/pi_dev_test}
SOCK=${SOCK:-$RUN.sock}
NVIM_LAUNCHER=${NVIM_LAUNCHER:-nvim}
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

# Remember and switch workspace only when connected to a live i3 IPC socket.
# `i3-msg` may be installed on non-i3 desktops, where it returns no JSON.
WORKSPACES=$(i3-msg -t get_workspaces 2>/dev/null || true)
CURRENT_WS=$(
  printf '%s' "$WORKSPACES" |
    python3 -c "import sys,json; ws=[w['name'] for w in json.load(sys.stdin) if w['focused']]; print(ws[0] if ws else '')" \
      2>/dev/null || true
)
printf '%s' "$CURRENT_WS" >"$WS_FILE"
if [ -n "$CURRENT_WS" ]; then
  i3-msg "workspace $TEST_WS" >/dev/null 2>&1
  sleep 0.3
fi

# Force X11 so xdotool, xwininfo, and ffmpeg share one window ID even when
# the host desktop itself runs on Wayland. A unique Neovim terminal title lets
# xdotool discover the window through XQueryTree; niri's rootless XWayland does
# not expose the EWMH client list required by wmctrl.
WINDOW_TITLE=${WINDOW_TITLE:-AgentWorkbenchDemo-$$}
env -u WAYLAND_DISPLAY wezterm start --always-new-process -- "$NVIM_LAUNCHER" \
  --listen "$SOCK" --cmd "set title titlestring=$WINDOW_TITLE" "$@" &

# Wait for socket, then the new X window, then RPC readiness.
for _ in $(seq 1 60); do
  [ -S "$SOCK" ] && break
  sleep 0.25
done
if [ -S "$SOCK" ]; then
  nvim --server "$SOCK" --remote-expr \
    "execute('set title titlestring=$WINDOW_TITLE')" >/dev/null 2>&1
fi
for _ in $(seq 1 60); do
  NEW=$(xdotool search --onlyvisible --name "$WINDOW_TITLE" 2>/dev/null | head -1)
  [ -n "$NEW" ] && {
    echo "$NEW" >"$WIN_FILE"
    break
  }
  sleep 0.25
done
for _ in $(seq 1 60); do
  nvim --server "$SOCK" --remote-expr '1' >/dev/null 2>&1 && break
  sleep 0.25
done

WIN=$(cat "$WIN_FILE" 2>/dev/null)
if [ ! -S "$SOCK" ] || [ -z "$WIN" ]; then
  echo "gui_launch: failed to discover Neovim socket or X11 window" >&2
  exit 1
fi
echo "RUN=$RUN  WIN=$WIN  user_workspace=$(cat "$WS_FILE")"
echo "RPC buf=$(nvim --server "$SOCK" --remote-expr 'luaeval("vim.api.nvim_buf_get_name(0)")' 2>/dev/null)"
xwininfo -id "$WIN" 2>/dev/null | grep -E "Width|Height" | sed 's/^/  /'
