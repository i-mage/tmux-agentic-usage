#!/usr/bin/env bash
# Run: tests/test_claude_accounts.sh  (exit 0 = pass)
# Several Claude subscriptions: the logged-in account is copied into our own store,
# accounts switched away from are read from the store and renewed with their refresh
# token, and the logged-in account is never refreshed by us. Keychain and network are
# replaced with fakes; nothing real is touched.
set -euo pipefail
cd "$(dirname "$0")/.."
JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
fail=0
expect() { if [ "$2" != "$3" ]; then printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$1" "$2" "$3"; fail=1; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CACHE_DIR="$T/cache"; mkdir -p "$CACHE_DIR" "$T/kc"
# shellcheck source=../scripts/claude_accounts.sh
source scripts/claude_accounts.sh

NOW_MS=1795521600000
au_now_ms() { echo "$NOW_MS"; }
ACTIVE=""
_kc_active() { [ -n "$ACTIVE" ] && printf '{"claudeAiOauth":%s}' "$ACTIVE"; }
_kc_get() { cat "$T/kc/$1" 2>/dev/null; }
_kc_put() { cat >"$T/kc/$1"; }
_refresh_token() { echo "$1" >>"$T/refreshed"; [ "$1" = "dead" ] && return 1; [ "$1" = "busy" ] && return 75
  printf '{"access_token":"new-%s","refresh_token":"r2-%s","expires_in":28800}' "$1" "$1"; }
_api() { # $1 token, $2 endpoint
  case "$1" in tokA|new-*) ;; *) echo "$1 $2" >>"$T/denied"; return 22 ;; esac
  case "$2" in
    usage) echo '{"limits":[{"kind":"weekly_all","percent":30,"resets_at":"2026-11-30T17:00:00+00:00"}]}' ;;
    profile) echo '{"account":{"email":"who@x.io"},"organization":{"rate_limit_tier":"default_claude_max_20x"}}' ;;
  esac
}
blob() { # $1 uuid, $2 access, $3 refresh, $4 expiresAt ms
  "$JQ" -nc --arg u "$1" --arg a "$2" --arg r "$3" --argjson e "$4" \
    '{accountUuid:$u, accessToken:$a, refreshToken:$r, expiresAt:$e, scopes:["user:profile","user:inference"]}'
}

# 1. Logged into A: A is captured and listed, read with Claude Code's own token.
ACTIVE=$(blob A tokA refA $((NOW_MS + 3600000)))
OUT=$(claude_entries)
expect 'A stored' "$("$JQ" -r .accessToken "$T/kc/A")" 'tokA'
expect 'one entry' "$("$JQ" -r 'length' <<<"$OUT")" '1'
expect 'A active' "$("$JQ" -r '.[0] | "\(.accountUuid) \(.active) \(.usage.secondary.usedPercent)"' <<<"$OUT")" 'A true 30'

# 2. /login switched Claude Code to B. B's token in the keychain is accepted by the
#    fake API only after renewal, so A must come from our store with a still-valid token.
ACTIVE=$(blob B tokA refB $((NOW_MS + 3600000)))
OUT=$(claude_entries)
expect 'two entries' "$("$JQ" -r 'length' <<<"$OUT")" '2'
expect 'B active, A not' "$("$JQ" -r '[.[] | "\(.accountUuid):\(.active)"] | sort | join(" ")' <<<"$OUT")" 'A:false B:true'
expect 'nothing refreshed yet' "$(cat "$T/refreshed" 2>/dev/null || true)" ''

# 3. A's access token expired: renewed with its refresh token, new pair stored.
blob A tokA-old refA $((NOW_MS - 1000)) >"$T/kc/A"
OUT=$(claude_entries)
expect 'A refreshed once' "$(cat "$T/refreshed")" 'refA'
expect 'A new access' "$("$JQ" -r .accessToken "$T/kc/A")" 'new-refA'
expect 'A new refresh' "$("$JQ" -r .refreshToken "$T/kc/A")" 'r2-refA'
expect 'A new expiry' "$("$JQ" -r .expiresAt "$T/kc/A")" "$((NOW_MS + 28800000))"
expect 'A fresh' "$("$JQ" -r '.[] | select(.accountUuid=="A") | .stale // false' <<<"$OUT")" 'false'

