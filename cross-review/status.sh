#!/usr/bin/env bash
# status.sh — cross-review の状態を一覧する。読むだけで、レビューは走らせない。
#
#   status.sh [--no-color]
#
# PR ごと: レビュー待ち（次の巡回で拾う）/ レビュー中 / レビュー済み（誰が）/ 対象外（draft・no-cross-review）
# inbox:   作者に届いたレビューのうち、まだ残っているもの（未通知 = 作者が作業中、通知済み = 作者の対応待ち）
# 巡回:    cron の登録と最終巡回の時刻
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

if [[ "${1:-}" == "--no-color" || -n "${NO_COLOR:-}" || ! -t 1 && -z "${FORCE_COLOR:-}" ]]; then
  B=""; D=""; R=""; Y=""; G=""; C=""; Z=""
else
  B=$'\e[1m'; D=$'\e[2m'; R=$'\e[31m'; Y=$'\e[33m'; G=$'\e[32m'; C=$'\e[36m'; Z=$'\e[0m'
fi

ago() {  # epoch → 「7分前」
  local s=$(( $(date +%s) - $1 ))
  if (( s < 60 )); then echo "${s}秒前"; elif (( s < 3600 )); then echo "$((s / 60))分前"
  elif (( s < 86400 )); then echo "$((s / 3600))時間前"; else echo "$((s / 86400))日前"; fi
}

# レポート（cross-review.sh が書く .md）の要約: 「判定  指摘 高1 低2  テスト失敗」
summary_of() {
  local v
  v="$(awk '
    /^## / { sec = $0; next }
    sec == "## 判定" && v == "" && NF { v = match($0, /[A-Z_]+/) ? substr($0, RSTART, RLENGTH) : $1 }
    sec == "## 指摘" && /^- \[高\]/ { h++ }
    sec == "## 指摘" && /^- \[中\]/ { m++ }
    sec == "## 指摘" && /^- \[低\]/ { l++ }
    /^- tests:/ && /exit=[1-9]/ { tf = 1 }
    END { printf "%s %d %d %d %d", (v == "" ? "?" : v), h, m, l, tf }' "$1")"
  read -r verdict h m l tf <<<"$v"
  case "$verdict" in
    APPROVE)           printf '%s' "${G}APPROVE${Z}" ;;
    CHANGES_REQUESTED) printf '%s' "${R}CHANGES_REQUESTED${Z}" ;;
    *)                 printf '%s' "${Y}$verdict${Z}" ;;
  esac
  local findings=""
  (( h > 0 )) && findings+=" ${R}高$h${Z}"
  (( m > 0 )) && findings+=" ${Y}中$m${Z}"
  (( l > 0 )) && findings+=" 低$l"
  [[ -n "$findings" ]] && printf '  指摘%s' "$findings"
  (( tf )) && printf '  %s' "${R}テスト失敗${Z}"
  return 0
}

# 実行中のレビュー（"repo pr" の行）
# スクリプト自身がプログラムか、bash の第 1 引数のときだけ（コマンド行に名前が出てくるだけの別プロセスは除く）
running="$(ps -eo args= | awk '$1 ~ /cross-review\.sh$/ && $3 ~ /^[0-9]+$/ { print $2, $3; next }
  $1 ~ /(^|\/)bash$/ && $2 ~ /cross-review\.sh$/ && $4 ~ /^[0-9]+$/ { print $3, $4 }')"

echo "${B}cross-review${Z}"
if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "  ${Y}対象リポジトリがありません（config.local.sh の REPOS）${Z}"
fi

