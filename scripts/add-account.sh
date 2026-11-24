#!/usr/bin/env bash
# Add a Claude subscription to the popup without switching Claude Code.
#
#   bash scripts/add-account.sh [email]
#
# Logs in once in a throwaway CLAUDE_CONFIG_DIR (the browser opens, pick the
# account there), copies that login's OAuth credentials into the plugin's own
# store (see claude_accounts.sh), then deletes the throwaway login. The Claude
# Code you work in, and every session running in it, stays on its account.
set -uo pipefail

CACHE_DIR="$HOME/.cache/tmux-agentic-usage"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$CACHE_DIR"
# shellcheck source=claude_accounts.sh
source "$SCRIPT_DIR/claude_accounts.sh"

services() {
  security dump-keychain 2>/dev/null \
    | sed -n 's/.*"svce"<blob>="\(Claude Code-credentials[^"]*\)".*/\1/p' | sort -u
}

before=$(services)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

CLAUDE_CONFIG_DIR="$tmpdir" claude auth login --claudeai ${1:+--email "$1"} || {
  echo "login failed" >&2; exit 1; }

svc=$(comm -13 <(printf '%s\n' "$before") <(services) | head -1)
blob=""
if [ -n "$svc" ]; then
  blob=$(security find-generic-password -s "$svc" -w 2>/dev/null | "$JQ" -c '.claudeAiOauth // empty')
fi
if [ -z "$blob" ] && [ -f "$tmpdir/.credentials.json" ]; then
  blob=$("$JQ" -c '.claudeAiOauth // empty' "$tmpdir/.credentials.json")
fi
[ -n "$blob" ] || { echo "no credentials found after login" >&2; exit 1; }

uuid=$("$JQ" -r '.accountUuid // empty' <<<"$blob")
if [ -z "$uuid" ]; then
  uuid=$(_api "$("$JQ" -r .accessToken <<<"$blob")" profile | "$JQ" -r '.account.uuid // empty')
  blob=$("$JQ" -c --arg u "$uuid" '.accountUuid = $u' <<<"$blob")
fi
[ -n "$uuid" ] || { echo "could not read the account id" >&2; exit 1; }

printf '%s' "$blob" | _kc_put "$uuid" || { echo "keychain write failed" >&2; exit 1; }
grep -qx "$uuid" "$CACHE_DIR/claude-accounts" 2>/dev/null || echo "$uuid" >>"$CACHE_DIR/claude-accounts"
# The throwaway login is not used again; its tokens now live in our store only.
[ -n "$svc" ] && security delete-generic-password -s "$svc" >/dev/null 2>&1

email=$(_api "$("$JQ" -r .accessToken <<<"$blob")" profile | "$JQ" -r '.account.email // "?"')
echo "added $email ($uuid)"
bash "$SCRIPT_DIR/refresh.sh" && echo "cache refreshed"
