#!/usr/bin/env bash
# install.sh — cross-review をこのマシンで動かす準備をする。何度実行してもよい。
#
#   install.sh              cron の巡回（毎分 watch.sh）を入れ、足りないものを確認して表示する
#   install.sh --check      確認だけ（何も変えない）
#   install.sh --uninstall  cron の巡回を外す（レビュー結果・設定は残す）
#
# パスの設定は要らない: この install.sh の場所から watch.sh の場所を決める（どこに clone してもよい）。
# cron の行は 1 本だけ。前の行（別の場所に clone していた分も）は消してから入れ直す。変える前の crontab は
# ~/.cache/cross-review/crontab.bak.<日時> に残す。
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
mode="install"
case "${1:-}" in
  "") ;;
  --check) mode="check" ;;
  --uninstall) mode="uninstall" ;;
  -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  *) echo "unknown option: $1 (use --check or --uninstall)" >&2; exit 1 ;;
esac

if [[ -t 1 ]]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; Z=$'\e[0m'; else G=""; Y=""; R=""; B=""; Z=""; fi
ok()   { echo "  ${G}✓${Z} $*"; }
warn() { echo "  ${Y}!${Z} $*"; problems=$((problems + 1)); }
bad()  { echo "  ${R}✗${Z} $*"; problems=$((problems + 1)); }
problems=0

cache="$HOME/.cache/cross-review"
log="$cache/watch.log"
# $HOME の下なら "$HOME/..." と書く（cron の sh が展開する。ホームの場所が変わっても読みやすく、同じ行になる）
cron_line="* * * * * ${here/#$HOME/\$HOME}/watch.sh >> \$HOME/.cache/cross-review/watch.log 2>&1"

# ── cron ─────────────────────────────────────────────────────
current_crontab() { crontab -l 2>/dev/null || true; }
write_crontab() {   # stdin → crontab（crontab <file> は長いパスを切り詰めるので stdin で渡す）
  mkdir -p "$cache"
  current_crontab > "$cache/crontab.bak.$(date +%Y%m%d%H%M%S)"
  crontab -
}

if [[ "$mode" == "uninstall" ]]; then
  echo "${B}cross-review: uninstall${Z}"
  if current_crontab | grep -q 'cross-review/watch\.sh'; then
    current_crontab | grep -v 'cross-review/watch\.sh' | write_crontab && ok "cron の巡回を外しました（前の crontab は $cache/crontab.bak.* ）"
  else
    ok "cron に巡回は入っていません"
  fi
  echo "  レビュー結果・設定（config.local.sh）・状態（$cache）はそのまま残しています。"
  exit 0
fi

echo "${B}cross-review: ${mode}${Z}  ($here)"

echo "${B}cron${Z}"
if ! command -v crontab >/dev/null 2>&1; then
  bad "crontab がありません（Debian/Ubuntu: sudo apt install cron）"
elif current_crontab | grep -qxF "$cron_line"; then
  ok "巡回は入っています: $cron_line"
elif [[ "$mode" == "check" ]]; then
  if current_crontab | grep -q 'cross-review/watch\.sh'; then
    warn "巡回の行が古い／別の場所を指しています（install.sh で入れ直せます）: $(current_crontab | grep 'cross-review/watch\.sh')"
  else
    warn "巡回が入っていません（install.sh で入ります）"
  fi
else
  mkdir -p "$cache"
  { current_crontab | grep -v 'cross-review/watch\.sh'; echo "$cron_line"; } | write_crontab \
    && ok "巡回を入れました（毎分）: $cron_line" || bad "crontab に書けませんでした"
fi
if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then
  ok "cron は動いています"
else
  bad "cron が動いていません（sudo service cron start。WSL は /etc/wsl.conf の [boot] systemd=true で自動起動）"
fi
if grep -qi microsoft /proc/version 2>/dev/null && ! grep -Eq '^\s*systemd\s*=\s*true' /etc/wsl.conf 2>/dev/null; then
  warn "WSL: /etc/wsl.conf に [boot] systemd=true が無いので、WSL を起動し直すと cron が止まったままになります"
fi

