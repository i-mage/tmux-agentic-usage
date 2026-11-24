#!/usr/bin/env bash
# Run: tests/test_rows.sh  (exit 0 = pass)
# Rows the popup draws from the cache: per-account blocks and the Claude pool.
set -euo pipefail
cd "$(dirname "$0")/.."
JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
fail=0
expect() { # $1 = label, $2 = got, $3 = want
  if [ "$2" != "$3" ]; then printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$1" "$2" "$3"; fail=1; fi
}
rows() { "$JQ" -r --argjson now "$NOW" -f scripts/rows.jq <<<"$1"; }

# now = Tue 2026-11-24T12:00:00Z. Week windows: A resets Mon 30.11. 17:00Z
# (19h of 168h elapsed = 11.3%), B resets Mon 30.11. 10:00Z (26h elapsed = 15.5%).
NOW=1795521600
acct() { # $1 uuid, $2 email, $3 active, $4 weekly used, $5 reset, $6 fable used, $7 session used
  "$JQ" -nc --arg u "$1" --arg e "$2" --argjson a "$3" --argjson w "$4" --arg r "$5" \
    --argjson f "$6" --argjson s "$7" '{provider:"claude", source:"oauth", error:null,
      accountUuid:$u, active:$a,
      usage:{identity:{loginMethod:"Claude Max 20x", accountEmail:$e},
        primary:{usedPercent:$s, windowMinutes:300, resetsAt:"2026-11-24T14:00:00Z"},
        secondary:{usedPercent:$w, windowMinutes:10080, resetsAt:$r},
        extraRateWindows:[{title:"Fable", window:{usedPercent:$f, windowMinutes:10080, resetsAt:$r}}]}}'
}
A=$(acct a a@x.io true 14 2026-11-30T17:00:00Z 20 10)
B=$(acct b b@x.io false 6 2026-11-30T10:00:00Z 4 0)

# One account: no pool, exactly the old block.
OUT=$(rows "[$A]")
expect 'single: no pool row' "$(grep -c '^Q' <<<"$OUT" || true)" '0'
expect 'single: header' "$(grep '^H' <<<"$OUT")" "$(printf 'H\tclaude\tClaude Max 20x\ta@x.io\tactive')"

# Two accounts: pool first, then the active account, then the other one.
OUT=$(rows "[$B,$A]")
expect 'two: header order' "$(grep '^H' <<<"$OUT" | cut -f2,3,4,5 | tr '\t' ' ' | paste -sd'|' -)" \
  'claude pool 2 accounts  |claude Claude Max 20x a@x.io active|claude Claude Max 20x b@x.io '
# Weekly pool: 20 of 200 used, mean elapsed (11.3 + 15.5) / 2 = 13.4 -> 13,
# normalised used 10 -> 3 under pace, lasts.
expect 'pool weekly row' "$(grep -A1 $'^Q\tWeekly' <<<"$OUT" | paste -sd'|' -)" \
  "$(printf 'Q\tWeekly\t20\t2|P\t-3\t13\ttrue\t')"
# Fable pool: 24 of 200 used -> 12 normalised, 1 under pace.
expect 'pool fable row' "$(grep -A1 $'^Q\tFable' <<<"$OUT" | paste -sd'|' -)" \
  "$(printf 'Q\tFable\t24\t2|P\t-1\t13\ttrue\t')"
# Inactive account with an untouched session: no Session row for it.
expect 'session rows' "$(grep -c $'^W\tSession' <<<"$OUT")" '1'

# Over pace: 190 of 200 used -> runs out.
A2=$(acct a a@x.io true 95 2026-11-30T17:00:00Z 10 0)
B2=$(acct b b@x.io false 95 2026-11-30T10:00:00Z 10 0)
OUT=$(rows "[$A2,$B2]")
expect 'pool over pace' "$(grep -A1 $'^Q\tWeekly' <<<"$OUT" | tail -1)" "$(printf 'P\t82\t13\tfalse\t')"

# A stale account says so in its header; an account that needs a login too.
S=$("$JQ" -c '.stale=true | .fetchedAt=1795514400' <<<"$B")
L=$("$JQ" -c '.stale=true | .fetchedAt=1795514400 | .needsLogin=true' <<<"$B")
expect 'stale header' "$(rows "[$A,$S]" | grep 'b@x.io' | cut -f5)" 'stale:120'
expect 'login header' "$(rows "[$A,$L]" | grep 'b@x.io' | cut -f5)" 'login:120'

# Codex and errors still render.
OUT=$(rows '[{"provider":"codex","error":null,"usage":{"identity":{"loginMethod":"plus"},
  "secondary":{"usedPercent":18,"windowMinutes":10080,"resetsAt":"2026-11-30T09:42:33Z"},
  "codexResetCredits":{"availableCount":3}}},{"provider":"gemini","error":{"message":"boom"}}]')
expect 'codex weekly' "$(grep -c $'^W\tWeekly\t18' <<<"$OUT")" '1'
expect 'codex credits' "$(grep '^C' <<<"$OUT")" "$(printf 'C\t3')"
expect 'error row' "$(grep '^E' <<<"$OUT")" "$(printf 'E\tgemini\tboom')"

[ $fail -eq 0 ] && echo "ok"
exit $fail
