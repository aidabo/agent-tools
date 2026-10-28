#!/usr/bin/env bash
# watch.sh — 開いている PR を 1 巡して、未レビューの head だけ cross-review.sh に渡す。
# 常駐はしない。cron / systemd timer から数分おきに呼ぶ（README 参照）。
set -uo pipefail
# cron は PATH が最小なので、gh / claude / codex(nvm) / node を明示する
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.19.0/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"
mkdir -p "$STATE_DIR"
exec 8>"$STATE_DIR/watch.lock"
flock -n 8 || { echo "[watch] another pass is running"; exit 0; }

for entry in "${REPOS[@]}"; do
  IFS='|' read -r name gh_repo _ _ <<<"$entry"
  gh pr list -R "$gh_repo" --state open --json number,isDraft,labels \
    -q '.[] | select(.isDraft|not) | select([.labels[].name] | index("no-cross-review") | not) | .number' 2>/dev/null |
  while read -r pr; do
    "$here/cross-review.sh" "$name" "$pr" || echo "[watch] $name #$pr failed" >&2
  done
done

# 未通知のレビューを、手すきのエージェントに届ける（前の巡回で作業中だった分も）
"$here/notify.sh" || true
