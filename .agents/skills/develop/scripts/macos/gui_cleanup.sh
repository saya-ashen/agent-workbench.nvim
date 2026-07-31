#!/usr/bin/env bash
# Tear down ONLY the pi.nvim GUI test instance started by gui_launch.sh
# (macOS variant): the wezterm-gui recorded in $RUN.WTPID plus any nvim whose
# cmdline references the test socket. The user's wezterm-gui (different pid,
# never recorded) and the user's nvim (no test socket in cmdline) never match —
# the recorded pid + socket path are perfect discriminators (G16/G17).
#
# IMPORTANT subtlety (inherited from the Linux version, read before "fixing"):
# we capture pids with pgrep and kill them in a SECOND step, on purpose. A
# `pgrep -f "<pattern>"` runs inside a command-substitution shell whose own
# cmdline *contains the pattern text*, so pgrep lists that shell too — but that
# shell exits the instant the substitution completes, so killing its (now-dead)
# pid is a harmless no-op. Do NOT replace this with `pkill -f`: pkill delivers
# the signal synchronously and would kill the very shell executing the pkill,
# aborting the script. Also never run, in another terminal, a command whose
# text contains the socket path while this runs — it would be matched and
# killed.
#
# This file's own cmdline is `bash .../gui_cleanup.sh` (no socket string), so
# it cannot match itself. macOS `pgrep -f`/`lsof` behave like the Linux ones.
set -u
RUN=${RUN:-/tmp/pi_dev_test}
SOCK=${SOCK:-$RUN.sock}
F=$SOCK   # the discriminator string

WTPID=$(cat "$RUN.WTPID" 2>/dev/null)
WTPIDS=$(pgrep -f "wezterm-gui.*$F" 2>/dev/null | tr '\n' ' ')
NVPIDS=$(pgrep -f "nvim.*$F" 2>/dev/null | tr '\n' ' ')
echo "test wezterm-gui: [${WTPID:-none} $WTPIDS]  test nvim: [$NVPIDS]"

# wezterm-gui is matched BOTH by the recorded pid and by the socket string in
# its daemonized cmdline (see gui_launch.sh); nvim by the socket string.
ALL="${WTPID:-} $WTPIDS $NVPIDS"
if [ -n "$(echo "$ALL" | tr -d ' ')" ]; then
  kill $ALL 2>/dev/null; sleep 2
  SURV="$(pgrep -f "wezterm-gui.*$F" 2>/dev/null) $(pgrep -f "nvim.*$F" 2>/dev/null)"
  [ -n "$(echo "$SURV" | tr -d ' ')" ] && kill -9 $SURV 2>/dev/null
fi
sleep 1
rm -f "$SOCK" "$RUN.WIN" "$RUN.WTPID" "$RUN.PANE" "$RUN.WSOCK" "$RUN.winid.swift" "$RUN.wezterm.lua"
echo "cleanup done (user wezterm/nvim untouched)"
