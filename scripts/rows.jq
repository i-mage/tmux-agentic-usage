# Turn the cache (an array of provider entries) into tab-separated rows for popup.sh.
# Run with --argjson now <epoch seconds>, so the rows are testable. An empty field
# goes last in its row: popup.sh reads with IFS=tab, which merges empty fields.
#
#   H  provider  plan  email  state  why  state: active | stale:<min> | login:<min> | ""
#                                          why: what failed in the last update, or ""
#   R  resetsAt                     a Claude account's week windows share one reset:
#                                    said once under its header, empty on its W rows
#   W  title     used%  resetsAt          one rate window
#   Q  title     sumUsed%  accounts       a window summed over every Claude account
#   P  diff%                         pace of the row above: used minus what an even
#                                    pace allows by now (+ over pace, - reserve)
#   A  start  end                    an away period that shapes the pace (epochs)
#   C  creditsAvailable
#   E  provider  message

def r1: . * 10 | round / 10;

# Away periods, [[start, end], ...] in epoch seconds (--argjson away). Time away
# is not working time: the quota is paced over the hours you are at the computer,
# so before an away period an even pace allows more (24. 11. 2026, owner).
def away: $ARGS.named.away // [];
def away_in($s; $e): [away[] | ([([.[1], $e] | min) - ([.[0], $s] | max), 0] | max)] | add // 0;

# Percent of a window's working time gone by $t (unrounded), null when unknown.
def workf($u; $t):
  if $u == null then null else
    ($u.resetsAt // "" | try fromdateiso8601 catch null) as $r
    | if $r == null then null else
        ($r - ($u.windowMinutes // 300) * 60) as $s
        | (($r - $s) - away_in($s; $r)) as $total
        | ([[$t, $s] | max, $r] | min) as $tc
        | if $total <= 0 then null
          else (($tc - $s) - away_in($s; $tc)) / $total * 100 end
      end
  end;
def elapsedf($u): workf($u; $now);

# Pace to the second (24. 11. 2026, owner): an even pace allows cap x elapsed
# share of the window by now; the row says how far the use is above (over pace)
# or below (reserve) that line. No "too early" gate, no daily budget wording.
# $exp = what an even pace allows by now.
def pace($used; $exp): ["P", ($used - $exp | r1)] | @tsv;

def pacerow($u): elapsedf($u) as $el | if $el == null then empty
  else pace($u.usedPercent // 0; $el) end;

def state:
  if .needsLogin == true then "login:\((($now - (.fetchedAt // $now)) / 60) | floor)"
  elif .stale == true then "stale:\((($now - (.fetchedAt // $now)) / 60) | floor)"
  elif .active == true then "active"
  else "" end;

# A Claude account's week windows (Weekly, Fable, ...) reset together: the reset
# is said once under the header (24. 11. 2026, owner). Codex keeps it per row.
def shared_reset:
  if .provider != "claude" then null else
    # The windows' reset stamps differ by a second or so: within 2 minutes is one reset.
    [.usage.secondary.resetsAt?, (.usage.extraRateWindows[]?.window.resetsAt)]
    | map(select(. != null and . != "")
          | {s: ., e: (try fromdateiso8601 catch null)} | select(.e != null))
    | if length > 0 and (map(.e) | max - min) <= 120 then .[0] else null end
  end;

def entry_rows:
  if .error != null then
    ["E", (.provider // "?"), (.error.message // "error")] | @tsv
  else
    shared_reset as $sr
    | def at($u): ($u.resetsAt // "") as $r
        | ($r | try fromdateiso8601 catch null) as $e
        | if $sr != null and $e != null and (($e - $sr.e) | fabs) <= 120 then "" else $r end;
    (["H", .provider,
      (.usage.identity.loginMethod // .usage.loginMethod // ""),
      (.usage.identity.accountEmail // .usage.accountEmail // ""),
      state, (.staleReason // "")] | @tsv),
    (if $sr != null then ["R", $sr.s] | @tsv else empty end),
    # A Claude account you are not logged into shows its session only while in use.
    (if .usage.primary != null
        and (.active != false or (.usage.primary.usedPercent // 0) > 0) then
      (["W", "Session", (.usage.primary.usedPercent // 0), (.usage.primary.resetsAt // "")] | @tsv),
      pacerow(.usage.primary)
     else empty end),
    (if .usage.secondary != null then
      (["W", "Weekly", (.usage.secondary.usedPercent // 0), at(.usage.secondary)] | @tsv),
      pacerow(.usage.secondary)
     else empty end),
    (.usage.extraRateWindows[]? |
      (["W", .title, (.window.usedPercent // 0), at(.window)] | @tsv),
      pacerow(.window)),
    (if .usage.codexResetCredits != null then
      ["C", .usage.codexResetCredits.availableCount] | @tsv else empty end)
  end;

# Every Claude subscription together, one row per window title shared by two or
# more accounts: N accounts = N x 100% per week. The pace compares the summed use
# with the sum of what each account's own pace allows by now, so accounts that
# reset at different hours still add up.
def pool_rows($acc):
  if ($acc | length) < 2 then empty else
    (["H", "claude pool", "\($acc | length) accounts", "", ""] | @tsv),
    ([ $acc[]
       | {t: "Weekly", w: .usage.secondary},
         (.usage.extraRateWindows[]? | {t: (.title | sub(" only$"; "")), w: .window}) ]
     | group_by(.t) | map(select(length >= 2))
     | sort_by(if .[0].t == "Weekly" then 0 else 1 end) | .[]
     | length as $n
     | ([.[].w.usedPercent // 0] | add) as $sum
     | ([.[].w | elapsedf(.) // 0] | add) as $exp
     | (["Q", .[0].t, $sum, $n] | @tsv),
       pace($sum; $exp))
  end;

(away[] | select(.[1] > $now - 8 * 86400) | ["A", .[0], .[1]] | @tsv),
(group_by(.provider) | .[]
| if .[0].provider == "claude" then
    pool_rows(map(select(.error == null and .usage.secondary != null))),
    (sort_by(if .active == true then 0 else 1 end, .usage.identity.accountEmail // "")
     | .[] | entry_rows)
  else .[] | entry_rows end)
