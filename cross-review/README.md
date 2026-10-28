# cross-review — エージェント同士のローカル PR レビュー

GitHub Actions を使わず、この PC 上で「作者とは別のエージェント」に PR をレビューさせる。
GitHub の課金は発生しない（gh API は無料）。レビューは各エージェントのサブスク／API の枠を使う
（claude = Claude サブスク、codex = ChatGPT/Codex プラン、deepseek = DeepSeek API の従量）。

## 使い方

```bash
# 1 本だけ（作者を推定して相手方がレビュー）
./cross-review.sh jibunsee-react 384
# レビュアーを指定 / テストなし / コメントを出さない / 同じ head でもやり直す
./cross-review.sh business-libs 12 --reviewer claude --reviewer deepseek --no-test --no-post --force

# 開いている PR を 1 巡（未レビューの head だけ）
./watch.sh
```

## 状態を見る

監視セッション（`agent-notify/monitor.sh`）の上の pane が PR 一覧（`status.sh`）、下の pane がレビューの実況（`live.sh`）:
巡回の流れ（どの PR・テスト・レビュー開始・完了・コメント・通知）と、実行中のレビューの一歩一歩
（`▸` ツール実行、`✎` 書いた文、`⚠` 断られた操作、`✓` 完了）。レビュー自体は cron が動かすので、pane を閉じても止まらない。

```bash
./status.sh                       # GitHub の PR 一覧のように 1 PR 1 行、新しい順
./status.sh jibunsee-react 393    # その PR のレビューの全回（時刻・head・各レビュアーの判定）と、最後のレポートの場所
```

止めた（NEEDS YOU）・スキップした PR は、最新の head にレビューが無くても、最後のレビュー結果
（`last <sha>: claude ✗ 中1 …`）と「全員 APPROVE だった最後の head」を一覧に出す。マージするかを決めるときは
`status.sh <repo> <PR>` で全回を見る。

```
 Open
  ● CHANGES REQUESTED business-libs  #16  Harden estate ViewModel …   3m ago  codex → claude ✗ 高1 中1  → codex fixing
  ● APPROVED          jibunsee-react #390 Connect editor …            8m ago  claude → codex ✓ 低1  → merge on GitHub
 Done (last 24h)
  ✓ MERGED            business-libs  #15  Expose hazard metadata …   20m ago  codex → claude ✓ 低3
```

状態: WAITING（次の巡回でレビュー）→ IN REVIEW → CHANGES REQUESTED（作者が直して push すると WAITING に戻る）/
NEEDS YOU（回数の上限で止めた。マージするかはあなたが決める）/
REVIEWED（コメントだけ）/ APPROVED（GitHub でマージしてよい）。SKIPPED は draft・`no-cross-review`・fork・信頼外の作者。
テストが失敗した PR は CHANGES REQUESTED。下の Done は最近マージ・クローズした PR（`CROSS_REVIEW_DONE_DAYS`、既定 1 日）。
各行の `作者 → レビュアー ✓/✗/~ 指摘数` の作者は `author:` label か、レポートの author 行。
IN REVIEW の行には、いま何をしているかが出る: `running tests 0:42`、または
`claude Read index.ts · 12 steps · active · 2:15`（最後の操作・ツール実行数・45 秒以内に動きがあれば active、無ければ quiet と経過）。
元は cross-review.sh がレビュー用 worktree の `.cross-review/` に書く `phase` と `<reviewer>.events.jsonl`
（claude は `--output-format stream-json`、codex は `--json`）。
読むだけで、レビューは走らせない。`agent-notify/monitor.sh` の監視セッションにも同じ内容が出る。

## 設定（別のプロジェクトで使う）

`config.sh` は既定値だけ。対象リポジトリ（`REPOS`）・テストコマンド・レビュー結果の置き場は `config.local.sh` に書く。
ワークスペース（`~/work/legacy` のように複数リポジトリをまとめたフォルダ）がいくつあっても、設定はこの 1 つに並べる
（`REPOS` はフルパスなので、どのワークスペースのリポジトリでも書ける）。cron の巡回・状態ボードも全部まとめて見る
（git に入れない）。初めてなら `cp config.local.example.sh config.local.sh` して書き換える。
`CROSS_REVIEW_CONFIG=/path/to/file` で別の設定ファイルも使える。

