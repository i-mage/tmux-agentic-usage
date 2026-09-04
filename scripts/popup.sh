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
  pw=84; ph=24
  [ "$cw" -le 86 ] 2>/dev/null && pw='100%'
  [ "$ch" -le 26 ] 2>/dev/null && ph='100%'
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
rel_until() {
  local epoch now diff
  epoch=$(iso_epoch "$1") || { echo "?"; return; }
  now=$(date +%s); diff=$(( epoch - now ))
  if (( diff <= 0 )); then echo "now"; return; fi
  if (( MOBILE )); then
    if (( diff < 86400 )); then echo "$(( diff / 3600 ))h$(( diff % 3600 / 60 ))m"
    else echo "$(( diff / 86400 ))d$(( diff % 86400 / 3600 ))h"; fi
  else
    if (( diff < 86400 )); then echo "in $(( diff / 3600 ))h $(( diff % 3600 / 60 ))m"
    else echo "in $(( diff / 86400 ))d $(( diff % 86400 / 3600 ))h"; fi
  fi
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

render() {
  clear
  MOBILE=0
  (( $(tput cols) < 70 )) && MOBILE=1

  if [ ! -f "$CACHE" ]; then
    printf '\n  No cache yet. Press %sr%s to fetch (~25s).\n' "$BOLD" "$RST"
    return
  fi

  "$JQ" -r '
    # codexbar omits the pace block for a barely-used window (e.g. right
    # after a session reset); synthesize one from elapsed time vs used %.
    def synthp:
      . as $u |
      if $u == null or ($u.resetsAt // "") == "" then empty else
        (($u.windowMinutes // 300) * 60) as $win |
        ($u.resetsAt | try fromdateiso8601 catch null) as $reset |
        if $reset == null then empty else
          ((((1 - (($reset - now) / $win)) * 100)
            | if . < 0 then 0 elif . > 100 then 100 else . end) | round) as $exp |
          ($u.usedPercent // 0) as $used |
          ($used - $exp) as $delta |
          (if $exp <= 0 then ($used == 0) else $used <= $exp end) as $lasts |
          ((if $delta < 0 then "\(0 - $delta)% in reserve"
            elif $delta == 0 then "On pace"
            else "\($delta)% over pace" end)
           + " | Expected \($exp)% used | "
           + (if $lasts then "Lasts until reset" else "Projected to run out" end)) as $sum |
          (["P", $sum, ($delta | tostring), ($lasts | tostring)] | @tsv)
        end
      end;
    sort_by(.provider) | .[] |
    if .error != null then
      ["E", (.provider // "?"), (.error.message // "error")] | @tsv
    else
      (["H", .provider,
        (.usage.identity.loginMethod // .usage.loginMethod // ""),
        (.usage.identity.accountEmail // .usage.accountEmail // "")] | @tsv),
      (if .usage.primary != null then
        ["W", "Session", (.usage.primary.usedPercent // 0), (.usage.primary.resetsAt // "")] | @tsv else empty end),
      (if .pace.primary != null then
        ["P", .pace.primary.summary, (.pace.primary.deltaPercent // 0),
         (.pace.primary.willLastToReset | tostring)] | @tsv
       else (.usage.primary | synthp) end),
      (if .usage.secondary != null then
        ["W", "Weekly", (.usage.secondary.usedPercent // 0), (.usage.secondary.resetsAt // "")] | @tsv else empty end),
      (if .pace.secondary != null then
        ["P", .pace.secondary.summary, (.pace.secondary.deltaPercent // 0),
         (.pace.secondary.willLastToReset | tostring)] | @tsv
       else (.usage.secondary | synthp) end),
      (.usage.extraRateWindows[]? |
        ["W", .title, (.window.usedPercent // 0), (.window.resetsAt // "")] | @tsv),
      (if .usage.codexResetCredits != null then
        ["C", .usage.codexResetCredits.availableCount] | @tsv else empty end)
    end
  ' "$CACHE" | while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      H)
        name=$(printf '%s' "$a" | tr '[:lower:]' '[:upper:]')
        extra=""
        [ -n "$b" ] && extra=" ${DIM}${b}${RST}"
        if (( ! MOBILE )) && [ -n "$c" ]; then extra="$extra ${DIM}${c}${RST}"; fi
        printf '\n %s%s%s%s\n' "$BOLD" "$name" "$RST" "$extra"
        ;;
      W)
        title=${a/ only/}
        left=$(( 100 - b ))
        if (( MOBILE )); then
          printf ' %-7s %s%3d%%%s %s %s%s%s\n' \
            "$title" "$BOLD" "$left" "$RST" "$(draw_bar "$left")" "$DIM" "$(rel_until "$c")" "$RST"
        else
          printf '  %-8s %s%3d%%%s left  %s  %sresets %s%s\n' \
            "$title" "$BOLD" "$left" "$RST" "$(draw_bar "$left")" "$DIM" "$(rel_until "$c")" "$RST"
        fi
        ;;
      P)
        color=$(pace_color "$b" "$c")
        if (( MOBILE )); then
          # Rebuild a short pace line from delta + willLastToReset.
          if [ "${b#-}" != "$b" ]; then short="${b#-}% in reserve"
          elif [ "$b" = "0" ]; then short="on pace"
          else short="${b}% over pace"
          fi
          [ "$c" = "false" ] && short="$short · runs out!"
          printf ' %s▸ %s%s\n' "$color" "$short" "$RST"
        else
          printf '  %s▸ %s%s\n' "$color" "${a//| /· }" "$RST"
        fi
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
