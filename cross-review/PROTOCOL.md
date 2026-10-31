# Cross-review の決まり（claude / codex / deepseek 共通）

同じ tmux セッションで並んで作業する AI エージェントが、互いの PR を自動でレビューし合うための決まり。
人が毎回指示しなくても回ることが目的。仕組みは同じフォルダの README.md。

## 0. 自分の名前と役割

- 名前: 環境変数 `CROSS_REVIEW_AGENT`（無ければ Claude Code は `claude`、Codex は `codex`）。
  DeepSeek は Claude Code の上で動くが、起動スクリプトが `CROSS_REVIEW_AGENT=deepseek` を設定する。
- この決まりは clone した agent-tools の `cross-review/PROTOCOL.md`。pane では `start-agents.sh` が
  `CROSS_REVIEW_HOME`（= `<clone>/cross-review`）と `AGENT_TOOLS_HOME` を export する。
  下の `<clone>` はその値、手元ではこのファイルと同じフォルダ。
- `CROSS_REVIEW_ROLE=reviewer` のときは **レビュアーとして呼ばれている**。この決まりの 1〜3 は行わない
  （inbox を見ない、PR を作らない、ファイルを変更しない）。頼まれたレビューを返すだけ。

## 1. PR を作るとき

- `gh pr create` に必ず `--label author:<自分の名前>` を付ける。レビュアーの振り分けに使う
  （claude の PR → codex と deepseek、codex の PR → claude と deepseek、deepseek の PR → codex と claude）。
  自分の PR を自分がレビューすることは無い（作者と同じエージェントはレビュアーから必ず外れる）。label が無いと
  作者を推定できず、自分もレビュアーに入りうるので、label は必ず付ける。
- レビューは自動で始まる（cron が毎分、未レビューの PR を探す）。急ぐときだけ自分で
  `<clone>/cross-review.sh <repo> <PR番号>` を実行してよい。
  repo は `cross-review/config.local.sh` の `REPOS` にある名前（ボードに出ている名前）。
  テストを走らせるかは `config.local.sh` の `test_cmds_for` で決まる（無ければレビューだけ）。
- draft の PR と `no-cross-review` label の PR はレビューされない。

## 2. レビューを受け取る

- 「cross-review: … にレビューが N 件届きました」という 1 行が届いたら、または作業の開始時・
  タスクの区切りに、`<clone>/inbox/<自分の名前>/` を見る。
- 中の `*.txt` の 1 行目 = レビュー結果のファイル。読んで、
  - **正しい指摘** → その PR のブランチで直して push する（head が変わると自動で再レビューされる）。
  - **同意しない指摘** → 理由を PR コメントに書く（黙って無視しない）。
  - 判定が APPROVE で指摘が無ければ、直す必要はない（ただし提案があれば、下のとおりユーザーに報告する）。
  - **提案（`## 提案` の [補足]・[改善]・[魅力]）は直す義務がない。** 判定にも影響しない。作者は読んで、
    その PR の目的の中で小さく済むものだけ、全員の APPROVE より前なら取り入れてよい。それ以外は、
    **ユーザーへの報告に「レビュアーの提案」として短くまとめて渡す**（採るかどうかはユーザーが決める）。黙って捨てない。
  - 処理したら、その `*.txt` と `*.txt.notified` を消す。
- **ユーザーの現在の指示を優先する。** 別の作業中に届いたら、区切りで対応する。
- **秘密の値（`secrets✗`）の指摘は必ず直す。** 値をコードから消すだけでなく、その鍵・パスワードは漏れたものとして
  ユーザーに伝え、無効化と再発行を頼む（git の履歴と公開された PR に残るため）。
- **全員が APPROVE なら、もう push しない。** 低（[低]）の指摘は直さず、必要なら「後で対応」と PR コメントに書くだけ
  （push すると head が変わって全員の再レビューが始まり、終わらなくなる）。
- **再レビューは前回の続き。** レビュアーは前回の指摘が直ったかと、前回からの差分で壊れたところだけを見る。
- **回数の上限。** 1 つの PR の自動レビューは `MAX_ROUNDS`（既定 4 = 初回 + 再レビュー 3 回）まで。超えると
  `*-limit.txt` が届く。届いたらその PR への修正・push をやめ、ユーザーの判断を待つ（ポインタは消す）。
  ボードには NEEDS YOU と出る。
- マージはしない（マージはユーザーが画面で行う）。

## 3. してはいけないこと

- 他のエージェントの tmux pane に send-keys しない。連絡は inbox と PR コメントで行う
  （通知の 1 行は notify.sh が、相手が手すきのときだけ送る）。
- レビュー用 worktree（`REPOS` の 4 列目。作業ツリーの隣に作られる `*-review`）で作業しない。スクリプトが毎回上書きする。
- 他のエージェントのブランチ・作業ツリーを切り替えない。そこに commit しない。
- レビュー結果のファイル（`<ワークスペース>/.agent-tools/reviews/`）を書き換えない。
