#!/usr/bin/env bash
# Render the usage popup from the cache written by refresh.sh.
# Keys: r = force refresh, q / Esc = close.
# Under 70 columns (phone-sized clients) a compact layout is used.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$HOME/.cache/tmux-agentic-usage"
CACHE="$CACHE_DIR/usage.json"
REFRESH="$SCRIPT_DIR/refresh.sh"
JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"

# "open" mode: size the popup to the client so small (mobile) terminals
# don't fail with "height too large", then re-run ourselves inside it.
if [ "${1:-}" = "open" ]; then
  cw=$(tmux display -p '#{client_width}')
  ch=$(tmux display -p '#{client_height}')
  # Height follows the content (accounts come and go): body lines, the line the
  # cursor waits on, and the two border rows.
  rows=$(bash "$0" count 2>/dev/null)
  [[ "$rows" =~ ^[0-9]+$ ]] || rows=22
  pw=84; ph=$(( rows + 3 ))
  [ "$cw" -le 86 ] 2>/dev/null && pw='100%'
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

# "2026-09-04T12:50:00Z" -> relative time, local clock.
# Wide: "in 4h 55m" / "in 3d 13h" — compact: "4h55m" / "3d13h"
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

rel_until() {
  local epoch now diff
  epoch=$(iso_epoch "$1") || { echo "?"; return; }
  now=$(date +%s); diff=$(( epoch - now ))
  if (( diff <= 0 )); then echo "now"; return; fi
  if (( MOBILE )); then fmt_secs "$diff"; return; fi
  # Wide: relative plus the exact local clock time, day prefix past midnight.
  local fmt="%H:%M"
  (( diff >= 86400 )) && fmt="%a %-d.%-m. %H:%M"
  local at
  at=$(date -r "$epoch" "+$fmt" 2>/dev/null || date -d "@$epoch" "+$fmt" 2>/dev/null)
  echo "in $(fmt_secs "$diff") ($at)"
}

