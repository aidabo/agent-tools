#!/usr/bin/env bash
# cross-review — ローカルで「別のエージェント」に PR をレビューさせる（GitHub Actions を使わない）。
#
#   cross-review.sh <repo-name> <pr-number> [--reviewer claude|codex|deepseek]... [--author X]
#                   [--no-test] [--no-post] [--force]
#
# 流れ: PR head をレビュー用 worktree に detach で展開 → スクリプトがテストを走らせる →
#       作者以外のエージェントが読み取り専用でレビュー → 22-temp/reviews/cross/ に保存 →
#       PR コメント（POST_COMMENT=1）→ 作者の inbox にポインタ + tmux の status 行に通知。
# 他エージェントの pane に send-keys はしない（作業中の割り込みを避ける）。
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=config.sh
source "$here/config.sh"

die() { echo "[cross-review] $*" >&2; exit 1; }
log() { echo "[cross-review] $*" >&2; }

repo_name="${1:-}"; pr="${2:-}"
[[ -n "$repo_name" && "$pr" =~ ^[0-9]+$ ]] || die "usage: cross-review.sh <repo-name> <pr-number> [--reviewer X]... [--author X] [--no-test] [--no-post] [--force]"
shift 2
reviewers=(); author=""; do_test=1; post="$POST_COMMENT"; force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reviewer) reviewers+=("$2"); shift 2 ;;
    --author)   author="$2"; shift 2 ;;
    --no-test)  do_test=0; shift ;;
    --no-post)  post=0; shift ;;
    --force)    force=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

gh_repo=""; src=""; wt=""
for entry in "${REPOS[@]}"; do
  IFS='|' read -r n g s w <<<"$entry"
  if [[ "$n" == "$repo_name" ]]; then gh_repo="$g"; src="$s"; wt="$w"; fi
done
[[ -n "$gh_repo" ]] || die "unknown repo '$repo_name' (config.sh REPOS)"

mkdir -p "$REPORT_DIR" "$STATE_DIR" "$INBOX_DIR"
# worktree を 1 本だけ使うので、同じリポジトリのレビューは直列にする
exec 9>"$STATE_DIR/$repo_name.lock"
flock 9

# ── PR 情報 ────────────────────────────────────────────────
pr_json="$(gh pr view "$pr" -R "$gh_repo" --json number,title,state,headRefOid,baseRefName,headRefName,body,labels,commits)"
field() { python3 -c "import json,sys; print(json.load(sys.stdin)[sys.argv[1]])" "$1" <<<"$pr_json"; }
head_sha="$(field headRefOid)"
base_ref="$(field baseRefName)"
head_ref="$(field headRefName)"
title="$(field title)"
[[ "$(field state)" == "OPEN" || "$force" == 1 ]] || die "PR #$pr is not open (use --force)"
short="${head_sha:0:8}"

# ── 作者の推定（label author:X > --author > コミットの痕跡）──────────
if [[ -z "$author" ]]; then
  author="$(python3 - "$pr_json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
for l in d.get("labels", []):
    if l["name"].startswith("author:"):
        print(l["name"].split(":", 1)[1]); sys.exit()
msgs = "\n".join((c.get("messageHeadline", "") + "\n" + c.get("messageBody", "")) for c in d.get("commits", []))
if "deepseek" in msgs.lower():
    print("deepseek")
elif "Co-Authored-By: Claude" in msgs:
    print("claude")
elif any(k in msgs for k in ("Constraint:", "Confidence:", "Scope-risk:", "Codex")):
    print("codex")
else:
    print("unknown")