## 何をするか

1. `gh pr view` で head SHA を取り、**レビュー用 worktree**（`01-ghost-front-review` など、作業ツリーの隣）に
   detach で展開する。作者のツリー・共用ツリーのブランチは動かさない。node_modules と `apps/*/.env*` は作者の
   ツリーへの symlink（読むだけ）。
2. **テストはスクリプトが走らせる**（`config.local.sh` の `test_cmds_for`。host は typecheck と変更ファイルに関係する
   vitest、business-libs は変更パッケージの tsc）。AI には結果とログだけ渡す。
3. 作者以外のエージェントが **読み取り専用** でレビューする。claude/deepseek は `--restricted`（コマンド実行系ツールを外し、
   ユーザー・プロジェクトの設定ファイルの許可ルールや hook を読まず、ファイル操作を worktree の中に限る）＋
   `--permission-mode dontAsk` で、使えるのは Read/Grep/Glob と `git diff/log/show` だけ。MCP も使わない。
   codex は `--sandbox read-only`。複数レビュアーは並列。
4. 結果を `REPORT_DIR/<repo>-pr<N>-<sha8>-<reviewer>.md` に保存し、PR コメントにも出す（`POST_COMMENT`）。
5. 作者の `inbox/<agent>/` にポインタを置き、`notify.sh` が作者の pane に **手すきのときだけ** 1 行送る
   （作業中の表示が無く、入力欄が空のとき。codex の薄字の placeholder は空とみなす）。作業中なら送らず、
   cron の次の巡回で再試行する。送ったポインタには `.notified`（中身は送った先のエージェントの PID）が付く。
   そのエージェントのセッションが閉じた・再起動したら、新しいセッションに送り直す。作者は `PROTOCOL.md` に従って直す。

同じ PR head × レビュアーは二度レビューしない（`~/.cache/cross-review/state/`）。push で head が変われば再レビュー。

## 終わらないレビューを防ぐ

- **再レビューは前回の続き。** 前回レビューした head があれば、前回のレビューと前回からの差分（`since-last.patch`）を
  レビュアーに渡し、「前回の指摘が直ったか」と「前回からの変更で壊れたところ」だけを見させる。前回からあった部分への
  新しい指摘は [高] だけ。直すたびに新しい中・低の指摘が出て終わらない、を防ぐ。
- **回数の上限。** 1 つの PR の自動レビューは `MAX_ROUNDS`（既定 4 = 初回 + 再レビュー 3 回）まで。超えたら止めて、
  ボードに `◆ NEEDS YOU` を出し、作者には修正・push をやめるよう 1 回だけ通知する（`*-limit.txt`）。
  続けるときは `cross-review.sh <repo> <PR> --force`、またはそのまま GitHub でマージする。
- **全員が APPROVE なら作者は push しない**（`PROTOCOL.md`）。低の指摘は PR コメントで「後で」と書くだけ。

## pane の作業を邪魔しない

- レビューは pane の外の別プロセス（`claude -p` / `codex exec`）で動く。pane に入力しない（サブエージェントと同じ考え方）。
- 作者への通知は、その pane が手すき（作業中の表示が無く、入力欄が空）のときだけ 1 行送る。
- テストとレビュアーは `nice`（`REVIEW_NICE`、既定 10）で動かし、pane で動いているエージェントの CPU を先にする。
- deepseek でレビューするときは思考量を `DEEPSEEK_REVIEW_EFFORT`（既定 high）にする。pane の deepseek（max）は変えない。
- テストで動かすときは `NOTIFY=0` にする（本物の pane に通知を送らないように）。

## 信頼できる PR だけ

PR のコードはこの PC でテストとして実行され（`.env` も見える）、レビュアーはファイルを読めて、結果は PR コメントで公開される。
そのため **fork からの PR** と、**`TRUSTED_AUTHORS` にいない人の PR**（空なら各リポジトリの owner だけ）は、`--force` を付けても
レビューしない。`status.sh` では「対象外」と出る。

## 履歴と、止まったときのこと

