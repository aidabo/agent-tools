# agent-tools

tmux で複数の AI エージェント（claude / codex / deepseek）を並べて使うための道具。

- `agent-notify/` — エージェントの pane を立ち上げる（`start-agents.sh`、`yarn agents`）、状態ボード（`monitor.sh`）、Discord への停止通知
- `cross-review/` — エージェント同士で PR をレビューさせる（`cross-review.sh`、`watch.sh`、`status.sh`）

ワークスペース（`~/work/legacy` のように backend・frontend など複数のリポジトリをまとめたフォルダ）単位で使う。

- エージェントの pane: ワークスペースの直下に `agents.yaml` を置くと、その中のどのリポジトリから `yarn agents` しても
  そのワークスペースで起動する。セッション名もワークスペースごと（`agent-notify/README.md`）
- cross-review: 全ワークスペースのリポジトリを `cross-review/config.local.sh` 1 か所に並べる（`cross-review/README.md`）
- 状態ボード（`agent-notify/monitor.sh`）は 1 つで、全ワークスペースのレビューとエージェントをまとめて見る