PY
)"
fi
[[ ${#reviewers[@]} -gt 0 ]] || read -r -a reviewers <<<"$(reviewers_for "$author")"
log "PR #$pr ($repo_name) head=$short author=$author reviewers=${reviewers[*]}"

pending=()
for r in "${reviewers[@]}"; do
  if [[ "$force" == 0 && -f "$STATE_DIR/$repo_name-$pr-$short-$r.done" ]]; then
    log "skip $r: already reviewed $short"
  else
    pending+=("$r")
  fi
done
[[ ${#pending[@]} -gt 0 ]] || { log "nothing to do"; exit 0; }

# ── レビュー用 worktree（detach、作者のツリーは動かさない）──────────
git -C "$src" fetch -q origin "$head_sha" "$base_ref" 2>/dev/null || git -C "$src" fetch -q origin
if [[ ! -e "$wt/.git" ]]; then
  log "creating review worktree $wt"
  git -C "$src" worktree add -q --detach "$wt" "$head_sha"
else
  git -C "$wt" reset -q --hard
  git -C "$wt" clean -qfd -e node_modules -e '.env*'
  git -C "$wt" checkout -q --detach "$head_sha"
fi
# gitignore された node_modules と apps/*/.env* を作者のツリーから借りる（symlink、読むだけ）
while IFS= read -r nm; do
  rel="${nm#"$src"/}"
  [[ -d "$wt/$(dirname "$rel")" && ! -e "$wt/$rel" ]] && ln -s "$nm" "$wt/$rel"
done < <(find "$src" -maxdepth 4 -name node_modules -type d -prune -not -path '*/node_modules/*/*' 2>/dev/null)
for envf in "$src"/apps/*/.env*; do
  [[ -f "$envf" ]] || continue
  rel="${envf#"$src"/}"; [[ -e "$wt/$rel" ]] || ln -s "$envf" "$wt/$rel"
done

# 差分の起点は「PR の最初のコミットの親」。merge-base だとマージ済み PR（--force）で空になる。
first_commit="$(python3 -c "import json,sys; c=json.load(sys.stdin)['commits']; print(c[0]['oid'] if c else '')" <<<"$pr_json")"
if [[ -n "$first_commit" ]] && git -C "$wt" cat-file -e "$first_commit^" 2>/dev/null; then
  merge_base="$(git -C "$wt" rev-parse "$first_commit^")"
else
  merge_base="$(git -C "$wt" merge-base "origin/$base_ref" "$head_sha")"
fi
work="$wt/.cross-review"; mkdir -p "$work"
git -C "$wt" diff "$merge_base" "$head_sha" > "$work/diff.patch"
mapfile -t changed < <(git -C "$wt" diff --name-only "$merge_base" "$head_sha")
log "changed files: ${#changed[@]}"

# ── テスト（スクリプトが実行。AI には結果だけ渡す）────────────────
test_summary="(テストは実行していない)"
if [[ "$do_test" == 1 ]]; then
  host_files=(); pkg_dirs=()
  for f in "${changed[@]}"; do
    [[ -f "$wt/$f" ]] || continue
    [[ "$f" == apps/host/* ]] && host_files+=("${f#apps/host/}")
    top="${f%%/*}"; [[ -f "$wt/$top/tsconfig.json" ]] && pkg_dirs+=("$top")
  done
  mapfile -t pkg_dirs < <(printf '%s\n' "${pkg_dirs[@]}" | sort -u | sed '/^$/d')
  test_summary=""
  : > "$work/tests.log"
  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    if [[ "$cmd" == *"{HOST_FILES}"* ]]; then
      [[ ${#host_files[@]} -gt 0 ]] || { test_summary+="- skip: ${cmd%% \{*} (apps/host の変更なし)"$'\n'; continue; }
      cmd="${cmd//\{HOST_FILES\}/$(printf '%q ' "${host_files[@]}")}"
    fi
    if [[ "$cmd" == *"{PKG_DIRS}"* ]]; then
      [[ ${#pkg_dirs[@]} -gt 0 ]] || { test_summary+="- skip: tsc (パッケージの変更なし)"$'\n'; continue; }
      cmd="${cmd//\{PKG_DIRS\}/$(printf '%q ' "${pkg_dirs[@]}")}"
    fi
    log "test: $cmd"
    echo "\$ $cmd" >> "$work/tests.log"
    set +e
    (cd "$wt" && timeout "$TEST_TIMEOUT" bash -c "$cmd") >> "$work/tests.log" 2>&1
    rc=$?
    set -e
    test_summary+="- exit=$rc: $cmd"$'\n'
  done < <(test_cmds_for "$repo_name")
  [[ -n "$test_summary" ]] || test_summary="(このリポジトリにテスト設定なし)"
  cp "$work/tests.log" "$REPORT_DIR/$repo_name-pr$pr-$short-tests.log"
fi

# ── プロンプト ───────────────────────────────────────────────
prompt_file="$work/prompt.md"
cat > "$prompt_file" <<EOF
あなたは別のエージェント（作者: $author）が作った PR のレビュアーです。日本語で、簡潔に答えてください。

- リポジトリ: $gh_repo  PR #$pr「$title」（$head_ref → $base_ref、head $short）
- カレントディレクトリは PR head を展開したレビュー専用 worktree です。**ファイルを変更しないでください**（読み取りのみ）。
- 差分: \`.cross-review/diff.patch\`（merge-base..head）。変更ファイル ${#changed[@]} 件。必要に応じて周辺コードも読んでください。
- リポジトリの規約は CLAUDE.md / AGENTS.md / docs/architecture/decisions.md を優先してください（あれば）。
- テスト結果（スクリプトが実行済み。ログ: \`.cross-review/tests.log\`）:
$test_summary
観点: 正しさ・既存挙動の回帰・セキュリティ（秘密の値の混入、認証境界）・テスト不足・規約違反。
推測ではなく、コードで確かめた指摘だけを書いてください。好みの問題は書かないでください。

出力形式（Markdown、これ以外は書かない）:
## 判定
APPROVE / CHANGES_REQUESTED / COMMENT のどれか 1 語と、理由 1 行
## 指摘
- [高|中|低] \`path:line\` — 何が問題か／どう壊れるか／直し方（無ければ「なし」）
## テスト
テスト結果の解釈と、足りないテスト（あれば）
EOF

# ── レビュアー実行 ─────────────────────────────────────────
run_reviewer() {
  local who="$1" out="$2"
  # レビュアーであることを示す。PROTOCOL.md はこのとき inbox を見ない・PR を作らないと定める。
  export CROSS_REVIEW_ROLE=reviewer
  local prompt; prompt="$(cat "$prompt_file")"
  case "$who" in
    claude)
      # サブスクのログインで動かす。API キーや親の Claude Code セッションの環境は渡さない
      # （ANTHROPIC_API_KEY があるとそちらが優先され、無効なら "Invalid API key" で落ちる）。
      (cd "$wt" && unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDECODE \
        CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID && timeout "$REVIEW_TIMEOUT" claude -p "$prompt" \
        --allowedTools "Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*)" \
        --disallowedTools "Edit,Write,NotebookEdit" > "$out")
      ;;
    deepseek)
      # 起動スクリプト（ユーザー自身のファイル）の export/unset 行だけを eval する。
      # 鍵を別ファイルに複製しないため。外部入力は通らない。
      (cd "$wt" && unset ANTHROPIC_API_KEY CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID && set -a && eval "$(grep -E '^(export|unset) ' "$DEEPSEEK_LAUNCHER")" && set +a && \
        timeout "$REVIEW_TIMEOUT" claude -p "$prompt" \
        --allowedTools "Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*)" \
        --disallowedTools "Edit,Write,NotebookEdit" > "$out")
      ;;
    codex)
      timeout "$REVIEW_TIMEOUT" codex exec -C "$wt" --sandbox read-only --skip-git-repo-check \
        -o "$out" "$prompt" > "$work/codex.stdout" 2>&1
      ;;
    *) echo "unknown reviewer: $who" > "$out"; return 1 ;;
  esac
}

pids=(); outs=()
for r in "${pending[@]}"; do
  out="$REPORT_DIR/$repo_name-pr$pr-$short-$r.md"
  log "reviewing with $r → $out"
  run_reviewer "$r" "$out.tmp" & pids+=("$!"); outs+=("$r|$out")
done

for i in "${!pids[@]}"; do
  IFS='|' read -r r out <<<"${outs[$i]}"
  if wait "${pids[$i]}" && [[ -s "$out.tmp" ]]; then
    { echo "# cross-review: $repo_name PR #$pr by $r"
      echo
      echo "- head: \`$head_sha\` / author: $author / reviewed: $(date '+%Y-%m-%d %H:%M %Z')"
      echo "- tests: $(echo "$test_summary" | tr '\n' ' ')"
      echo
      cat "$out.tmp"; } > "$out"
    rm -f "$out.tmp"
    touch "$STATE_DIR/$repo_name-$pr-$short-$r.done"
    log "done: $r"
    if [[ "$post" == 1 ]]; then
      gh pr comment "$pr" -R "$gh_repo" --body-file "$out" >/dev/null && log "posted comment ($r)"
    fi
    if [[ "$author" != unknown ]]; then
      mkdir -p "$INBOX_DIR/$author"
      echo "$out" > "$INBOX_DIR/$author/$repo_name-pr$pr-$short-$r.txt"
    fi
    echo "$out"
  else
    log "FAILED: $r (partial output kept at $out.tmp)"
  fi
done

# 作者が手すきなら 1 行で知らせる（作業中なら次の watch 巡回で）
"$here/notify.sh" || true
