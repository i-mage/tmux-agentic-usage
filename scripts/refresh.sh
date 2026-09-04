#!/usr/bin/env bash
# Fetch usage from the CodexBar CLI and write the cache atomically.
# A full fetch can take 20-25s, which is why the popup never fetches
# in the foreground: this script runs from the daemon or in background.
set -uo pipefail

CACHE_DIR="$HOME/.cache/tmux-agentic-usage"
CACHE="$CACHE_DIR/usage.json"
LOCK="$CACHE_DIR/refresh.lock"
LOG="$CACHE_DIR/refresh.log"

CODEXBAR="$(command -v codexbar || echo /opt/homebrew/bin/codexbar)"
JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"

provider="$(tmux show-option -gqv @agentic-usage-providers 2>/dev/null)"
provider="${provider:-both}"

mkdir -p "$CACHE_DIR"

# mkdir is the atomic lock; a lock older than 5 min is a crashed run.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

TMP="$CACHE.tmp"
if "$CODEXBAR" usage --provider "$provider" --format json >"$TMP" 2>>"$LOG" \
   && "$JQ" -e 'type=="array" and length>0' "$TMP" >/dev/null 2>&1; then
  mv "$TMP" "$CACHE"
else
  rm -f "$TMP"
  echo "$(date '+%F %T') refresh failed" >>"$LOG"
  exit 1
fi
