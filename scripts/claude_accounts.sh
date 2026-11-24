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
# `security -w` prints the data as hex when it holds a non-printable byte (a
# trailing newline is enough), so hex output is decoded back.
_kc_get() {
  local out
  out=$(security find-generic-password -s "$AU_KC_SERVICE" -a "$1" -w 2>/dev/null) || return 1
  if [[ "$out" =~ ^([0-9a-f][0-9a-f])+$ ]]; then printf '%s' "$out" | xxd -r -p | tr -d '\n'
  else printf '%s' "$out"; fi
}
# stdin = credentials JSON (newlines dropped, JSON does not need them). Sent hex-encoded through `security -i` so the token
# never appears in a process list.
_kc_put() {
  local hex
  hex=$(tr -d '\n' | xxd -p | tr -d '\n')
  [ -n "$hex" ] || return 1
  printf 'add-generic-password -U -s %s -a %s -X %s\n' "$AU_KC_SERVICE" "$1" "$hex" \
    | security -i >/dev/null 2>&1
}
_api() { # $1 access token, $2 usage|profile
  curl -sf -m 10 "$AU_API/$2" -H "Authorization: Bearer $1" -H "anthropic-beta: oauth-2025-04-20"
}
# Without Claude Code's User-Agent the token endpoint answers 429 (24. 11. 2026).
au_cli_version() { # installed Claude Code version, from its versions/<x.y.z> symlink
  local bin
  bin=$(command -v claude 2>/dev/null)
  [[ "$bin" == /* ]] || bin="$HOME/.local/bin/claude"
  basename "$(readlink "$bin" 2>/dev/null)" 2>/dev/null
}
AU_UA="claude-cli/$(au_cli_version) (external, cli)"
# $1 refresh token, $2 space-separated scopes -> token response JSON on stdout.
# Exit 75 = passing problem (429, 5xx, no answer): keep the account, try later.
# Exit 1 = the refresh token was refused: only a new login fixes that.
_refresh_token() {
  local out code
  out=$("$JQ" -nc --arg r "$1" --arg c "$AU_CLIENT_ID" --arg s "$2" \
      '{grant_type: "refresh_token", refresh_token: $r, client_id: $c, scope: $s}' \
    | curl -s -m 15 -X POST "$AU_TOKEN_URL" -H "Content-Type: application/json" \
        -H "User-Agent: $AU_UA" --data-binary @- -w '\n%{http_code}')
  code=${out##*$'\n'}
  case "$code" in
    200) printf '%s\n' "${out%$'\n'*}" ;;
    429|5??|000|"") return 75 ;;
    *) return 1 ;;
  esac
}

# An account that could not be updated. Its last good entry comes back marked
# stale with the reason, so the popup says what went wrong and since when; an
# account that was never fetched comes back as an error entry, never silently.
#   $1 uuid  $2 "active" or ""  $3 reason for the popup
#   $4 "login" when only a new login of that account fixes it
_au_stale() {
  local f="$CACHE_DIR/claude-$1.json" a login
  a=$([ "${2:-}" = active ] && echo true || echo false)
  login=$([ "${4:-}" = login ] && echo true || echo false)
  if [ -s "$f" ]; then
    "$JQ" -c --argjson a "$a" --argjson login "$login" --arg r "$3" \
      '.stale = true | .active = $a | .staleReason = $r
       | if $login then .needsLogin = true else . end' "$f"
  else
    "$JQ" -nc --arg u "$1" --argjson a "$a" --arg r "$3" \
      '{provider: "claude", accountUuid: $u, active: $a,
        error: {message: ("account \($u[0:8]): \($r)")}}'
  fi
}

AU_RELOGIN="login expired, run scripts/add-account.sh"

# One account -> one cache entry on stdout. $1 = uuid, $2 = credentials JSON or
# empty, $3 = "active" for the account Claude Code is logged into.
_au_entry() {
  local uuid=$1 blob=$2 active=${3:-} token exp now resp usage profile entry rc=0
  [ -n "$blob" ] || { _au_stale "$uuid" "$active" "no stored login, run scripts/add-account.sh" login; return; }
  token=$("$JQ" -r '.accessToken // empty' <<<"$blob")
  exp=$("$JQ" -r '.expiresAt // 0' <<<"$blob")
  now=$(au_now_ms)
  if [ "$active" != active ] && (( exp - 300000 < now )); then
    resp=$(_refresh_token "$("$JQ" -r '.refreshToken // empty' <<<"$blob")" \
      "$("$JQ" -r '(.scopes // []) | join(" ")' <<<"$blob")") || rc=$?
    (( rc == 75 )) && { _au_stale "$uuid" "" "token server busy, retrying"; return; }
    token=$("$JQ" -r '.access_token // empty' <<<"$resp" 2>/dev/null)
    (( rc == 0 )) && [ -n "$token" ] || { _au_stale "$uuid" "" "$AU_RELOGIN" login; return; }
    blob=$("$JQ" -c --argjson r "$resp" --argjson now "$now" \
      '.accessToken = $r.access_token
       | .refreshToken = ($r.refresh_token // .refreshToken)
       | .expiresAt = ($now + (($r.expires_in // 3600) * 1000))' <<<"$blob")
    printf '%s' "$blob" | _kc_put "$uuid"
  fi
  usage=$(_api "$token" usage) || rc=$?
  if (( rc == 22 )); then _au_stale "$uuid" "$active" "usage API refused the request"; return
  elif (( rc != 0 )); then _au_stale "$uuid" "$active" "no connection to the usage API"; return; fi
  profile=$(_api "$token" profile) || profile='{}'
  entry=$("$JQ" -nc --argjson u "$usage" --argjson p "$profile" '{usage: $u, profile: $p}' \
    | "$JQ" -c -f "$AU_DIR/claude_oauth.jq" 2>/dev/null)
  "$JQ" -e '.usage.secondary != null' <<<"$entry" >/dev/null 2>&1 \
    || { _au_stale "$uuid" "$active" "unexpected answer from the usage API"; return; }
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