draw_bar() { # $1 = percent left -> colored bar
  local left=$1 width filled i out="" color
  if (( MOBILE )); then width=8; else width=20; fi
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

pace_color() { # $1 = deltaPercent, $2 = willLastToReset
  if [ "$2" = "false" ]; then printf '%s' "$RED"
  elif [ "${1#-}" != "$1" ] || [ "$1" = "0" ]; then printf '%s' "$GREEN"
  else printf '%s' "$YELLOW"
  fi
}

# Pace line in plain words. The window is a tank that refills at reset, so the
# only comparison that matters is "how much of the window is gone" against
# "how much of the quota is gone". Used for windows under a day (session).
#   $1 = window name (session/week)  $2 = used label ("18%", "10% of pool")
#   $3 = delta%  $4 = elapsed%
#   $5 = willLastToReset             $6 = etaSeconds or ""
pace_line() {
  local win=$1 used=$2 delta=$3 elapsed=$4 lasts=$5 eta=$6 pace end
  if (( elapsed == 0 )); then echo "$win just reset"; return; fi
  if (( delta < 0 )); then pace="$(( -delta ))% under pace"
  elif (( delta == 0 )); then pace="on pace"
  else pace="${delta}% over pace"
  fi
  if (( MOBILE )); then
    [ "$lasts" = "false" ] && pace="$pace · runs out!"
    echo "${elapsed}% of $win gone · $pace"
    return
  fi
  if [ "$lasts" != "false" ]; then end="lasts until reset"
  elif [ -n "$eta" ]; then end="runs out in $(fmt_secs "$eta")"
  else end="runs out before reset"
  fi
  echo "${elapsed}% of $win elapsed · ${used} used · $pace · $end"
}

# Pace of a window of a day or more, as a daily budget: capacity / days in the
# window (one Claude week 14.3 %/day, two accounts 28.6 %/day), against what was
# actually spent per elapsed day. Projected from the first hour.
#   $1 = day  $2 = %/day spent  $3 = %/day budget  $4 = lasts  $5 = days in window
#   $6 = run-out epoch or ""
daily_line() {
  local day=$1 burn=$2 budget=$3 lasts=$4 wd=$5 out=$6 end
  if [ "$day" = "0" ]; then echo "week just reset · budget ${budget}%/day"; return; fi
  if [ "$lasts" != "false" ]; then end="lasts until reset"
  elif (( MOBILE )); then end="out $(date -r "$out" '+%a %H:%M' 2>/dev/null || date -d "@$out" '+%a %H:%M')"
  else end="runs out $(date -r "$out" '+%a %-d.%-m. %H:%M' 2>/dev/null || date -d "@$out" '+%a %-d.%-m. %H:%M')"
  fi
  if (( MOBILE )); then echo "d${day}/${wd} · ${burn} of ${budget}%/d · $end"
  else echo "day ${day} of ${wd} · ${burn}%/day, budget ${budget}%/day · $end"; fi
}

# Green under budget, yellow over budget but lasting, red when it runs out first.
daily_color() { # $1 = %/day spent, $2 = budget, $3 = lasts
  if [ "$3" = "false" ]; then printf '%s' "$RED"
  elif awk -v b="$1" -v g="$2" 'BEGIN { exit !(b <= g) }'; then printf '%s' "$GREEN"
  else printf '%s' "$YELLOW"
  fi
}

render() {
  clear
  MOBILE=0
  (( $(tput cols) < 70 )) && MOBILE=1

  if [ ! -f "$CACHE" ]; then
    printf '\n  No cache yet. Press %sr%s to fetch (~25s).\n' "$BOLD" "$RST"
    return
  fi

  "$JQ" -r --argjson now "$(date +%s)" -f "$SCRIPT_DIR/rows.jq" "$CACHE" | while IFS=$'\t' read -r kind a b c d e f; do
    case "$kind" in
      H)
        # a = provider, b = plan, c = email, d = active | stale:<min> | login:<min>
        name=$(printf '%s' "$a" | tr '[:lower:]' '[:upper:]')
        extra=""
        [ -n "$b" ] && extra=" ${DIM}${b}${RST}"
        if [ -n "$c" ]; then
          if (( MOBILE )); then extra=" ${DIM}${c%@*}${RST}"; else extra="$extra ${DIM}${c}${RST}"; fi
        fi
        case "$d" in
          active) extra="$extra ${GREEN}●${RST}" ;;
          stale:*) extra="$extra ${YELLOW}stale $(fmt_secs $(( ${d#stale:} * 60 )))${RST}" ;;
          login:*) extra="$extra ${RED}/login to this account to refresh${RST}" ;;
        esac
        printf '\n %s%s%s%s\n' "$BOLD" "$name" "$RST" "$extra"
        ;;
      Q)
        # a = title, b = used % summed over the accounts, c = number of accounts
        title=${a/ only/}
        win_name=week
        win_used="$(( (b + c / 2) / c ))% of pool"
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
        title=${a/ only/}
        win_used="$b%"
        case "$title" in Session) win_name=session ;; *) win_name=week ;; esac
        left=$(( 100 - b ))
        if (( MOBILE )); then
          printf ' %-7s %s%3d%%%s %s %s%s%s\n' \
            "$title" "$BOLD" "$left" "$RST" "$(draw_bar "$left")" "$DIM" "$(rel_until "$c")" "$RST"
        else
          printf '  %-8s %s%3d%%%s left  %s  %sresets %s%s\n' \
            "$title" "$BOLD" "$left" "$RST" "$(draw_bar "$left")" "$DIM" "$(rel_until "$c")" "$RST"
        fi
        ;;
      D)
        if [ "$a" = "0" ]; then color=$DIM; else color=$(daily_color "$b" "$c" "$d"); fi
        line=$(daily_line "$a" "$b" "$c" "$d" "$e" "$f")
        if (( MOBILE )); then printf ' %s▸ %s%s\n' "$color" "$line" "$RST"
        else printf '  %s▸ %s%s\n' "$color" "$line" "$RST"; fi
        ;;
      P)
        # a = delta%, b = elapsed%, c = willLastToReset, d = etaSeconds
        if (( b == 0 )); then color=$DIM; else color=$(pace_color "$a" "$c"); fi
        line=$(pace_line "$win_name" "$win_used" "$a" "$b" "$c" "$d")
        if (( MOBILE )); then printf ' %s▸ %s%s\n' "$color" "$line" "$RST"
        else printf '  %s▸ %s%s\n' "$color" "$line" "$RST"; fi
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
  done

  local mtime now age
  mtime=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  now=$(date +%s); age=$(( (now - mtime) / 60 ))
  if (( MOBILE )); then
    printf '\n %supd %dm · r=refresh q=quit%s\n' "$DIM" "$age" "$RST"
  else
    printf '\n %supdated %dm ago · r refresh · q quit%s\n' "$DIM" "$age" "$RST"
  fi
}

# "count" mode: how many lines the popup body needs, for sizing it in "open".
if [ "${1:-}" = "count" ]; then
  render 2>/dev/null | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | wc -l | tr -d ' '
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