# 4. The active account is never refreshed by us, even when its token is expired:
#    Claude Code owns that token, a rotation would log it out.
: >"$T/refreshed"
ACTIVE=$(blob B tokB-expired refB $((NOW_MS - 1000)))
OUT=$(claude_entries)
expect 'active not refreshed' "$(grep -c refB "$T/refreshed" || true)" '0'
# B could not be fetched now, so its last good entry is shown as stale.
expect 'B stale' "$("$JQ" -r '.[] | select(.accountUuid=="B") | "\(.stale) \(.staleReason)"' <<<"$OUT")" 'true usage API refused the request'

# 5. A refresh token that no longer works: last good entry, flagged for a login.
blob A x dead $((NOW_MS - 1000)) >"$T/kc/A"
OUT=$(claude_entries)
expect 'A needs login' "$("$JQ" -r '.[] | select(.accountUuid=="A") | "\(.stale) \(.needsLogin) \(.staleReason)"' <<<"$OUT")" 'true true login expired, run scripts/add-account.sh'

# 5b. Rate limited (429) or server error: a passing problem, stale but no /login.
blob A x busy $((NOW_MS - 1000)) >"$T/kc/A"
OUT=$(claude_entries)
expect 'A busy: stale, no login' "$("$JQ" -r '.[] | select(.accountUuid=="A") | "\(.stale) \(.needsLogin // false) \(.staleReason)"' <<<"$OUT")" 'true false token server busy, retrying'

# 5c. An account that never had a good fetch is not dropped: an error entry.
echo C >>"$CACHE_DIR/claude-accounts"
OUT=$(claude_entries)
expect 'C never fetched: error entry' "$("$JQ" -r '.[] | select(.accountUuid=="C") | .error.message' <<<"$OUT")" \
  'account C: no stored login, run scripts/add-account.sh'

# 6. Nothing usable at all: non-zero exit so refresh.sh falls back to CodexBar.
rm -f "$T"/kc/* "$CACHE_DIR"/claude-*
: >"$CACHE_DIR/claude-accounts"
ACTIVE=""
if claude_entries >/dev/null; then expect 'empty fails' 'rc=0' 'rc!=0'; fi

# 7. Real keychain round trip (own throwaway service): a trailing newline in the
#    stored JSON makes `security -w` print hex; put strips it, get decodes hex.
if command -v security >/dev/null 2>&1; then
  ( AU_KC_SERVICE="tmux-agentic-usage-test-$$"
    source scripts/claude_accounts.sh
    AU_KC_SERVICE="tmux-agentic-usage-test-$$"
    printf '{"a":1}\n' | _kc_put probe
    got=$(_kc_get probe)
    printf '{"a":2}\n' | security add-generic-password -U -s "$AU_KC_SERVICE" -a raw \
      -X "$(printf '{"a":2}\n' | xxd -p | tr -d '\n')" 2>/dev/null
    raw=$(_kc_get raw | "$JQ" -c . 2>/dev/null)
    security delete-generic-password -s "$AU_KC_SERVICE" -a probe >/dev/null 2>&1
    security delete-generic-password -s "$AU_KC_SERVICE" -a raw >/dev/null 2>&1
    [ "$got" = '{"a":1}' ] || { echo "FAIL keychain put strips newline: got '$got'"; exit 1; }
    [ "$raw" = '{"a":2}' ] || { echo "FAIL keychain get decodes hex: got '$raw'"; exit 1; }
  ) || fail=1
fi

[ $fail -eq 0 ] && echo "ok"
exit $fail
