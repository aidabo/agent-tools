# agent-tools

tmux で複数の AI エージェント（claude / codex / deepseek）を並べて使うための道具。

- `agent-notify/` — エージェントの pane を立ち上げる（`start-agents.sh`、`yarn agents`）、状態ボード（`monitor.sh`）、Discord への停止通知
- `cross-review/` — エージェント同士で PR をレビューさせる（`cross-review.sh`、`watch.sh`、`status.sh`）

ワークスペース（`~/work/legacy` のように backend・frontend など複数のリポジトリをまとめたフォルダ）単位で使う。

- エージェントの pane: ワークスペースの直下に `agents.yaml` を置くと、その中のどのリポジトリから `yarn agents` しても
  そのワークスペースで起動する。セッション名もワークスペースごと（`agent-notify/README.md`）
- cross-review: 全ワークスペースのリポジトリを `cross-review/config.local.sh` 1 か所に並べる（`cross-review/README.md`）
- 状態ボード（`agent-notify/monitor.sh`）は 1 つで、全ワークスペースのレビューとエージェントをまとめて見る

## 別のマシンで使う

1. このリポジトリを clone する（場所はどこでもよい）。
2. `cross-review/install.sh` を実行する。cron の巡回を入れ、`cross-review/config.local.sh` のひな形を作り、
   足りないもの（ログイン・コマンド・cron の起動）を表示する。表示に従って直し、`--check` で確かめる。
3. 各ワークスペースの直下に `agents.yaml` を置く（`agent-notify/agents.yaml` を写して pane を書く）。
4. リポジトリの package.json に yarn のコマンドを足す（例）:

   ```json
   "agents": "bash \"${AGENT_TOOLS_HOME:-$HOME/work/legacy/10-agent-tools}/agent-notify/start-agents.sh\"",
   "monitor": "bash \"${AGENT_TOOLS_HOME:-$HOME/work/legacy/10-agent-tools}/agent-notify/monitor.sh\"",
   "cross-review:install": "bash \"${AGENT_TOOLS_HOME:-$HOME/work/legacy/10-agent-tools}/cross-review/install.sh\""
   ```

   agent-tools を別の場所に clone したマシンでは、シェルの設定（`~/.bashrc` など）に
   `export AGENT_TOOLS_HOME=/path/to/agent-tools` を書く。スクリプト自身は自分の場所を見るので、パスの設定は要らない。
