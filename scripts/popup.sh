#!/usr/bin/env bash
# Render the usage popup from the cache written by refresh.sh.
# Keys: r = force refresh, q / Esc = close.
# Under 50 columns (phone-sized clients) a compact layout is used. The bars take
# whatever width the popup has (24. 11. 2026, owner).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${AGENTIC_USAGE_CACHE_DIR:-$HOME/.cache/tmux-agentic-usage}"
CACHE="$CACHE_DIR/usage.json"
AWAY_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-agentic-usage/away"
REFRESH="$SCRIPT_DIR/refresh.sh"
JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"

# "open" mode: size the popup to the client so small (mobile) terminals
# don't fail with "height too large", then re-run ourselves inside it.
if [ "${1:-}" = "open" ]; then
  cw=$(tmux display -p '#{client_width}')
  ch=$(tmux display -p '#{client_height}')
  # Height follows the content (accounts come and go): body lines, the line the
  # cursor waits on, and the two border rows.
  # Width: the widest text line (bars measured at 20) plus borders and a margin,
  # at least 64 columns; the bars then stretch to fill it.
  read -r rows cols <<<"$(bash "$0" count 2>/dev/null)"
  [[ "$rows" =~ ^[0-9]+$ ]] || rows=22
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=60
  pw=$(( cols + 4 )); (( pw < 64 )) && pw=64; ph=$(( rows + 3 ))
  [ "$cw" -le $(( pw + 2 )) ] 2>/dev/null && pw='100%'
  [ "$ch" -le $(( ph + 2 )) ] 2>/dev/null && ph='100%'
  exec tmux display-popup -E -w "$pw" -h "$ph" -T ' Agentic usage ' "bash $0"
fi

ESC=$'\033'
RST="${ESC}[0m"; BOLD="${ESC}[1m"; DIM="${ESC}[2m"
RED="${ESC}[31m"; GREEN="${ESC}[32m"; YELLOW="${ESC}[33m"; CYAN="${ESC}[36m"

iso_epoch() { # BSD date first, GNU date as fallback
  date -jf "%Y-%m-%dT%H:%M:%S%z" "${1%Z}+0000" +%s 2>/dev/null \
    || date -d "$1" +%s 2>/dev/null
}

fmt_secs() { # seconds -> "4h 55m" / "3d 13h" (compact: "4h55m" / "3d13h")
  local diff=$1
  if (( MOBILE )); then
    if (( diff < 86400 )); then echo "$(( diff / 3600 ))h$(( diff % 3600 / 60 ))m"
    else echo "$(( diff / 86400 ))d$(( diff % 86400 / 3600 ))h"; fi
  else
    if (( diff < 86400 )); then echo "$(( diff / 3600 ))h $(( diff % 3600 / 60 ))m"
    else echo "$(( diff / 86400 ))d $(( diff % 86400 / 3600 ))h"; fi
  fi
}

# "2026-09-04T12:50:00Z" -> when it resets, local clock: "Mon 23:00" (a week or
# more ahead: "Mon 7.12. 23:00"). The moment, never a countdown (24. 11. 2026, owner).
reset_at() {
  local epoch
  epoch=$(iso_epoch "$1") || { echo "?"; return; }
  (( epoch <= $(date +%s) )) && { echo "now"; return; }
  at_local $(( epoch + 30 ))  # stamps like 17:59:59 read as 18:00
}

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

at_local() { # epoch -> "Sat 12:00" (a week or more away: "Sat 5.12. 12:00")
  local fmt="%a %H:%M"
  (( $1 - $(date +%s) >= 7 * 86400 )) && fmt="%a %-d.%-m. %H:%M"
  date -r "$1" "+$fmt" 2>/dev/null || date -d "@$1" "+$fmt" 2>/dev/null
}

draw_bar() { # $1 = percent left -> colored bar, BARW wide
  local left=$1 width=$BARW filled i out="" color
  (( filled = left * width / 100 ))
  if   (( left >= 40 )); then color=$GREEN
  elif (( left >= 15 )); then color=$YELLOW
  else                        color=$RED
  fi
  for (( i = 0; i < width; i++ )); do
    if (( i < filled )); then out+="█"; else out+="░"; fi
  done
  printf '%s' "${color}${out}${RST}"
}

