#!/usr/bin/env bash
# status.sh — cross-review の状態を GitHub の PR 一覧のように出す。読むだけで、レビューは走らせない。
#
#   status.sh [--no-color]
#
# 1 PR 1 行、新しい順。上に開いている PR（WAITING / IN REVIEW / CHANGES REQUESTED / REVIEWED / APPROVED / SKIPPED）、
# 下に最近マージ・クローズした PR（CROSS_REVIEW_DONE_DAYS 日、既定 3）。各行に「作者 → レビュアーと判定」。
# 描画は status.py（日本語タイトルの幅をそろえるため）。ここは config.sh を読んで渡すだけ。
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

[[ "${1:-}" == "--no-color" ]] && export CR_NO_COLOR=1

repos=""
for entry in "${REPOS[@]}"; do
  IFS='|' read -r name gh_repo src wt <<<"$entry"
  repos+="$name|$gh_repo|$wt|$(report_dir_for "$src")"$'\n'
done

# 巡回（cron の watch.sh）
D=$'\e[2m'; R=$'\e[31m'; Z=$'\e[0m'
[[ -n "${CR_NO_COLOR:-}" || -n "${NO_COLOR:-}" || ( ! -t 1 && -z "${FORCE_COLOR:-}" ) ]] && D="" R="" Z=""
if crontab -l 2>/dev/null | grep -v '^\s*#' | grep -q "cross-review/watch.sh"; then
  if [[ -e "$STATE_DIR/watch.lock" ]]; then
    cron_line="${D}cron: every pass checks open PRs / last $(date -d "@$(stat -c %Y "$STATE_DIR/watch.lock")" +%H:%M)${Z}"
  else
    cron_line="${D}cron: registered, not run yet${Z}"
  fi
else
  cron_line="${R}cron: watch.sh is not in crontab (README「定期実行」)${Z}"
fi

CR_REPOS="$repos" CR_STATE_DIR="$STATE_DIR" CR_INBOX_DIR="$INBOX_DIR" \
CR_TRUSTED="${TRUSTED_AUTHORS:-}" CR_CRON_LINE="$cron_line" \
  exec python3 "$here/status.py"
