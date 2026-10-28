#!/usr/bin/env bash
set -euo pipefail

target="${1:?target required}"
shift
message="${*:-}"
delay="${SENDTMUX_DELAY_SECONDS:-1}"

if [[ -z "$message" ]]; then
  echo "message required" >&2
  exit 1
fi

tmux send-keys -t "$target" "$message"
sleep "$delay"
tmux send-keys -t "$target" C-m
