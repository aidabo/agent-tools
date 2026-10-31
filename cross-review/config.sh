# cross-review の設定（bash から source される）。
# ここは どのマシン・プロジェクトでも同じ既定値だけ。対象リポジトリ（REPOS）・テスト・置き場所などの
# 固有の値は config.local.sh に書く（git に入れない。config.local.example.sh を写して使う）。
# CROSS_REVIEW_CONFIG で別のファイルを指定することもできる。

# このツールの置き場所（PROTOCOL.md・inbox の場所をエージェントに伝えるのに使う）
CROSS_REVIEW_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# レビュー結果の置き場（人が読む・作者エージェントに渡すファイル）。空なら report_dir_for がリポジトリごとに決める。
REPORT_DIR=""
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

# 作者 → レビュアー（作者以外の全員。並列に動く）。作者が分からないときは unknown — 3 人とも入るが、
# cross-review.sh は作者と同じエージェントを必ず外す。deepseek は DeepSeek API の従量課金。
reviewers_for() {
  case "$1" in
    claude)   echo "codex deepseek" ;;
    codex)    echo "claude deepseek" ;;
    deepseek) echo "codex claude" ;;
    *)        echo "claude codex deepseek" ;;
  esac
}

# レビューしてよい PR の作者（GitHub login、スペース区切り）。空なら各リポジトリの owner だけ。
# fork からの PR はここに関係なく扱わない（PR のコードを実行し、レビューは公開されるため）。
TRUSTED_AUTHORS=""

# 1 つの PR を自動でレビューする回数の上限（初回 + 再レビュー）。超えたら止めて、ユーザーの判断を待つ
# （ボードは NEEDS YOU、作者には止めるよう通知）。続けるときは cross-review.sh <repo> <PR> --force。
MAX_ROUNDS=4
# deepseek でレビューするときの思考量（起動スクリプトの CLAUDE_CODE_EFFORT_LEVEL を上書き。pane の deepseek は変えない）
DEEPSEEK_REVIEW_EFFORT="high"

# 作者の pane に「レビューが届きました」を送るか（1=送る）。テストでは 0 にする（本物の pane に送らないように）
NOTIFY=1

# レビュー結果を PR コメントにも出すか（1=出す）
POST_COMMENT=1
# レビューとテストの優先度（nice。大きいほど低い）。pane で動いているエージェントの作業を先にする
REVIEW_NICE=10
# レビュアー 1 人あたりの上限秒
REVIEW_TIMEOUT=1500
# テスト 1 コマンドあたりの上限秒
TEST_TIMEOUT=900
# DeepSeek（Claude Code + DeepSeek API）の起動スクリプト。export 行だけを読む。
# 固定パスは持たない: DEEPSEEK_LAUNCHER が未指定なら PATH から解決する（下で）。
DEEPSEEK_LAUNCHER="${DEEPSEEK_LAUNCHER:-}"
# cron から呼ばれたときに PATH の先頭へ足すディレクトリ（: 区切り）。空なら nvm の最新 node を探す。
EXTRA_PATH=""

# レビュー結果の置き場: REPORT_DIR があればそれ。無ければリポジトリのワークスペース（作業ツリーから上へたどって
# agents.yaml がある所、例 ~/work/legacy）の .agent-tools/reviews/。どれでもなければ ~/.cache/cross-review/reports。
report_dir_for() {  # <作者の作業ツリー>
  if [[ -n "$REPORT_DIR" ]]; then echo "$REPORT_DIR"; return; fi
  local d="$1"
  while [[ -n "$d" && "$d" != "/" && "$d" != "." ]]; do
    if [[ -f "$d/agents.yaml" ]]; then echo "$d/.agent-tools/reviews"; return; fi
    d="$(dirname "$d")"
  done
  echo "$HOME/.cache/cross-review/reports"
}

_cross_review_local="${CROSS_REVIEW_CONFIG:-$CROSS_REVIEW_HOME/config.local.sh}"
# shellcheck source=/dev/null
[[ -f "$_cross_review_local" ]] && source "$_cross_review_local"
unset _cross_review_local

# deepseek の起動スクリプトを PATH から解決する（EXTRA_PATH も見る）。
# cron は PATH が最小なので、置き場所は config.local.sh の EXTRA_PATH に足すか、
# DEEPSEEK_LAUNCHER で絶対パスを指定する。見つからなければ空のまま。
if [[ -z "$DEEPSEEK_LAUNCHER" ]]; then
  DEEPSEEK_LAUNCHER="$(PATH="${EXTRA_PATH:+$EXTRA_PATH:}$PATH" command -v deepseek 2>/dev/null || true)"
fi
