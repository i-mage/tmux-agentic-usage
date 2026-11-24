#!/usr/bin/env bash
# Away periods the popup paces around (time away is not working time).
#   away.sh                                  list them
#   away.sh "2026-11-28 12:00" "2026-11-29 14:00"   add one (local time)
#   away.sh clear                            remove all
# Stored one per line in ~/.config/tmux-agentic-usage/away.
set -euo pipefail
FILE="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-agentic-usage/away"
mkdir -p "$(dirname "$FILE")"

case "${1:-}" in
  "") [ -s "$FILE" ] && grep -v '^#' "$FILE" || echo "no away periods" ;;
  clear) : >"$FILE"; echo "cleared" ;;
  *)
    [ $# -eq 2 ] || { echo "usage: away.sh \"YYYY-MM-DD HH:MM\" \"YYYY-MM-DD HH:MM\"" >&2; exit 2; }
    for t in "$1" "$2"; do
      date -jf "%Y-%m-%d %H:%M" "$t" +%s >/dev/null 2>&1 || date -d "$t" +%s >/dev/null 2>&1 \
        || { echo "not a time: $t" >&2; exit 2; }
    done
    echo "$1 $2" >>"$FILE"; echo "away $1 → $2" ;;
esac