# ── 設定 ─────────────────────────────────────────────────────
echo "${B}設定${Z}"
if [[ ! -f "$here/config.local.sh" ]]; then
  if [[ "$mode" == "install" ]]; then
    cp "$here/config.local.example.sh" "$here/config.local.sh"
    warn "config.local.sh を作りました（ひな形）。対象リポジトリ（REPOS）とテストを書いてください: $here/config.local.sh"
  else
    warn "config.local.sh がありません（install.sh でひな形が作られます）"
  fi
fi
# shellcheck source=config.sh
source "$here/config.sh"
if [[ ${#REPOS[@]} -eq 0 ]]; then
  bad "REPOS が空です（config.local.sh）"
fi
reviewers_used=""
for entry in "${REPOS[@]}"; do
  IFS='|' read -r name gh_repo src wt <<<"$entry"
  if [[ "$gh_repo" == me/* ]]; then
    warn "$name: ひな形のままです（config.local.sh の REPOS を書き換えてください）"
  elif [[ ! -d "$src/.git" && ! -f "$src/.git" ]]; then
    bad "$name: 作業ツリーがありません: $src"
  else
    ok "$name ($gh_repo) — 作業ツリー $src、結果は $(report_dir_for "$src")"
  fi
done
for a in claude codex deepseek unknown; do reviewers_used+=" $(reviewers_for "$a")"; done

# ── 道具とログイン ─────────────────────────────────────────────
echo "${B}道具とログイン${Z}"
for cmd in git gh python3 flock tmux timeout; do
  command -v "$cmd" >/dev/null 2>&1 && ok "$cmd" || bad "$cmd がありません"
done
if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 && ok "gh にログイン済み" || bad "gh にログインしていません（gh auth login）"
fi
# cron は PATH が最小なので、watch.sh と同じ PATH で探す
cron_path="$HOME/.local/bin${EXTRA_PATH:+:$EXTRA_PATH}"
[[ -z "$EXTRA_PATH" ]] && cron_path+=":$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
cron_path+=":/usr/local/bin:/usr/bin:/bin"
for r in claude codex; do
  [[ " $reviewers_used " == *" $r "* ]] || continue
  if PATH="$cron_path" command -v "$r" >/dev/null 2>&1; then
    ok "$r（cron からも見つかる）"
  elif command -v "$r" >/dev/null 2>&1; then
    warn "$r は今のシェルにはあるが cron からは見つからない（config.local.sh の EXTRA_PATH に $(dirname "$(command -v "$r")") を足す）"
  else
    bad "$r がありません（レビュアーに使っています）"
  fi
done
if [[ " $reviewers_used " == *" deepseek "* ]]; then
  # cron（watch.sh）と同じ PATH で config.sh を読み直し、そこで解決できるか確かめる
  cron_launcher="$(PATH="$cron_path" bash -c '
    set -u
    source "$1/config.sh"
    printf "%s" "${DEEPSEEK_LAUNCHER:-}"
  ' _ "$CROSS_REVIEW_HOME" 2>/dev/null)"
  if [[ -n "$cron_launcher" && -f "$cron_launcher" ]]; then
    ok "deepseek の起動スクリプト: $cron_launcher（cron からも見つかる）"
  elif [[ -n "${DEEPSEEK_LAUNCHER:-}" && -f "$DEEPSEEK_LAUNCHER" ]]; then
    warn "deepseek は今のシェルにはあるが cron からは見つからない（config.local.sh の EXTRA_PATH に $(dirname "$DEEPSEEK_LAUNCHER") を足すか、DEEPSEEK_LAUNCHER を絶対パスで指定）"
  else
    warn "deepseek の起動スクリプトが見つかりません（PATH に deepseek を置くか、config.local.sh で DEEPSEEK_LAUNCHER=/path/to/deepseek を指定。使わないなら reviewers_for から外す）"
  fi
fi
echo "  （claude・codex のログイン状態は確認できないので、それぞれ一度起動してログインしておいてください）"

echo
if [[ $problems -eq 0 ]]; then
  echo "${G}${B}準備できています。${Z} 状態は status.sh、監視セッションは agent-notify/monitor.sh（yarn monitor）で見られます。"
else
  echo "${Y}${B}確認が必要なものが ${problems} 件あります（上の ! と ✗）。${Z}"
fi
exit 0