for entry in "${REPOS[@]}"; do
  IFS='|' read -r name gh_repo _ _ <<<"$entry"
  echo "  ${B}$name${Z} ${D}($gh_repo)${Z}"
  trusted=" ${TRUSTED_AUTHORS:-${gh_repo%%/*}} "
  if ! prs="$(gh pr list -R "$gh_repo" --state open --json number,title,headRefOid,isDraft,labels,isCrossRepository,author \
      -q '.[] | [.number, .headRefOid[0:8],
                 (if .isDraft then "draft" elif ([.labels[].name] | index("no-cross-review")) then "no-cross-review"
                  elif .isCrossRepository then "fork" else "-" end),
                 (.author.login // "-"), .title] | @tsv' 2>&1)"; then
    echo "    ${R}PR を取得できません: ${prs%%$'\n'*}${Z}"
    continue
  fi
  if [[ -z "$prs" ]]; then
    echo "    ${D}開いている PR なし${Z}"
    continue
  fi
  # skip は空にしない（"-"）: タブは IFS の空白扱いで、空の列は詰められてしまう
  while IFS=$'\t' read -r num sha skip author title; do
    [[ "$skip" == "-" && "$trusted" != *" $author "* ]] && skip="信頼外の作者 $author"
    (( ${#title} > 40 )) && title="${title:0:39}…"
    done_by=()
    for f in "$STATE_DIR/$name-$num-$sha-"*.done; do
      [[ -e "$f" ]] && done_by+=("$(basename "${f#"$STATE_DIR/$name-$num-$sha-"}" .done)")
    done
    if grep -qx "$name $num" <<<"$running"; then
      state="${C}レビュー中${Z}"
    elif [[ "$skip" != "-" ]]; then
      state="${D}対象外 ($skip)${Z}"
    elif [[ ${#done_by[@]} -gt 0 ]]; then
      state="${G}レビュー済み${Z}"
      for r in "${done_by[@]}"; do
        report="$REPORT_DIR/$name-pr$num-$sha-$r.md"
        if [[ -f "$report" ]]; then state+="  $r: $(summary_of "$report")"; else state+="  $r"; fi
      done
    else
      state="${Y}レビュー待ち${Z}"
    fi
    printf '    #%-5s %s  %s  %s\n' "$num" "$sha" "$state" "${D}$title${Z}"
  done <<<"$prs"
done

# ── 最近のレビュー結果（新しい順に RECENT 件）────────────────────
RECENT="${CROSS_REVIEW_STATUS_RECENT:-5}"
echo "  ${B}最近のレビュー結果${Z} ${D}(${REPORT_DIR/#$HOME/~})${Z}"
mapfile -t reports < <(ls -t "$REPORT_DIR"/*.md 2>/dev/null | head -n "$RECENT")
if [[ ${#reports[@]} -eq 0 ]]; then
  echo "    ${D}まだありません${Z}"
fi
for f in "${reports[@]}"; do
  [[ "$(basename "$f")" =~ ^(.+)-pr([0-9]+)-([0-9a-f]{8})-([a-z]+)\.md$ ]] || continue
  t="$(stat -c %Y "$f")"
  printf '    %s %s #%s %s  %-8s → %s\n' "${D}$(date -d "@$t" '+%m/%d %H:%M')${Z}" \
    "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "$(summary_of "$f")"
done

# ── inbox（作者に届いて残っているレビュー）────────────────────
declare -A reviewers=() notified=()
keys=()
for f in "$INBOX_DIR"/*/*.txt; do
  [[ -e "$f" ]] || continue
  agent="$(basename "$(dirname "$f")")"
  [[ "$(basename "$f")" =~ ^(.+)-pr([0-9]+)-([0-9a-f]{8})-([a-z]+)\.txt$ ]] || continue
  key="$agent|${BASH_REMATCH[1]}|${BASH_REMATCH[2]}|${BASH_REMATCH[3]}"
  [[ -v "reviewers[$key]" ]] || { keys+=("$key"); notified[$key]=1; }
  reviewers[$key]+="${reviewers[$key]:+, }${BASH_REMATCH[4]}"
  [[ -e "$f.notified" ]] || notified[$key]=0
done
echo "  ${B}inbox${Z} ${D}(作者に届いて残っているレビュー)${Z}"
if [[ ${#keys[@]} -eq 0 ]]; then
  echo "    ${D}なし${Z}"
fi
for key in "${keys[@]}"; do
  IFS='|' read -r agent repo num sha <<<"$key"
  if [[ "${notified[$key]}" == 1 ]]; then
    state="${Y}通知済み・対応待ち${Z}"
  else
    state="${C}未通知（作者が作業中）${Z}"
  fi
  printf '    %-8s %s #%s %s ← %s  %s\n' "$agent" "$repo" "$num" "$sha" "${reviewers[$key]}" "$state"
done

# ── 巡回（cron の watch.sh）────────────────────────────────
if crontab -l 2>/dev/null | grep -v '^\s*#' | grep -q "cross-review/watch.sh"; then
  if [[ -e "$STATE_DIR/watch.lock" ]]; then
    t="$(stat -c %Y "$STATE_DIR/watch.lock")"
    echo "  ${D}巡回: cron 登録あり / 最終 $(date -d "@$t" +%H:%M)（$(ago "$t")）${Z}"
  else
    echo "  ${D}巡回: cron 登録あり / まだ動いていない${Z}"
  fi
else
  echo "  ${R}巡回: cron に watch.sh が登録されていません（README の「定期実行」）${Z}"
fi
