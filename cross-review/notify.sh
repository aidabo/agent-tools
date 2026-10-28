#!/usr/bin/env bash
# notify.sh — inbox に未通知のレビューがあるエージェントへ、手すきのときだけ 1 行送る。
#
# 「手すき」= 作業中の表示が無く、入力欄が空（codex の薄字の placeholder は空とみなす）。
# 作業中・入力中・ダイアログ表示中は送らない。cron の watch.sh が数分おきに呼ぶので、
# 次の巡回で手すきになっていれば届く。送ったポインタには .notified（中身は送った先のエージェントの PID）を付けて
# 二度送らない。ただしその PID がもう無い（セッションを閉じた・再起動した）なら、新しいセッションに送り直す。
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"
log() { echo "[notify] $*" >&2; }
[[ "${NOTIFY:-1}" == 1 ]] || exit 0

# エージェントのプロセス（pane のシェルの子）を探し、"pane_id agent_pid" を出す
panes_of() {
  local want="$1"
  tmux list-panes -a -F '#{pane_id} #{pane_pid}' 2>/dev/null | while read -r id spid; do
    ps -o pid=,args= --ppid "$spid" 2>/dev/null | while read -r cpid args; do
      case "$want" in
        codex)    [[ "$args" == *bin/codex* ]] && echo "$id $cpid" ;;
        deepseek) [[ "$args" == *claw/deepseek* ]] && echo "$id $(ps -o pid= --ppid "$cpid" | head -1 | tr -d ' ')" ;;
        claude)   [[ "$args" == claude* ]] && echo "$id $cpid" ;;
      esac
    done
  done
}

# 0 = 手すき（送ってよい）
pane_is_idle() {
  tmux capture-pane -e -p -t "$1" 2>/dev/null | python3 -c '
import re, sys
raw = sys.stdin.read().splitlines()
ansi = re.compile(r"\x1b\[[0-9;]*m")
plain = [ansi.sub("", l) for l in raw]
# 入力行 = 最後の › (codex) か ❯ (Claude Code) で始まる行
idx = max((i for i, l in enumerate(plain) if l.lstrip().startswith(("›", "❯"))), default=-1)
if idx < 0:
    sys.exit(1)                      # 入力欄が見えない（ダイアログ中など）
# 入力欄の中身: 薄字（ESC[2m … ESC[0m/22m）の placeholder を除いてから空か判定
line = re.sub(r"\x1b\[2m.*?(\x1b\[0m|\x1b\[22m|$)", "", raw[idx])
text = ansi.sub("", line).strip().lstrip("›❯").strip()
if text:
    sys.exit(1)                      # 人が入力中
around = "\n".join(plain[max(0, idx - 5):])
if "esc to interrupt" in around:     # codex / 旧 Claude Code の作業中表示
    sys.exit(1)
if re.search(r"…\s*\((\d+[hms]\s*)+", around):   # Claude Code の作業中スピナー「…(39s ·」
    sys.exit(1)
sys.exit(0)
'
}

# レポートのリポジトリの作業ツリーにいる pane を優先（同じ種類のエージェントが複数いるとき）
pick_pane() {
  local agent="$1" repo="$2" best="" src=""
  for entry in "${REPOS[@]}"; do IFS='|' read -r n _ s _ <<<"$entry"; [[ "$n" == "$repo" ]] && src="$s"; done
  while read -r id pid; do
    [[ -z "$id" ]] && continue
    [[ -z "$best" ]] && best="$id"
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    if [[ -n "$src" && "$cwd" == "$src"* ]]; then best="$id $pid"; break; fi
    [[ "$best" == "$id" ]] && best="$id $pid"
  done < <(panes_of "$agent")
  echo "$best"
}

# 送ってよいポインタ: まだ送っていない、または送った先のエージェントのプロセスがもう無い
needs_notice() {
  local f="$1" pid
  [[ -e "$f.notified" ]] || return 0
  pid="$(cat "$f.notified" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ && ! -d "/proc/$pid" ]]   # 中身が空（以前の形式）は送り済みとみなす
}

for agent in claude codex deepseek; do
  dir="$INBOX_DIR/$agent"; [[ -d "$dir" ]] || continue
  mapfile -t fresh < <(find "$dir" -maxdepth 1 -name '*.txt' 2>/dev/null | sort | while read -r f; do needs_notice "$f" && echo "$f"; done)
  [[ ${#fresh[@]} -gt 0 ]] || continue
  repo=""
  for entry in "${REPOS[@]}"; do IFS='|' read -r n _ _ _ <<<"$entry"; [[ "$(basename "${fresh[0]}")" == "$n-pr"* ]] && repo="$n"; done
  read -r pane agent_pid <<<"$(pick_pane "$agent" "$repo")"
  if [[ -z "$pane" ]]; then log "$agent: pane が見つからない（起動していない）— 保留 ${#fresh[@]} 件"; continue; fi
  if ! pane_is_idle "$pane"; then log "$agent ($pane): 作業中か入力中 — 次の巡回で再試行"; continue; fi
  msg="cross-review: ${INBOX_DIR/#$HOME/~}/$agent/ にレビューが ${#fresh[@]} 件届きました。${CROSS_REVIEW_HOME/#$HOME/~}/PROTOCOL.md の「レビューを受け取る」に従って対応してください。"
  tmux send-keys -t "$pane" -l "$msg"
  sleep "${SENDTMUX_DELAY_SECONDS:-1}"
  tmux send-keys -t "$pane" Enter
  for f in "${fresh[@]}"; do echo "$agent_pid" > "$f.notified"; done
  log "$agent ($pane): 通知しました（${#fresh[@]} 件）"
done
