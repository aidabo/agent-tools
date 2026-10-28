#!/usr/bin/env bash
# monitor.sh — レビューとエージェントの状態ボード（status.py）を、作業用とは別の tmux セッションに開く。
# 下の pane はレビューの実況（../cross-review/live.sh）: 巡回の流れと、実行中のレビューの一歩一歩。
#
#   monitor.sh             セッションが無ければ作り、そこへ移る（tmux の中なら switch-client、外なら attach）
#   monitor.sh --detach    作るだけで移らない（start-agents.sh が使う）
#
# 作業用のセッションへは prefix + L（直前のセッション）で戻る。ボードは q で閉じる（セッションも消える）。
# 環境変数: AGENTS_MONITOR_SESSION（既定 agents-monitor）
set -euo pipefail

detach=false
for arg in "$@"; do
  case "$arg" in
    --detach) detach=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

script_dir="$(dirname "$(readlink -f "$0")")"
session="${AGENTS_MONITOR_SESSION:-agents-monitor}"

live_script="$script_dir/../cross-review/live.sh"

if ! tmux has-session -t "=$session" 2>/dev/null; then
  board="$(tmux new-session -d -P -F '#{pane_id}' -s "$session" -n status "python3 $(printf '%q' "$script_dir/status.py")")"
  tmux select-pane -t "$board" -T "board"
  if [[ -f "$live_script" ]]; then
    live="$(tmux split-window -v -l 45% -P -F '#{pane_id}' -t "$board" "bash $(printf '%q' "$live_script")")"
    tmux select-pane -t "$live" -T "review — live"
    tmux select-pane -t "$board"
  fi
  tmux set-window-option -t "$session:status" pane-border-status top >/dev/null
  tmux set-window-option -t "$session:status" pane-border-format ' #{pane_title} ' >/dev/null
  echo "[monitor] Created session '$session'."
fi

[[ "$detach" == true ]] && exit 0
if [[ -n "${TMUX:-}" ]]; then
  tmux switch-client -t "=$session"
else
  tmux attach -t "=$session"
fi
