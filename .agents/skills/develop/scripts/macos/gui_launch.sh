#!/usr/bin/env bash
# Launch a FRESH, ISOLATED pi.nvim GUI test instance on macOS: a dedicated
# WezTerm process running `nvim --listen $SOCK`, sized large for legible
# screenshots.
#
# Differences from the Linux launcher (see references/testing.md "Layer 3"):
#   * No i3/workspace dance and NO FOCUS MANAGEMENT AT ALL. Input is injected
#     as bytes via `wezterm cli send-text` (see gui_harness.sh), which bypasses
#     the OS focus model entirely — immune to the fullscreen-Space focus bounce
#     (G28) and needs no Accessibility permission. `screencapture -l` renders
#     the window even when occluded or on another Space.
#   * The test wezterm-gui is identified by the socket string in its own
#     cmdline (G29: it daemonizes to ppid=1, so "parent of nvim" is wrong);
#     its per-GUI mux socket (~/.local/share/wezterm/gui-sock-<pid>) is how
#     the harness talks to this specific instance (WEZTERM_UNIX_SOCKET).
#   * The window FULLSCREENS ITSELF at startup (generated --config-file with
#     a gui-startup hook). Why: macOS cannot pixel-capture windows on
#     non-active Spaces (screencapture -l and ScreenCaptureKit both refuse),
#     and Space-switching from a background CLI is ignored since macOS 14 —
#     but a GUI's own fullscreen transition always moves to a new Space AND
#     switches the view to it (G28/G30).
#   * The CGWindowID (needed only by `shot`) is looked up via a tiny Swift
#     helper calling CGWindowListCopyWindowInfo over ALL windows (not just
#     on-screen ones — the window may sit on another Space), picking the
#     largest layer-0 window (WezTerm also owns tab-bar/IME helper windows).
#     Without Screen Recording the list holds only the caller's own windows,
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
PANE_FILE=$RUN.PANE
WSOCK_FILE=$RUN.WSOCK

# Clean a previous instance launched by THIS harness (safe no-ops if absent).
OLDPID=$(cat "$WTPID_FILE" 2>/dev/null)
[ -n "$OLDPID" ] && kill "$OLDPID" 2>/dev/null
if [ -S "$SOCK" ]; then
  SPID=$(lsof -t "$SOCK" 2>/dev/null | head -1); [ -n "$SPID" ] && kill "$SPID" 2>/dev/null
fi
sleep 1.5
rm -f "$SOCK" "$WTPID_FILE" "$WIN_FILE" "$PANE_FILE" "$WSOCK_FILE"

# Launch a dedicated wezterm+nvim via a GENERATED config (--config-file is a
# top-level option): the gui-startup hook spawns the only window and, after a
# beat (immediate calls only maximize), toggles NATIVE fullscreen. This puts
# the window on its own Space, visible to screencapture -l. The standalone
# config replaces the user's wezterm config for this instance (their
# keybindings/fonts are irrelevant — nvim's UI is what is under test).
WZLUA=$RUN.wezterm.lua
cat > "$WZLUA" <<'LUA'
local wezterm = require 'wezterm'
local mux = wezterm.mux
wezterm.on('gui-startup', function(cmd)
  local _, _, muxwin = mux.spawn_window(cmd or {})
  local gui = muxwin:gui_window()
  if gui then
    wezterm.time.call_after(1.0, function()
      gui:toggle_fullscreen()
    end)
  end
end)
return {
  initial_cols = 200,
  initial_rows = 55,
  native_macos_fullscreen_mode = true,
}
LUA
wezterm --config-file "$WZLUA" \
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
WTPID=""
for i in $(seq 1 60); do
  WTPID=$(pgrep -f "wezterm-gui.*$SOCK" | head -1)
  [ -n "$WTPID" ] && { echo "$WTPID" > "$WTPID_FILE"; break; }
  sleep 0.25
done

# The instance's mux socket + pane id: this is the input channel (send-text).
WSOCK=~/.local/share/wezterm/gui-sock-$WTPID
PANE=""
if [ -S "$WSOCK" ]; then
  echo "$WSOCK" > "$WSOCK_FILE"
  for i in $(seq 1 40); do
    PANE=$(WEZTERM_UNIX_SOCKET=$WSOCK wezterm cli list --format json 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['pane_id'])" 2>/dev/null)
    [ -n "$PANE" ] && { echo "$PANE" > "$PANE_FILE"; break; }
    sleep 0.25
  done
fi

# CGWindowID lookup (screenshots only). Swift lives in a FILE: on macOS 26 the
# JXA ObjC bridge fails to bind CGWindowListCopyWindowInfo (result.count is
# undefined — verified by e2e), so we call it from Swift, which needs no
# bridge metadata. Prints "<id> <area>" for every layer-0 window of the pid
# over ALL windows (occluded/other-Space included); we take the largest.
SWIFT=$RUN.winid.swift
cat > "$SWIFT" <<'SW'
import CoreGraphics
import Foundation
guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
let list = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    if (w[kCGWindowOwnerPID as String] as? Int32) == pid,
       (w[kCGWindowLayer as String] as? Int) == 0,
       let b = w[kCGWindowBounds as String] as? [String: Any],
       let width = b["Width"] as? Double, let height = b["Height"] as? Double,
       let id = w[kCGWindowNumber as String] as? Int {
        print(id, Int(width * height))
    }
}
SW
WIN=""
if [ -n "$WTPID" ]; then
  for i in $(seq 1 20); do
    WIN=$(swift "$SWIFT" "$WTPID" 2>/dev/null | sort -k2 -n | tail -1 | awk '{print $1}')
    [ -n "$WIN" ] && break
    sleep 0.5
  done
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

echo "RUN=$RUN  WTPID=${WTPID:-?}  PANE=${PANE:-?}  WIN=${WIN:-none}  SOCK=$SOCK"
echo "RPC buf=$(nvim --server "$SOCK" --remote-expr 'luaeval("vim.api.nvim_buf_get_name(0)")' 2>/dev/null)"