# Pace line: only how far the use is from an even pace by now. Red more than 3 %
# over pace, yellow within 3 % either way, green more than 3 % in reserve. With an
# away period ahead the even pace counts only the working time.
#   $1 = diff% (+ over pace, - reserve)
pace_line() {
  local d=$1 abs=${1#-} color text
  if awk -v d="$d" 'BEGIN { exit !(d > 3) }'; then color=$RED
  elif awk -v d="$d" 'BEGIN { exit !(d < -3) }'; then color=$GREEN
  else color=$YELLOW; fi
  if [ "$d" = "0" ]; then text="on pace"
  elif [ "${d#-}" != "$d" ]; then text="${abs}% reserve"
  else text="${d}% over pace"; fi
  if (( MOBILE )); then printf ' %s▸ %s%s\n' "$color" "$text" "$RST"
  else printf '  %s▸ %s%s\n' "$color" "$text" "$RST"; fi
}

render() {
  [ -z "${PRINT:-}" ] && clear
  local cols rows_out
  cols=${COLS:-$(tput cols)}
  MOBILE=0
  (( cols < 50 )) && MOBILE=1

  if [ ! -f "$CACHE" ]; then
    printf '\n  No cache yet. Press %sr%s to fetch (~25s).\n' "$BOLD" "$RST"
    return
  fi

  rows_out=$("$JQ" -r --argjson now "$(date +%s)" --argjson away "$(away_json)" \
    -f "$SCRIPT_DIR/rows.jq" "$CACHE")
  # Bars fill the line: what the label and the percent leave, minus room for the
  # pool's "of 200%" (wide) or "/200%" (compact) after the bar.
  if (( MOBILE )); then BARW=$(( cols - 14 - 7 ))
  elif grep -q $'^Q' <<<"$rows_out"; then BARW=$(( cols - 22 - 10 ))
  else BARW=$(( cols - 22 - 1 )); fi
  [ -n "${COUNT_BARW:-}" ] && BARW=$COUNT_BARW
  (( BARW < 8 )) && BARW=8
  while IFS=$'\t' read -r kind a b c d e f; do
    case "$kind" in
      A)
        # a, b = away start and end: the pace below plans around it.
        printf '\n %saway %s → %s%s\n' "$CYAN" "$(at_local "$a")" "$(at_local "$b")" "$RST"
        ;;
      R)
        # a = the reset this account's week windows share, said once.
        if (( MOBILE )); then printf ' %sresets %s%s\n' "$DIM" "$(reset_at "$a")" "$RST"
        else printf '  %sresets %s%s\n' "$DIM" "$(reset_at "$a")" "$RST"; fi
        ;;
      H)
        # a = provider, b = plan, c = email, d = active | stale:<min> | login:<min>
        name=$(printf '%s' "$a" | tr '[:lower:]' '[:upper:]')
        extra=""
        [ -n "$b" ] && extra=" ${DIM}${b}${RST}"
        if [ -n "$c" ]; then
          if (( MOBILE )); then extra=" ${DIM}${c%@*}${RST}"; else extra="$extra ${DIM}${c}${RST}"; fi
        fi
        [ "$d" = active ] && extra="$extra ${GREEN}●${RST}"
        printf '\n %s%s%s%s\n' "$BOLD" "$name" "$RST" "$extra"
        # e = why the last update of this account failed; its numbers are that old.
        case "$d" in
          stale:*|login:*)
            if [ "${d%%:*}" = login ]; then color=$RED; else color=$YELLOW; fi
            printf ' %s ⚠ not updated for %s: %s%s\n' "$color" \
              "$(fmt_secs $(( ${d#*:} * 60 )))" "${e:-update failed}" "$RST" ;;
        esac
        ;;
      Q)
        # a = title, b = used % summed over the accounts, c = number of accounts
        title=${a/ only/}
        left=$(( c * 100 - b ))
        if (( MOBILE )); then
          printf ' %-7s %s%3d%%%s %s %s/%d%%%s\n' \
            "$title" "$BOLD" "$left" "$RST" "$(draw_bar $(( left / c )))" "$DIM" $(( c * 100 )) "$RST"
        else
          printf '  %-8s %s%3d%%%s left  %s  %sof %d%%%s\n' \
            "$title" "$BOLD" "$left" "$RST" "$(draw_bar $(( left / c )))" "$DIM" $(( c * 100 )) "$RST"
        fi
        ;;
      W)
        # c = reset, empty when the account's header line already said it. It goes
        # on its own line under the bar, so the bar keeps the whole width.
        title=${a/ only/}
        left=$(( 100 - b ))
        if (( MOBILE )); then
          printf ' %-7s %s%3d%%%s %s\n' "$title" "$BOLD" "$left" "$RST" "$(draw_bar "$left")"
          [ -n "$c" ] && printf ' %sresets %s%s\n' "$DIM" "$(reset_at "$c")" "$RST"
        else
          printf '  %-8s %s%3d%%%s left  %s\n' "$title" "$BOLD" "$left" "$RST" "$(draw_bar "$left")"
          [ -n "$c" ] && printf '  %sresets %s%s\n' "$DIM" "$(reset_at "$c")" "$RST"
        fi
        ;;
      P)
        pace_line "$a"
        ;;
      C)
        if (( MOBILE )); then
          printf ' %sCredits: %s%s\n' "$CYAN" "$a" "$RST"
        else
          printf '  %sReset credits: %s available%s\n' "$CYAN" "$a" "$RST"
        fi
        ;;
      E)
        printf '\n %s%s%s  %s%s%s\n' "$BOLD" "$a" "$RST" "$RED" "$b" "$RST"
        ;;
    esac
  done <<<"$rows_out"

  local mtime now age
  mtime=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  now=$(date +%s); age=$(( (now - mtime) / 60 ))
  local st
  st=$(cat "$CACHE_DIR/refresh.status" 2>/dev/null)
  if [ "${st%% *}" = fail ]; then
    printf '\n %s⚠ last refresh failed at %s: %s%s' "$RED" \
      "$(date -r "$(cut -d' ' -f2 <<<"$st")" '+%H:%M' 2>/dev/null)" "$(cut -d' ' -f3- <<<"$st")" "$RST"
  fi
  if (( MOBILE )); then
    printf '\n %supd %dm · r=refresh q=quit%s\n' "$DIM" "$age" "$RST"
  else
    printf '\n %supdated %dm ago · r refresh · q quit%s\n' "$DIM" "$age" "$RST"
  fi
}

