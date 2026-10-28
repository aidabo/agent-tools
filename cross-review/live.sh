#!/usr/bin/env bash
# live.sh — レビューの実況（監視セッションのレビュー用 pane で動く）。読むだけ。
#
# cron の巡回ログと、実行中のレビューの一歩一歩（テスト出力、レビュアーが読んだファイル・実行したコマンド・書いた文）を流す。
# レビュー自体は今までどおり cron（watch.sh → cross-review.sh）が動かす。セッションが切れても止まらないように。
# 描画は live.py。ここは config.sh を読んで渡すだけ。
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

wts=""
for entry in "${REPOS[@]}"; do
  IFS='|' read -r name _ _ wt <<<"$entry"
  wts+="$name|$wt"$'\n'
done

CR_WTS="$wts" CR_LOG="${CROSS_REVIEW_LOG:-$HOME/.cache/cross-review/watch.log}" exec python3 "$here/live.py"
