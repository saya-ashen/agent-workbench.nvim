#!/usr/bin/env bash
# Launch a FRESH, ISOLATED pi.nvim GUI test instance on macOS: a dedicated
# WezTerm process running `nvim --listen $SOCK`, sized large for legible
# screenshots, focused via the Accessibility API.
#
# Differences from the Linux launcher (see references/testing.md "Layer 3"):
#   * No i3/workspace dance. `screencapture -l <CGWindowID>` renders the window
#     even when occluded or unfocused, so the window just needs to be BIG
#     (initial_cols/rows) — not alone on a workspace.
#   * The test wezterm-gui is identified by PID (parent of the test nvim),
#     because every wezterm-gui shares one bundle id and AppleScript cannot
#     address "the other wezterm" by name.
#   * The CGWindowID (needed only by `shot`) is looked up via JXA
#     CGWindowListCopyWindowInfo filtered by owner pid. Without the Screen
#     Recording permission that call returns ONLY the caller's own windows,
#     so the lookup comes back empty — the launcher then warns loudly and
#     continues: keys/RPC/cleanup all still work, only `shot` is skipped (G27).
#
# Usage:  bash gui_launch.sh [extra nvim args, e.g. a file to open]
#   RUN=/tmp/my_run bash gui_launch.sh /tmp/my_run/sample.lua
#
# This file's cmdline is clean (no test feature string); it never pgrep-matches
# itself (G16). It kills only by recorded pid / socket lsof, never by pattern.
set -u
RUN=${RUN:-/tmp/pi_dev_test}
SOCK=${SOCK:-$RUN.sock}
WTPID_FILE=$RUN.WTPID
WIN_FILE=$RUN.WIN
COLS=${COLS:-200}
ROWS=${ROWS:-55}

# Clean a previous instance launched by THIS harness (safe no-ops if absent).
OLDPID=$(cat "$WTPID_FILE" 2>/dev/null)
[ -n "$OLDPID" ] && kill "$OLDPID" 2>/dev/null
if [ -S "$SOCK" ]; then
  SPID=$(lsof -t "$SOCK" 2>/dev/null | head -1); [ -n "$SPID" ] && kill "$SPID" 2>/dev/null
fi
sleep 1.5
rm -f "$SOCK" "$WTPID_FILE" "$WIN_FILE"

# Launch a dedicated wezterm+nvim. Big initial size => legible screenshots.
# NOTE: `--config` is a TOP-LEVEL wezterm option — it must come BEFORE the
# `start` subcommand (`wezterm start --config` is rejected; caught by e2e).
wezterm --config "initial_cols=$COLS" --config "initial_rows=$ROWS" \
  start --always-new-process \
  -- nvim --listen "$SOCK" "$@" &

# Wait for the RPC socket, then RPC readiness.
for i in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 0.25; done
for i in $(seq 1 60); do
  nvim --server "$SOCK" --remote-expr '1' >/dev/null 2>&1 && break; sleep 0.25
done

# The test wezterm-gui is found by the SOCKET STRING in its own cmdline — on
# macOS wezterm-gui daemonizes (reparents to launchd, ppid=1) but keeps the
# full original argv, so `pgrep -f "wezterm-gui.*$SOCK"` names it exactly.
# Do NOT derive it as "parent of nvim": the pgrep pattern for nvim matches
# wezterm-gui's cmdline too, and the ppid chain leads to launchd, not to the
# GUI. Identifying by pid (not app name) is what lets `ensure_focus` pick the
# RIGHT wezterm when several are running.
WTPID=""
for i in $(seq 1 60); do
  WTPID=$(pgrep -f "wezterm-gui.*$SOCK" | head -1)
  [ -n "$WTPID" ] && { echo "$WTPID" > "$WTPID_FILE"; break; }
  sleep 0.25
done

# CGWindowID lookup (screenshots only). JXA lives in a FILE to dodge quoting.
JXA=$RUN.winid.js
cat > "$JXA" <<'JS'
function run(argv) {
  ObjC.import("CoreGraphics");
  const pid = Number(argv[0]);
  const list = $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID);
  const hits = [];
  for (let i = 0; i < list.count; i++) {
    const w = ObjC.deepUnwrap(list.objectAtIndex(i));
    if (w.kCGWindowOwnerPID === pid && w.kCGWindowLayer === 0) hits.push(w.kCGWindowNumber);
  }
  hits.join(" ");
}
JS
WIN=""
if [ -n "$WTPID" ]; then
  WIN=$(osascript -l JavaScript "$JXA" "$WTPID" 2>/dev/null | awk '{print $1}')
fi
if [ -n "$WIN" ]; then
  echo "$WIN" > "$WIN_FILE"
else
  echo "WARNING: no CGWindowID for wezterm-gui pid ${WTPID:-?}."
  echo "  Screen Recording is not granted to this terminal (G27): window lists hide"
  echo "  other apps' windows. Keys/RPC/cleanup still work; 'shot' will be skipped."
  echo "  Fix: System Settings -> Privacy & Security -> Screen Recording -> enable"
  echo "  this terminal app, then RESTART the terminal and re-run."
fi

# Focus the test window once (keystrokes go to the frontmost app only, G28);
# the harness re-checks focus before every `send`.
if [ -n "$WTPID" ]; then
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $WTPID) to true" >/dev/null 2>&1
fi

echo "RUN=$RUN  WTPID=${WTPID:-?}  WIN=${WIN:-none}  SOCK=$SOCK"
echo "RPC buf=$(nvim --server "$SOCK" --remote-expr 'luaeval("vim.api.nvim_buf_get_name(0)")' 2>/dev/null)"
