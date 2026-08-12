#!/usr/bin/env bash
# DevContainer Post-Start Script
#
# Runs after every container start (including from prebuild).
# Keeps openchamber alive across VS Code reconnects by launching it detached
# and guarding against duplicate starts via a PID file.
#
# Host-side counterpart (run on the WSL host, not in the container):
#   tailscale serve --service=svc:openchamber --https=443 http://127.0.0.1:4098

set -euo pipefail

LOG="/tmp/openchamber.log"
PIDFILE="/tmp/openchamber.pid"

# If a previous instance is still alive, don't start a second one.
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "openchamber already running (pid $(cat "$PIDFILE"))"
  exit 0
fi

# Stale pidfile with no live process — clean it up so the launch below can proceed.
rm -f "$PIDFILE"

# --foreground runs the HTTP server inline instead of forking a daemon child.
# Without it the CLI spawns a detached child and uses an IPC channel to signal
# "ready"; when nohup backgrounds the CLI and this script exits, the IPC pipe
# closes before the child can send, causing an EPIPE crash on startup.
nohup openchamber --foreground --port 4098 >"$LOG" 2>&1 &
PID=$!
echo "$PID" > "$PIDFILE"

# Give the process a moment to actually exec; if it dies immediately, surface that.
sleep 1
if ! kill -0 "$PID" 2>/dev/null; then
  echo "openchamber failed to start; see $LOG" >&2
  rm -f "$PIDFILE"
  exit 1
fi

echo "openchamber started (pid $PID), logs at $LOG"