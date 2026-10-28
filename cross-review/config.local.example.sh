# cross-review のマシン・プロジェクト固有の設定。config.local.sh に写して書き換える
# （config.sh の後に source される。config.local.sh は git に入れない）。

# レビュー結果の置き場。既定はリポジトリのワークスペース（agents.yaml がある上位フォルダ）の .agent-tools/reviews/。
# 1 か所に固定したいときだけ書く。
# REPORT_DIR="$HOME/work/reviews/cross"

# 対象リポジトリ: 名前|GitHub repo|作者の作業ツリー|レビュー用 worktree（作業ツリーの隣に作られる）
# ワークスペース（~/work/legacy のように複数リポジトリをまとめたフォルダ）が複数あっても、ここ 1 か所に並べる。
REPOS=(
  "my-backend|me/my-backend|$HOME/work/myws/backend|$HOME/work/myws/backend-review"
  "my-frontend|me/my-frontend|$HOME/work/myws/frontend|$HOME/work/myws/frontend-review"
)

# スクリプトが走らせるテスト（1 行 1 コマンド、worktree のルートで実行）
test_cmds_for() {
  case "$1" in
    my-backend)
      echo "npm run typecheck"
      ;;
    my-frontend)
      echo "npm run typecheck"
      ;;
  esac
}

# cron で node / gh が見つからないとき
# EXTRA_PATH="$HOME/.nvm/versions/node/v20.19.0/bin"
