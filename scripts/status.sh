#!/usr/bin/env bash
# One tmux status-line segment: how far the Claude week is from an even pace,
# shown only beyond the threshold (3 %): "+9%" green when that much is in
# reserve, "-10%" red when that much is over pace. Prints nothing otherwise.
# The week is the Claude pool's Weekly when there are two or more accounts,
# else the first account's Weekly. Reads the cache only, never the network.
#
#   set -g status-right '#(bash ~/.tmux/plugins/tmux-agentic-usage/scripts/status.sh)...'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${AGENTIC_USAGE_CACHE_DIR:-$HOME/.cache/tmux-agentic-usage}/usage.json"
JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
THRESHOLD="${AGENTIC_USAGE_STATUS_THRESHOLD:-3}"
source "$SCRIPT_DIR/away_lib.sh"

[ -f "$CACHE" ] || exit 0

d=$("$JQ" -r --argjson now "$(date +%s)" --argjson away "$(away_json)" \
      -f "$SCRIPT_DIR/rows.jq" "$CACHE" 2>/dev/null | awk -F'\t' '
  $1 == "H" { prov = $2 }
  $1 == "P" && last == "pool" { print $2; found = 1; exit }
  $1 == "P" && last == "acct" && cand == "" { cand = $2 }
  { last = ($1 == "Q" && $2 == "Weekly") ? "pool" \
         : ($1 == "W" && $2 == "Weekly" && prov == "claude") ? "acct" : "" }
  END { if (!found && cand != "") print cand }')

[ -n "$d" ] || exit 0
# d = used minus what an even pace allows (+ over pace, - reserve).
awk -v d="$d" -v t="$THRESHOLD" 'BEGIN {
  a = d < 0 ? -d : d
  if (a <= t) exit
  n = sprintf("%.0f", a)
  if (d < 0) printf "#[fg=green,bold]+%s%%#[default] ", n
  else       printf "#[fg=red,bold]-%s%%#[default] ", n
}'