# "print" mode: render once to stdout at $2 columns, no screen clearing (tests).
# "count" mode: lines and widest line (in characters) of the popup body, for
# sizing it in "open"; bars measured at 20 (the popup is not open yet).
if [ "${1:-}" = "print" ] || [ "${1:-}" = "count" ]; then
  export LC_ALL=en_US.UTF-8
  PRINT=1
  if [ "$1" = print ]; then COLS=${2:-80}; render; exit 0; fi
  COLS=200 COUNT_BARW=20
  render 2>/dev/null | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | {
    n=0; w=0
    while IFS= read -r line; do n=$(( n + 1 )); (( ${#line} > w )) && w=${#line}; done
    echo "$n $w"
  }
  exit 0
fi

# Kick a background refresh when the cache is older than the interval,
# so an open popup on a cold cache heals itself without blocking.
interval="$(tmux show-option -gqv @agentic-usage-interval 2>/dev/null)"
interval="${interval:-300}"
if [ -f "$CACHE" ] && [ "$interval" != "0" ]; then
  mtime=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  if (( $(date +%s) - mtime > interval )); then
    (bash "$REFRESH" >/dev/null 2>&1 &)
  fi
fi

tput civis 2>/dev/null
trap 'tput cnorm 2>/dev/null' EXIT

while true; do
  render
  IFS= read -rsn1 key
  case "$key" in
    r|R)
      printf '\n %sRefreshing (~25s)…%s' "$CYAN" "$RST"
      bash "$REFRESH"
      ;;
    q|Q|"$ESC")
      break
      ;;
  esac
done
