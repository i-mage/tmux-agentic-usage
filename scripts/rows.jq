# Turn the cache (an array of provider entries) into tab-separated rows for popup.sh.
# Run with --argjson now <epoch seconds>, so the rows are testable.
#
#   H  provider  plan  email  state       state: active | stale:<min> | login:<min> | ""
#   W  title     used%  resetsAt          one rate window
#   Q  title     sumUsed%  accounts       a window summed over every Claude account
#   P  delta%  elapsed%  willLastToReset  etaSeconds   pace of the row above
#   C  creditsAvailable
#   E  provider  message

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
  ((if $p != null then $p.expectedUsedPercent else null end) // elapsed($u)) as $exp |
  if $exp == null then empty else
    (if $p != null then ($p.deltaPercent // ($used - $exp)) else ($used - $exp) end) as $delta |
    (if $p != null then ($p.willLastToReset // true)
     elif $exp <= 0 then ($used == 0) else $used <= $exp end) as $lasts |
    (if $p != null then ($p.etaSeconds // "") else "" end) as $eta |
    ["P", $delta, $exp, ($lasts | tostring), $eta] | @tsv
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
# more accounts: N accounts = N x 100% per week. The pace line is in pool terms:
# mean used against mean elapsed, so two accounts resetting at different hours
# still compare quota spent with time spent.
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
     | ([.[].w | elapsed(.) // 0] | add / $n | round) as $el
     | (($sum / $n) | round) as $used
     | (["Q", .[0].t, $sum, $n] | @tsv),
       (["P", ($used - $el), $el, ($used <= $el | tostring), ""] | @tsv))
  end;

group_by(.provider) | .[]
| if .[0].provider == "claude" then
    pool_rows(map(select(.error == null and .usage.secondary != null))),
    (sort_by(if .active == true then 0 else 1 end, .usage.identity.accountEmail // "")
     | .[] | entry_rows)
  else .[] | entry_rows end
