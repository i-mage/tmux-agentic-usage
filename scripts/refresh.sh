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

# CodexBar's Claude CLI scrape only knows Opus/Sonnet windows, so a
# per-model weekly limit like "Current week (Fable)" is dropped. The
# OAuth usage endpoint lists every scoped limit; append them to the
# claude entry as extraRateWindows. Any failure leaves the file as is.
merge_claude_scoped() {
  "$JQ" -e 'any(.[]; .provider=="claude" and .error==null)' "$TMP" >/dev/null 2>&1 || return 0
  local token scoped
  token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | "$JQ" -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [ -n "$token" ] || return 0
  scoped=$(curl -sf -m 10 https://api.anthropic.com/api/oauth/usage \
    -H "Authorization: Bearer $token" -H "anthropic-beta: oauth-2025-04-20" \
    | "$JQ" -c '[.limits[]? | select(.kind=="weekly_scoped")
        | {title: (.scope.model.display_name // .scope.surface // "Scoped"),
           window: {usedPercent: .percent, windowMinutes: 10080,
                    resetsAt: (.resets_at | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z"))}}]' 2>/dev/null)
  [ -n "$scoped" ] && [ "$scoped" != "[]" ] || return 0
  "$JQ" --argjson s "$scoped" 'map(if .provider=="claude" and .error==null
      then .usage.extraRateWindows = ((.usage.extraRateWindows // []) + $s) else . end)' \
    "$TMP" >"$TMP.m" 2>/dev/null && mv "$TMP.m" "$TMP" || rm -f "$TMP.m"
}

if "$CODEXBAR" usage --provider "$provider" --format json >"$TMP" 2>>"$LOG" \
   && "$JQ" -e 'type=="array" and length>0' "$TMP" >/dev/null 2>&1; then
  merge_claude_scoped
  mv "$TMP" "$CACHE"
else
  rm -f "$TMP"
  echo "$(date '+%F %T') refresh failed" >>"$LOG"
  exit 1
fi
