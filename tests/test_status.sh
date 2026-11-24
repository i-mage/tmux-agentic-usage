#!/usr/bin/env bash
# Run: tests/test_status.sh  (exit 0 = pass)
# The status-line segment: the Claude week against an even pace, only beyond 3 %.
set -euo pipefail
cd "$(dirname "$0")/.."
JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
fail=0
expect() { # $1 = label, $2 = got, $3 = want
  if [ "$2" != "$3" ]; then printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$1" "$2" "$3"; fail=1; fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export AGENTIC_USAGE_CACHE_DIR="$TMP" XDG_CONFIG_HOME="$TMP/config"
NOW=$(date +%s)
# Every week below is half gone: it resets in 84 h of 168 h.
RESET=$("$JQ" -nr --argjson t "$(( NOW + 302400 ))" '$t | todate')
acct() { # $1 email, $2 active, $3 weekly used
  "$JQ" -nc --arg e "$1" --argjson a "$2" --argjson w "$3" --arg r "$RESET" '{provider:"claude",
    error:null, active:$a, usage:{identity:{loginMethod:"Claude Max 20x", accountEmail:$e},
      secondary:{usedPercent:$w, windowMinutes:10080, resetsAt:$r},
      extraRateWindows:[{title:"Fable", window:{usedPercent:90, windowMinutes:10080, resetsAt:$r}}]}}'
}
CODEX=$("$JQ" -nc --arg r "$RESET" '{provider:"codex", error:null, usage:{identity:{loginMethod:"plus"},
  secondary:{usedPercent:95, windowMinutes:10080, resetsAt:$r}}}')
status() { echo "$1" >"$TMP/usage.json"; bash scripts/status.sh; }

# Pool of two: 80 of 200 used at half time (100 allowed) -> 20 % in reserve, green plus.
expect 'pool reserve' "$(status "[$(acct a@x.io true 40),$(acct b@x.io false 40),$CODEX]")" \
  '#[fg=green,bold]+20%#[default] '
# 120 used -> 20 % over pace, red minus.
expect 'pool over pace' "$(status "[$(acct a@x.io true 60),$(acct b@x.io false 60)]")" \
  '#[fg=red,bold]-20%#[default] '
# Within 3 % either way: nothing.
expect 'pool on pace' "$(status "[$(acct a@x.io true 51),$(acct b@x.io false 51)]")" ''
# One account: its own Weekly, not Fable and not Codex.
expect 'single account' "$(status "[$(acct a@x.io true 40),$CODEX]")" '#[fg=green,bold]+10%#[default] '
# No cache, no Claude: nothing, and no error.
rm -f "$TMP/usage.json"
expect 'no cache' "$(bash scripts/status.sh)" ''
expect 'codex only' "$(status "[$CODEX]")" ''

[ $fail -eq 0 ] && echo "ok"
exit $fail
