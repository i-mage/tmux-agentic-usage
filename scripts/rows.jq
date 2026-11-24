# Turn the cache (an array of provider entries) into tab-separated rows for popup.sh.
# Run with --argjson now <epoch seconds>, so the rows are testable. An empty field
# goes last in its row: popup.sh reads with IFS=tab, which merges empty fields.
#
#   H  provider  plan  email  state       state: active | stale:<min> | login:<min> | ""
#   W  title     used%  resetsAt          one rate window
#   Q  title     sumUsed%  accounts       a window summed over every Claude account
#   P  diff%                         pace of the row above: used minus what an even
#                                    pace allows by now (+ over pace, - reserve)
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

# Pace to the second (24. 11. 2026, owner): an even pace allows cap x elapsed
# share of the window by now; the row says how far the use is above (over pace)
# or below (reserve) that line. No "too early" gate, no daily budget wording.
def pace($used; $cap; $el): ["P", ($used - $cap * $el / 100 | r1)] | @tsv;

def pacerow($u): elapsedf($u) as $el | if $el == null then empty
  else pace($u.usedPercent // 0; 100; $el) end;

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
      pacerow(.usage.primary)
     else empty end),
    (if .usage.secondary != null then
      (["W", "Weekly", (.usage.secondary.usedPercent // 0), (.usage.secondary.resetsAt // "")] | @tsv),
      pacerow(.usage.secondary)
     else empty end),
    (.usage.extraRateWindows[]? |
      (["W", .title, (.window.usedPercent // 0), (.window.resetsAt // "")] | @tsv),
      pacerow(.window)),
    (if .usage.codexResetCredits != null then
      ["C", .usage.codexResetCredits.availableCount] | @tsv else empty end)
  end;

# Every Claude subscription together, one row per window title shared by two or
# more accounts: N accounts = N x 100% per week. The pace compares the summed use
# with N x 100% x the mean elapsed share, so accounts that reset at different
# hours still add up.
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
     | (["Q", .[0].t, $sum, $n] | @tsv),
       pace($sum; $n * 100; $el))
  end;

group_by(.provider) | .[]
| if .[0].provider == "claude" then
    pool_rows(map(select(.error == null and .usage.secondary != null))),
    (sort_by(if .active == true then 0 else 1 end, .usage.identity.accountEmail // "")
     | .[] | entry_rows)
  else .[] | entry_rows end
