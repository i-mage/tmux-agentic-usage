#!/usr/bin/env bash
# Several Claude subscriptions, sourced by refresh.sh.
#
# Claude Code keeps only the account it is logged into ("Claude Code-credentials").
# Every refresh copies that account's OAuth credentials into our own keychain item
# (service "tmux-agentic-usage-claude", account = the account uuid), so an account
# you switched away from with /login stays readable: its access token is used while
# it is valid, then renewed with its refresh token and stored again.
#
# The account Claude Code is logged into is never refreshed here. Claude Code owns
# those tokens, and a refresh can rotate the refresh token out from under it.
#
# Not secret, kept in $CACHE_DIR: claude-accounts (one uuid per line, the accounts
# seen so far) and claude-<uuid>.json (the last good entry, shown as stale when a
# fetch fails). To forget an account: delete its line, its json and its keychain item
#   security delete-generic-password -s tmux-agentic-usage-claude -a <uuid>

AU_KC_SERVICE="tmux-agentic-usage-claude"
AU_TOKEN_URL="https://platform.claude.com/v1/oauth/token"
AU_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
AU_API="https://api.anthropic.com/api/oauth"
JQ="${JQ:-$(command -v jq || echo /opt/homebrew/bin/jq)}"
AU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

au_now_ms() { echo $(( $(date +%s) * 1000 )); }

_kc_active() { security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null; }
_kc_get() { security find-generic-password -s "$AU_KC_SERVICE" -a "$1" -w 2>/dev/null; }
# stdin = credentials JSON. Sent hex-encoded through `security -i` so the token
# never appears in a process list.
_kc_put() {
  local hex
  hex=$(xxd -p | tr -d '\n')
  [ -n "$hex" ] || return 1
  printf 'add-generic-password -U -s %s -a %s -X %s\n' "$AU_KC_SERVICE" "$1" "$hex" \
    | security -i >/dev/null 2>&1
}
_api() { # $1 access token, $2 usage|profile
  curl -sf -m 10 "$AU_API/$2" -H "Authorization: Bearer $1" -H "anthropic-beta: oauth-2025-04-20"
}
_refresh_token() { # $1 refresh token, $2 space-separated scopes -> token response JSON
  "$JQ" -nc --arg r "$1" --arg c "$AU_CLIENT_ID" --arg s "$2" \
    '{grant_type: "refresh_token", refresh_token: $r, client_id: $c, scope: $s}' \
    | curl -sf -m 15 -X POST "$AU_TOKEN_URL" -H "Content-Type: application/json" --data-binary @-
}

# Last good entry of an account, marked stale. $2 = "login" when the stored
# credentials no longer work and only a /login into that account can fix it,
# $3 = "active" for the account Claude Code is logged into.
_au_stale() {
  local f="$CACHE_DIR/claude-$1.json"
  [ -s "$f" ] || return 1
  "$JQ" -c --argjson login "$([ "${2:-}" = login ] && echo true || echo false)" \
    --argjson a "$([ "${3:-}" = active ] && echo true || echo false)" \
    '.stale = true | .active = $a | if $login then .needsLogin = true else . end' "$f"
}

# One account -> one cache entry on stdout. $1 = uuid, $2 = credentials JSON or
# empty, $3 = "active" for the account Claude Code is logged into.
_au_entry() {
  local uuid=$1 blob=$2 active=${3:-} token exp now resp usage profile entry
  [ -n "$blob" ] || { _au_stale "$uuid" "" "$active"; return; }
  token=$("$JQ" -r '.accessToken // empty' <<<"$blob")
  exp=$("$JQ" -r '.expiresAt // 0' <<<"$blob")
  now=$(au_now_ms)
  if [ "$active" != active ] && (( exp - 300000 < now )); then
    resp=$(_refresh_token "$("$JQ" -r '.refreshToken // empty' <<<"$blob")" \
      "$("$JQ" -r '(.scopes // []) | join(" ")' <<<"$blob")") \
      && token=$("$JQ" -r '.access_token // empty' <<<"$resp" 2>/dev/null) && [ -n "$token" ] \
      || { _au_stale "$uuid" login; return; }
    blob=$("$JQ" -c --argjson r "$resp" --argjson now "$now" \
      '.accessToken = $r.access_token
       | .refreshToken = ($r.refresh_token // .refreshToken)
       | .expiresAt = ($now + (($r.expires_in // 3600) * 1000))' <<<"$blob")
    printf '%s' "$blob" | _kc_put "$uuid"
  fi
  usage=$(_api "$token" usage) || { _au_stale "$uuid" "" "$active"; return; }
  profile=$(_api "$token" profile) || profile='{}'
  entry=$("$JQ" -nc --argjson u "$usage" --argjson p "$profile" '{usage: $u, profile: $p}' \
    | "$JQ" -c -f "$AU_DIR/claude_oauth.jq" 2>/dev/null) || { _au_stale "$uuid" "" "$active"; return; }
  "$JQ" -e '.usage.secondary != null' <<<"$entry" >/dev/null 2>&1 || { _au_stale "$uuid" "" "$active"; return; }
  entry=$("$JQ" -c --arg u "$uuid" --argjson a "$([ "$active" = active ] && echo true || echo false)" \
    --argjson t "$(( now / 1000 ))" '. + {accountUuid: $u, active: $a, fetchedAt: $t}' <<<"$entry")
  printf '%s\n' "$entry" >"$CACHE_DIR/claude-$uuid.json.tmp" \
    && mv "$CACHE_DIR/claude-$uuid.json.tmp" "$CACHE_DIR/claude-$uuid.json"
  printf '%s\n' "$entry"
}

# Every known account as a JSON array of cache entries. Exit 1 when there is none.
claude_entries() {
  local list="$CACHE_DIR/claude-accounts" active_blob active_uuid uuid entries
  active_blob=$(_kc_active | "$JQ" -c '.claudeAiOauth // empty' 2>/dev/null)
  active_uuid=$("$JQ" -r '.accountUuid // empty' <<<"$active_blob" 2>/dev/null)
  if [ -n "$active_uuid" ]; then
    printf '%s' "$active_blob" | _kc_put "$active_uuid"
    grep -qx "$active_uuid" "$list" 2>/dev/null || echo "$active_uuid" >>"$list"
  fi
  [ -s "$list" ] || return 1
  entries=$(while IFS= read -r uuid; do
      [ -n "$uuid" ] || continue
      if [ "$uuid" = "$active_uuid" ]; then _au_entry "$uuid" "$active_blob" active
      else _au_entry "$uuid" "$(_kc_get "$uuid")"; fi
    done <"$list" | "$JQ" -sc '.')
  "$JQ" -e 'length > 0' <<<"$entries" >/dev/null 2>&1 || return 1
  printf '%s\n' "$entries"
}
