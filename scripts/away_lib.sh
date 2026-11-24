# Shared by popup.sh and status.sh: the away periods the pace plans around.
AWAY_FILE="${AWAY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/tmux-agentic-usage/away}"

# Away periods from $AWAY_FILE, one per line: "YYYY-MM-DD HH:MM YYYY-MM-DD HH:MM"
# (local time, start and end). Printed as a JSON array of [startEpoch, endEpoch].
local_epoch() { # "YYYY-MM-DD HH:MM" local -> epoch
  date -jf "%Y-%m-%d %H:%M" "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null
}
away_json() {
  local out="" a b c d s e
  if [ -f "$AWAY_FILE" ]; then
    while read -r a b c d _; do
      [[ "$a" =~ ^[0-9]{4}- ]] || continue
      s=$(local_epoch "$a $b") || continue
      e=$(local_epoch "$c $d") || continue
      (( e > s )) && out+="${out:+,}[$s,$e]"
    done <"$AWAY_FILE"
  fi
  printf '[%s]' "$out"
}
