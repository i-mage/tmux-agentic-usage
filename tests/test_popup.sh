#!/usr/bin/env bash
# Run: tests/test_popup.sh  (exit 0 = pass)
# What the popup draws from a cache: bars as wide as the popup, resets as the
# moment they happen, compact layout on narrow clients.
set -euo pipefail
cd "$(dirname "$0")/.."
JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
export LC_ALL=en_US.UTF-8
fail=0
expect() { # $1 = label, $2 = got, $3 = want
  if [ "$2" != "$3" ]; then printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$1" "$2" "$3"; fail=1; fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export AGENTIC_USAGE_CACHE_DIR="$TMP" XDG_CONFIG_HOME="$TMP/config"
NOW=$(date +%s)
iso() { "$JQ" -nr --argjson t "$(( NOW + $1 ))" '$t | todate'; }
acct() { # $1 email, $2 active, $3 weekly used, $4 reset in seconds
  "$JQ" -nc --arg e "$1" --argjson a "$2" --argjson w "$3" --arg r "$(iso "$4")" \
    --arg s "$(iso 7200)" '{provider:"claude", error:null, active:$a,
      usage:{identity:{loginMethod:"Claude Max 20x", accountEmail:$e},
        primary:{usedPercent:10, windowMinutes:300, resetsAt:$s},
        secondary:{usedPercent:$w, windowMinutes:10080, resetsAt:$r},
        extraRateWindows:[{title:"Fable", window:{usedPercent:$w, windowMinutes:10080, resetsAt:$r}}]}}'
}
CODEX=$("$JQ" -nc --arg s "$(iso 5400)" --arg w "$(iso 300000)" '{provider:"codex", error:null,
  usage:{identity:{loginMethod:"plus"},
    primary:{usedPercent:5, windowMinutes:300, resetsAt:$s},
    secondary:{usedPercent:18, windowMinutes:10080, resetsAt:$w},
    codexResetCredits:{availableCount:3}}}')
render() { # $1 = columns -> plain text
  bash scripts/popup.sh print "$1" </dev/null | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g'
}
width() { local w=0 line; while IFS= read -r line; do (( ${#line} > w )) && w=${#line}; done; echo "$w"; }

# One account and Codex: every bar line ends one column short of the popup edge.
echo "[$(acct a@x.io true 20 400000),$CODEX]" >"$TMP/usage.json"
OUT=$(render 62)
expect 'rows rendered' "$(grep -c 'left' <<<"$OUT")" '5'
expect 'bar lines fill the width' "$(grep 'left' <<<"$OUT" | width)" '61'
expect 'nothing wider than the popup' "$( (( $(width <<<"$OUT") <= 62 )) && echo ok)" 'ok'
# Resets say when: "resets Mon 18:00", never a countdown, never beside a bar.
expect 'no countdown' "$(grep -c 'resets in' <<<"$OUT" || true)" '0'
expect 'reset lines' "$(grep -cE '^  resets (Mon|Tue|Wed|Thu|Fri|Sat|Sun) [0-9]{2}:[0-9]{2}$' <<<"$OUT")" '4'
expect 'no reset beside a bar' "$(grep 'left' <<<"$OUT" | grep -c 'resets' || true)" '0'
# The account's Weekly and Fable reset once, under its header.
expect 'shared reset under header' "$(grep -A1 'CLAUDE' <<<"$OUT" | tail -1 | grep -c resets)" '1'

# Two accounts: the pool's "of 200%" still fits.
echo "[$(acct a@x.io true 20 400000),$(acct b@x.io false 0 420000)]" >"$TMP/usage.json"
OUT=$(render 62)
expect 'pool row fits' "$(grep 'of 200%' <<<"$OUT" | width)" '61'

# A reset a week or more ahead carries its date.
echo "[$(acct a@x.io true 20 $(( 8 * 86400 )))]" >"$TMP/usage.json"
expect 'date a week ahead' "$(render 62 | grep -cE 'resets [A-Z][a-z]{2} [0-9]+\.[0-9]+\. ')" '1'

# Compact layout under 50 columns: bars still fill, resets still the moment.
echo "[$(acct a@x.io true 20 400000),$CODEX]" >"$TMP/usage.json"
OUT=$(render 44)
expect 'compact bars fill' "$(grep -E '^ (Weekly|Fable|Session) ' <<<"$OUT" | width)" '37'
expect 'compact resets' "$(grep -cE '^ resets (Mon|Tue|Wed|Thu|Fri|Sat|Sun) [0-9]{2}:[0-9]{2}$' <<<"$OUT")" '4'

# Away period: named on the first line, no spend-by part on the pace lines.
mkdir -p "$TMP/config/tmux-agentic-usage"
date -r $(( NOW + 86400 )) '+%Y-%m-%d %H:%M' 2>/dev/null >/dev/null \
  && printf '%s %s\n' "$(date -r $(( NOW + 86400 )) '+%Y-%m-%d %H:%M')" \
       "$(date -r $(( NOW + 2 * 86400 )) '+%Y-%m-%d %H:%M')" >"$TMP/config/tmux-agentic-usage/away"
OUT=$(render 62)
expect 'away line' "$(grep -c '^ away ' <<<"$OUT")" '1'
expect 'no spend-by' "$(grep -c 'to spend' <<<"$OUT" || true)" '0'

[ $fail -eq 0 ] && echo "ok"
exit $fail