| 何 | どこ |
|---|---|
| レビュー結果（本文） | `<ワークスペース>/.agent-tools/reviews/<repo>-pr<N>-<sha8>-<reviewer>.md`（ワークスペース = 作業ツリーから上へたどって `agents.yaml` がある所。例 `~/work/legacy/.agent-tools/reviews/`。`REPORT_DIR` を書けば 1 か所に固定）と、同じ内容の PR コメント |
| テストのログ | 同じ場所の `<repo>-pr<N>-<sha8>-tests.log` |
| レビュー済みの印 | `~/.cache/cross-review/state/<repo>-<N>-<sha8>-<reviewer>.done` |
| 作者への受け渡し | `inbox/<agent>/*.txt`（作者が対応したら消す）、`.notified` |
| 巡回のログ | `~/.cache/cross-review/watch.log` |
| 実行中の様子 | レビュー用 worktree の `.cross-review/`（`phase`、`<reviewer>.events.jsonl`。次のレビューで上書き） |

すべてこの PC のファイル（と GitHub の PR コメント）で、agent-tools のリポジトリには入れない（公開リポジトリなので、
private リポジトリのコードを引用するレビューを載せない）。エージェントのセッションが切れても、PC・WSL を再起動しても残る。cron が毎分見直すので、
途中で止まったレビュー（`.done` が無い）は次の巡回でやり直し、作者が対応していない inbox は新しいセッションに送り直す。

## 作者の判定（→ レビュアー）

PR の label `author:claude|codex|deepseek` > `--author` > コミットの痕跡
（`Co-Authored-By: Claude` → claude、`Constraint:`/`Confidence:` → codex、`deepseek` の文字 → deepseek）。
作者と同じエージェントは、`--reviewer` で指定しても `reviewers_for` の設定でも、必ずレビュアーから外す（自分の PR は自分でレビューしない）。
対応表は `config.sh` の `reviewers_for`（claude→codex+deepseek、codex→claude+deepseek、deepseek→codex+claude、不明→3 人とも。`config.local.sh` で上書きできる）。
DeepSeek の Claude Code も `Co-Authored-By: Claude` を付けるので、deepseek の PR には `author:deepseek` label を付けると確実。
`no-cross-review` label の PR と draft は watch が飛ばす。

## インストール（cron の巡回）

```bash
./install.sh              # 毎分の巡回（watch.sh）を cron に入れ、足りないものを確認して表示する
./install.sh --check      # 確認だけ（何も変えない）
./install.sh --uninstall  # 巡回を外す（レビュー結果・設定は残す）
# jibunsee-react などの package.json からは: yarn cross-review:install
```

- パスの設定は要らない。install.sh の場所から watch.sh の場所を決めるので、どこに clone してもよい。
  cron の行は 1 本だけで、前の行（別の場所に clone していた分も）は消して入れ直す。変える前の crontab は
  `~/.cache/cross-review/crontab.bak.<日時>` に残る。何度実行してもよい。
- 確認すること: cron が動いているか（WSL は `/etc/wsl.conf` の `[boot] systemd=true`）、`config.local.sh`
  （無ければひな形を作る）と `REPOS` の作業ツリー、`git gh python3 flock tmux timeout`、`gh` のログイン、
  レビュアーの `claude` / `codex` が cron の PATH から見えるか（見えなければ `EXTRA_PATH` に足す）、deepseek の起動スクリプト。
- `claude` / `codex` のログインは確かめられないので、新しいマシンではそれぞれ一度起動してログインしておく。

入る行（例）:

```
* * * * * $HOME/work/legacy/10-agent-tools/cross-review/watch.sh >> $HOME/.cache/cross-review/watch.log 2>&1
```

## 各エージェントへの指示

`PROTOCOL.md` が共通の決まり。`~/.claude/CLAUDE.md`・`~/.codex/AGENTS.md` から参照し、DeepSeek は起動スクリプトで
`CROSS_REVIEW_AGENT=deepseek` を設定する（CLAUDE.md を claude と共用するため）。

### 旧メモ

> 作業前に `~/work/legacy/10-agent-tools/cross-review/inbox/<自分>/` を確認し、レビューの指摘を直してから次へ進む。
> 読んだポインタは消す。
