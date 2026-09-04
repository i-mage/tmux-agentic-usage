#!/usr/bin/env bash
# tmux-agentic-usage TPM entry point.
# Binds the popup key and starts the background cache refresher.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

get_opt() { # $1 = option, $2 = default
  local v
  v="$(tmux show-option -gqv "$1")"
  echo "${v:-$2}"
}

key="$(get_opt @agentic-usage-key 'M-U')"
interval="$(get_opt @agentic-usage-interval '300')"

tmux bind-key -n "$key" run-shell "bash $CURRENT_DIR/scripts/popup.sh open"

if [ "$interval" != "0" ]; then
  tmux run-shell -b "bash $CURRENT_DIR/scripts/daemon.sh $interval"
fi
