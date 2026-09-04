#!/usr/bin/env bash
# Keep the usage cache warm while the tmux server runs.
# Started by agentic-usage.tmux via `run-shell -b`; exits when the
# server is gone. A pid file prevents duplicate daemons across
# config reloads.
set -u

INTERVAL="${1:-300}"
CACHE_DIR="$HOME/.cache/tmux-agentic-usage"
PIDFILE="$CACHE_DIR/daemon.pid"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$CACHE_DIR"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  exit 0
fi
echo $$ >"$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

while tmux has-session 2>/dev/null; do
  bash "$SCRIPT_DIR/refresh.sh"
  sleep "$INTERVAL"
done
