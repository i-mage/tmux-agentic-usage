# Turn the cache (an array of provider entries) into tab-separated rows for popup.sh.
# Run with --argjson now <epoch seconds>, so the rows are testable. An empty field
# goes last in its row: popup.sh reads with IFS=tab, which merges empty fields.
#
#   H  provider  plan  email  state       state: active | stale:<min> | login:<min> | ""
#   W  title     used%  resetsAt          one rate window
#   Q  title     sumUsed%  accounts       a window summed over every Claude account
#   P  delta%  elapsed%  willLastToReset  etaSeconds   pace of a window under a day
#   D  day  %/day  budget%/day  lasts  windowDays  runOutEpoch
#                                       pace of a window of a day or more, in days
#   C  creditsAvailable
#   E  provider  message

def r1: . * 10 | round / 10;
def secs_left($u): ($u.resetsAt // "" | try fromdateiso8601 catch null) as $r
  | if $r == null then null else ([$r - $now, 0] | max) end;

# Unrounded percent of the window elapsed, null when unknown.
def elapsedf($u):
  if $u == null then null else
    (($u.windowMinutes // 300) * 60) as $win | secs_left($u) as $left
    | if $left == null then null else ((1 - $left / $win) * 100 | [., 0] | max | [., 100] | min) end
  end;

# A week is a budget per day: capacity / days in the window. The pace is what was
# spent per elapsed day, from the first hour on (24. 11. 2026, owner: "je jasné, že
# máme 28,57 percenta na deň"); no "too early to project" gate any more.
#   $used, $cap in percent; $el = elapsed percent (unrounded); $left = seconds to reset
def daily($used; $cap; $minutes; $el; $left):
  ($minutes / 1440) as $wd | ($cap / $wd) as $budget | ($el / 100 * $wd) as $days
  | if $days <= 0 then ["D", 0, 0, ($budget | r1), "true", ($wd | r1), ""] | @tsv
    else ($used / $days) as $burn
      | (if $burn > 0 then (($cap - $used) / $burn * 86400) else null end) as $eta
      | ($eta == null or $eta >= ($left // 0)) as $lasts
      | ["D", ($days | r1), ($burn | r1), ($budget | r1), ($lasts | tostring), ($wd | r1),
         (if $lasts or $eta == null then "" else ($now + $eta | floor) end)] | @tsv
    end;

# Percent of the window already elapsed, from resetsAt + windowMinutes.
def elapsed($u):
  if $u == null or ($u.resetsAt // "") == "" then null else
    (($u.windowMinutes // 300) * 60) as $win |
    ($u.resetsAt | try fromdateiso8601 catch null) as $reset |
    if $reset == null then null else
      (((1 - (($reset - $now) / $win)) * 100)
        | if . < 0 then 0 elif . > 100 then 100 else . end) | round
    end
  end;

# One P row per window. codexbar omits the pace block for a barely-used window
# (right after a session reset, for example); then it is derived from elapsed vs used.
def pacerow($p; $u):
  ($u.usedPercent // 0) as $used |
  if ($u.windowMinutes // 300) >= 1440 and elapsedf($u) != null then
    daily($used; 100; $u.windowMinutes; elapsedf($u); secs_left($u))
  else
  ((if $p != null then $p.expectedUsedPercent else null end) // elapsed($u)) as $exp |
  if $exp == null then empty else
    (if $p != null then ($p.deltaPercent // ($used - $exp)) else ($used - $exp) end) as $delta |
    (if $p != null then ($p.willLastToReset // true)
     elif $exp <= 0 then ($used == 0) else $used <= $exp end) as $lasts |
    (if $p != null then ($p.etaSeconds // "") else "" end) as $eta |
    ["P", $delta, $exp, ($lasts | tostring), $eta] | @tsv
  end
  end;

def state:
  if .needsLogin == true then "login:\((($now - (.fetchedAt // $now)) / 60) | floor)"
  elif .stale == true then "stale:\((($now - (.fetchedAt // $now)) / 60) | floor)"
  elif .active == true then "active"
  else "" end;

def entry_rows:
  if .error != null then
    ["E", (.provider // "?"), (.error.message // "error")] | @tsv
  else
    (["H", .provider,
      (.usage.identity.loginMethod // .usage.loginMethod // ""),
      (.usage.identity.accountEmail // .usage.accountEmail // ""),
      state] | @tsv),
    # A Claude account you are not logged into shows its session only while in use.
    (if .usage.primary != null
        and (.active != false or (.usage.primary.usedPercent // 0) > 0) then
      (["W", "Session", (.usage.primary.usedPercent // 0), (.usage.primary.resetsAt // "")] | @tsv),
      pacerow(.pace.primary; .usage.primary)
     else empty end),
    (if .usage.secondary != null then
      (["W", "Weekly", (.usage.secondary.usedPercent // 0), (.usage.secondary.resetsAt // "")] | @tsv),
      pacerow(.pace.secondary; .usage.secondary)
     else empty end),
    (.usage.extraRateWindows[]? |
      (["W", .title, (.window.usedPercent // 0), (.window.resetsAt // "")] | @tsv),
      pacerow(null; .window)),
    (if .usage.codexResetCredits != null then
      ["C", .usage.codexResetCredits.availableCount] | @tsv else empty end)
  end;

# Every Claude subscription together, one row per window title shared by two or
# more accounts: N accounts = N x 100% per week = N x 14.3% per day. The pace is
# the summed use per mean elapsed day against that budget, so two accounts
# resetting at different hours still add up.
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
     | ([.[].w | elapsedf(.) // 0] | add / $n) as $el
     | ([.[].w | secs_left(.) // 0] | add / $n) as $left
     | (["Q", .[0].t, $sum, $n] | @tsv),
       daily($sum; $n * 100; 10080; $el; $left))
  end;

group_by(.provider) | .[]
| if .[0].provider == "claude" then
    pool_rows(map(select(.error == null and .usage.secondary != null))),
    (sort_by(if .active == true then 0 else 1 end, .usage.identity.accountEmail // "")
     | .[] | entry_rows)
  else .[] | entry_rows end
