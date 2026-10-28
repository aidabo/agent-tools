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

## 何をするか

1. `gh pr view` で head SHA を取り、**レビュー用 worktree**（`01-ghost-front-review` など、作業ツリーの隣）に
   detach で展開する。作者のツリー・共用ツリーのブランチは動かさない。node_modules と `apps/*/.env*` は作者の
   ツリーへの symlink（読むだけ）。
2. **テストはスクリプトが走らせる**（`config.sh` の `test_cmds_for`。host は typecheck と変更ファイルに関係する
   vitest、business-libs は変更パッケージの tsc）。AI には結果とログだけ渡す。
3. 作者以外のエージェントが **読み取り専用** でレビューする（claude/deepseek は `--allowedTools` を Read/Grep/Glob と
   git の閲覧だけに、codex は `--sandbox read-only`）。複数レビュアーは並列。
4. 結果を `22-temp/reviews/cross/<repo>-pr<N>-<sha8>-<reviewer>.md` に保存し、PR コメントにも出す（`POST_COMMENT`）。
5. 作者の `inbox/<agent>/` にポインタを置き、`notify.sh` が作者の pane に **手すきのときだけ** 1 行送る
   （作業中の表示が無く、入力欄が空のとき。codex の薄字の placeholder は空とみなす）。作業中なら送らず、
   cron の次の巡回で再試行する。送ったポインタには `.notified` が付く。作者は `PROTOCOL.md` に従って直す。

同じ PR head × レビュアーは二度レビューしない（`~/.cache/cross-review/state/`）。push で head が変われば再レビュー。

## 作者の判定（→ レビュアー）

PR の label `author:claude|codex|deepseek` > `--author` > コミットの痕跡
（`Co-Authored-By: Claude` → claude、`Constraint:`/`Confidence:` → codex、`deepseek` の文字 → deepseek）。
対応表は `config.sh` の `reviewers_for`（claude→codex、codex→claude、deepseek→codex+claude、不明→claude+codex）。
DeepSeek の Claude Code も `Co-Authored-By: Claude` を付けるので、deepseek の PR には `author:deepseek` label を付けると確実。
`no-cross-review` label の PR と draft は watch が飛ばす。

## 定期実行（任意）

```bash
crontab -e
# 10 分おき（PC が起きている間だけ）
*/10 * * * * $HOME/work/legacy/10-agent-tools/cross-review/watch.sh >> $HOME/.cache/cross-review/watch.log 2>&1
```

## 各エージェントへの指示

`PROTOCOL.md` が共通の決まり。`~/.claude/CLAUDE.md`・`~/.codex/AGENTS.md` から参照し、DeepSeek は起動スクリプトで
`CROSS_REVIEW_AGENT=deepseek` を設定する（CLAUDE.md を claude と共用するため）。

### 旧メモ

> 作業前に `~/work/legacy/10-agent-tools/cross-review/inbox/<自分>/` を確認し、レビューの指摘を直してから次へ進む。
> 読んだポインタは消す。
