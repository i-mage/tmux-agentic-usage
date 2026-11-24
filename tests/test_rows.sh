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
expect 'single: header' "$(grep '^H' <<<"$OUT")" "$(printf 'H\tclaude\tClaude Max 20x\ta@x.io\tactive\t')"

# Two accounts: pool first, then the active account, then the other one.
OUT=$(rows "[$B,$A]")
expect 'two: header order' "$(grep '^H' <<<"$OUT" | cut -f2,3,4,5 | tr '\t' ' ' | paste -sd'|' -)" \
  'claude pool 2 accounts  |claude Claude Max 20x a@x.io active|claude Claude Max 20x b@x.io '
# Pace to the second. P = used minus expected-by-now, in percent (+ over, - reserve).
# Weekly pool: mean elapsed (19 h + 26 h) / 2 = 22.5 h of 168 h = 13.4 %;
# expected 200 x 22.5/168 = 26.79 %, used 20 % -> 6.8 % reserve, worth
# 6.786 / 200 x 604800 s = 20520 s ahead; lasts (20 / 0.1339 = 149 % < 200 %).
P() { grep -A1 "$(printf '^%s\t%s' "$1" "$2")" <<<"$OUT" | tail -1; }
expect 'pool weekly row' "$(grep $'^Q\tWeekly' <<<"$OUT")" "$(printf 'Q\tWeekly\t20\t2')"
expect 'pool weekly pace' "$(P Q Weekly)" "$(printf 'P\t-6.8')"
# Fable pool: 24 % used -> 2.8 % reserve, 2.7857 x 3024 s = 8424 s.
expect 'pool fable pace' "$(P Q Fable)" "$(printf 'P\t-2.8')"
# One account's week: 19/168 = 11.3 % elapsed, 14 % used -> 2.7 % over pace,
# 2.6905 x 6048 s = 16272 s to wait; runs out (14 / 0.1131 = 124 % > 100 %).
expect 'account weekly pace' "$(grep -A1 $'^W\tWeekly\t14' <<<"$OUT" | tail -1)" \
  "$(printf 'P\t2.7')"
# Inactive account with an untouched session: no Session row for it.
expect 'session rows' "$(grep -c $'^W\tSession' <<<"$OUT")" '1'

# Over pace: 190 of 200 used -> 163.2 % over, 163.214 x 3024 s = 493560 s.
A2=$(acct a a@x.io true 95 2026-11-30T17:00:00Z 10 0)
B2=$(acct b b@x.io false 95 2026-11-30T10:00:00Z 10 0)
OUT=$(rows "[$A2,$B2]")
expect 'pool over pace' "$(P Q Weekly)" "$(printf 'P\t163.2')"
# Session (5 h) the same way: 3 h of 5 h gone = 60 %, 10 % used -> 50 % reserve,
# 50 x 180 s = 9000 s ahead.
OUT=$(rows "[$A]")
expect 'session pace' "$(P W Session)" "$(printf 'P\t-50')"
# Codex weekly from codexbar gets the same line (its own pace block is ignored).

# A stale account says so in its header; an account that needs a login too.
S=$("$JQ" -c '.stale=true | .fetchedAt=1795514400 | .staleReason="token server busy, retrying"' <<<"$B")
L=$("$JQ" -c '.stale=true | .fetchedAt=1795514400 | .needsLogin=true | .staleReason="login expired"' <<<"$B")
expect 'stale header' "$(rows "[$A,$S]" | grep 'b@x.io' | cut -f5,6)" "$(printf 'stale:120\ttoken server busy, retrying')"
expect 'login header' "$(rows "[$A,$L]" | grep 'b@x.io' | cut -f5,6)" "$(printf 'login:120\tlogin expired')"

# A Claude account's Weekly and Fable reset together: said once (R) under its
# header, empty on the W rows; a stamp a second apart is the same reset.
OUT=$(rows "[$A]")
expect 'shared reset row' "$(grep '^R' <<<"$OUT")" "$(printf 'R\t2026-11-30T17:00:00Z')"
expect 'weekly without reset' "$(grep $'^W\tWeekly' <<<"$OUT" | cut -f4)" ''
expect 'session keeps reset' "$(grep $'^W\tSession' <<<"$OUT" | cut -f4)" '2026-11-24T14:00:00Z'
A3=$("$JQ" -c '.usage.extraRateWindows[0].window.resetsAt="2026-11-30T17:00:01Z"' <<<"$A")
expect 'reset a second apart' "$(rows "[$A3]" | grep -c '^R')" '1'
A4=$("$JQ" -c '.usage.extraRateWindows[0].window.resetsAt="2026-12-01T17:00:00Z"' <<<"$A")
expect 'different resets stay per row' "$(rows "[$A4]" | grep -c '^R')" '0'

# Away Sat 28.11. 11:00Z to Sun 29.11. 13:00Z (26 h) is not working time: A's week
# has 168 - 26 = 142 working hours, 19 h gone = 13.38 %, 14 % used -> 0.6 % over
# pace (2.7 % without the away); the A row names the period.
AWAY='[[1795863600,1795957200]]'
rows_away() { "$JQ" -r --argjson now "$NOW" --argjson away "$AWAY" -f scripts/rows.jq <<<"$1"; }
OUT=$(rows_away "[$A]")
expect 'away row' "$(grep '^A' <<<"$OUT")" "$(printf 'A\t1795863600\t1795957200')"
expect 'away weekly pace' "$(grep -A1 $'^W\tWeekly' <<<"$OUT" | tail -1)" "$(printf 'P\t0.6')"
# Pool: B's week (Mon 10:00Z, 26 h gone of 142 = 18.31 %) plus A's 13.38 % = 31.69 %
# allowed, 20 % used -> 11.7 % reserve.
OUT=$(rows_away "[$A,$B]")
expect 'away pool pace' "$(P Q Weekly)" "$(printf 'P\t-11.7')"

# Codex and errors still render.
OUT=$(rows '[{"provider":"codex","error":null,"usage":{"identity":{"loginMethod":"plus"},
  "secondary":{"usedPercent":18,"windowMinutes":10080,"resetsAt":"2026-11-30T09:42:33Z"},
  "codexResetCredits":{"availableCount":3}}},{"provider":"gemini","error":{"message":"boom"}}]')
expect 'codex weekly' "$(grep -c $'^W\tWeekly\t18' <<<"$OUT")" '1'
expect 'codex keeps its reset' "$(grep $'^W\tWeekly' <<<"$OUT" | cut -f4)" '2026-11-30T09:42:33Z'
expect 'codex credits' "$(grep '^C' <<<"$OUT")" "$(printf 'C\t3')"
expect 'error row' "$(grep '^E' <<<"$OUT")" "$(printf 'E\tgemini\tboom')"

[ $fail -eq 0 ] && echo "ok"
exit $fail
