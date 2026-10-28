# cross-review の設定（bash から source される）。

# レビュー結果の置き場（人が読む・作者エージェントに渡すファイル）
REPORT_DIR="$HOME/work/legacy/22-temp/reviews/cross"
# 同じ PR head × レビュアーを二度レビューしないための記録
STATE_DIR="$HOME/.cache/cross-review/state"
# 作者エージェントへの受け渡し箱（inbox/<agent>/ にレビューへのポインタを置く）
INBOX_DIR="$HOME/work/legacy/10-agent-tools/cross-review/inbox"

# 対象リポジトリ: 名前|GitHub repo|作者の作業ツリー（worktree の親・node_modules の借り元）|レビュー用 worktree
# レビュー用 worktree は作業ツリーと同じ階層に置く — packages/business などの
# 相対 symlink（../../11-business）がそのまま解決するように。
REPOS=(
  "jibunsee-react|aidabo/jibunsee-react|$HOME/work/legacy/01-ghost-front-ui|$HOME/work/legacy/01-ghost-front-review"
  "business-libs|aidabo/business-libs|$HOME/work/legacy/11-business|$HOME/work/legacy/11-business-review"
)

# テスト（AI ではなくスクリプトが走らせる）。{FILES} は変更ファイル（スペース区切り）。
# 空ならテストしない。1 行 1 コマンド、worktree のルートで実行。
test_cmds_for() {
  case "$1" in
    jibunsee-react)
      echo "yarn --cwd apps/host typecheck"
      echo "yarn --cwd apps/host vitest related --run --passWithNoTests {HOST_FILES}"
      ;;
    business-libs)
      echo "for d in {PKG_DIRS}; do (cd \"\$d\" && npx tsc --noEmit -p .) || exit 1; done"
      ;;
  esac
}

# 作者 → レビュアー（互いにレビュー）。作者が分からないときは unknown。
reviewers_for() {
  case "$1" in
    claude)   echo "codex" ;;
    codex)    echo "claude" ;;
    deepseek) echo "codex claude" ;;
    *)        echo "claude codex" ;;
  esac
}

# レビュー結果を PR コメントにも出すか（1=出す）
POST_COMMENT=1
# レビュアー 1 人あたりの上限秒
REVIEW_TIMEOUT=1500
# テスト 1 コマンドあたりの上限秒
TEST_TIMEOUT=900
# DeepSeek（Claude Code + DeepSeek API）の起動スクリプト。export 行だけを読む。
DEEPSEEK_LAUNCHER="$HOME/claw/deepseek"
