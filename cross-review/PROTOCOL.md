# Cross-review の決まり（claude / codex / deepseek 共通）

同じ tmux セッションで並んで作業する AI エージェントが、互いの PR を自動でレビューし合うための決まり。
人が毎回指示しなくても回ることが目的。仕組みは同じフォルダの README.md。

## 0. 自分の名前と役割

- 名前: 環境変数 `CROSS_REVIEW_AGENT`（無ければ Claude Code は `claude`、Codex は `codex`）。
  DeepSeek は Claude Code の上で動くが、起動スクリプトが `CROSS_REVIEW_AGENT=deepseek` を設定する。
- `CROSS_REVIEW_ROLE=reviewer` のときは **レビュアーとして呼ばれている**。この決まりの 1〜3 は行わない
  （inbox を見ない、PR を作らない、ファイルを変更しない）。頼まれたレビューを返すだけ。

## 1. PR を作るとき

- `gh pr create` に必ず `--label author:<自分の名前>` を付ける。レビュアーの振り分けに使う
  （claude の PR → codex、codex の PR → claude、deepseek の PR → codex と claude）。
- レビューは自動で始まる（cron が 10 分おきに未レビューの PR を探す）。急ぐときだけ自分で
  `~/work/legacy/10-agent-tools/cross-review/cross-review.sh <repo> <PR番号>` を実行してよい。
  repo は `jibunsee-react` / `business-libs`。
- draft の PR と `no-cross-review` label の PR はレビューされない。

## 2. レビューを受け取る

- 「cross-review: … にレビューが N 件届きました」という 1 行が届いたら、または作業の開始時・
  タスクの区切りに、`~/work/legacy/10-agent-tools/cross-review/inbox/<自分の名前>/` を見る。
- 中の `*.txt` の 1 行目 = レビュー結果のファイル。読んで、
  - **正しい指摘** → その PR のブランチで直して push する（head が変わると自動で再レビューされる）。
  - **同意しない指摘** → 理由を PR コメントに書く（黙って無視しない）。
  - 判定が APPROVE で指摘が無ければ、何もしなくてよい。
  - 処理したら、その `*.txt` と `*.txt.notified` を消す。
- **ユーザーの現在の指示を優先する。** 別の作業中に届いたら、区切りで対応する。
- 同じ PR で 3 回再レビューしても CHANGES_REQUESTED のままなら、直すのをやめてユーザーに判断を求める。
- マージはしない（マージはユーザーが画面で行う）。

## 3. してはいけないこと

- 他のエージェントの tmux pane に send-keys しない。連絡は inbox と PR コメントで行う
  （通知の 1 行は notify.sh が、相手が手すきのときだけ送る）。
- レビュー用 worktree（`01-ghost-front-review`、`11-business-review`）で作業しない。スクリプトが毎回上書きする。
- 他のエージェントのブランチ・作業ツリーを切り替えない。そこに commit しない。
- レビュー結果のファイル（`22-temp/reviews/cross/`）を書き換えない。
