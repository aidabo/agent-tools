# cross-review の設定（bash から source される）。
# ここは どのマシン・プロジェクトでも同じ既定値だけ。対象リポジトリ（REPOS）・テスト・置き場所などの
# 固有の値は config.local.sh に書く（git に入れない。config.local.example.sh を写して使う）。
# CROSS_REVIEW_CONFIG で別のファイルを指定することもできる。

# このツールの置き場所（PROTOCOL.md・inbox の場所をエージェントに伝えるのに使う）
CROSS_REVIEW_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# レビュー結果の置き場（人が読む・作者エージェントに渡すファイル）
REPORT_DIR="$HOME/.cache/cross-review/reports"
# 同じ PR head × レビュアーを二度レビューしないための記録
STATE_DIR="$HOME/.cache/cross-review/state"
# 作者エージェントへの受け渡し箱（inbox/<agent>/ にレビューへのポインタを置く）
INBOX_DIR="$CROSS_REVIEW_HOME/inbox"

# 対象リポジトリ: 名前|GitHub repo|作者の作業ツリー（worktree の親・node_modules の借り元）|レビュー用 worktree
# レビュー用 worktree は作業ツリーと同じ階層に置く — 相対 symlink がそのまま解決するように。
REPOS=()

# テスト（AI ではなくスクリプトが走らせる）。1 行 1 コマンド、worktree のルートで実行。空ならテストしない。
# {HOST_FILES} = apps/host 配下の変更ファイル、{PKG_DIRS} = tsconfig.json を持つ変更トップディレクトリ
# （どちらもクォート済みで埋め込まれる）。
test_cmds_for() { :; }

# 作者 → レビュアー（互いにレビュー）。作者が分からないときは unknown。
reviewers_for() {
  case "$1" in
    claude)   echo "codex" ;;
    codex)    echo "claude" ;;
    deepseek) echo "codex claude" ;;
    *)        echo "claude codex" ;;
  esac
}

# レビューしてよい PR の作者（GitHub login、スペース区切り）。空なら各リポジトリの owner だけ。
# fork からの PR はここに関係なく扱わない（PR のコードを実行し、レビューは公開されるため）。
TRUSTED_AUTHORS=""

# レビュー結果を PR コメントにも出すか（1=出す）
POST_COMMENT=1
# レビュアー 1 人あたりの上限秒
REVIEW_TIMEOUT=1500
# テスト 1 コマンドあたりの上限秒
TEST_TIMEOUT=900
# DeepSeek（Claude Code + DeepSeek API）の起動スクリプト。export 行だけを読む。
DEEPSEEK_LAUNCHER="$HOME/claw/deepseek"
# cron から呼ばれたときに PATH の先頭へ足すディレクトリ（: 区切り）。空なら nvm の最新 node を探す。
EXTRA_PATH=""

_cross_review_local="${CROSS_REVIEW_CONFIG:-$CROSS_REVIEW_HOME/config.local.sh}"
# shellcheck source=/dev/null
[[ -f "$_cross_review_local" ]] && source "$_cross_review_local"
unset _cross_review_local
