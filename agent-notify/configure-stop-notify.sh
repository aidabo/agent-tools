#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
INSTALL_ROOT="${NOTIFY_INSTALL_ROOT:-$HOME/.notify}"
CONFIG_PATH="${CLAWHIP_STOP_NOTIFY_CONFIG:-$INSTALL_ROOT/stop-notify.json}"
EXAMPLE_PATH="$BASE_DIR/stop-notify.example.json"
ENV_PATH="${CLAWHIP_STOP_NOTIFY_ENV:-$INSTALL_ROOT/stop-notify.env}"
ENV_EXAMPLE_PATH="$BASE_DIR/stop-notify.env.example"
DEFAULT_NOTIFY_PROJECT_ROOT="${CLAWHIP_NOTIFY_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
DEFAULT_NOTIFY_STATE_ROOT="${CLAWHIP_NOTIFY_STATE_ROOT:-$DEFAULT_NOTIFY_PROJECT_ROOT/.omx/notify-state}"
HOOK_SOURCE_PATH="$BASE_DIR/hooks/native-hook.mjs"
SENDTMUX_SOURCE_PATH="$BASE_DIR/sendtmux.sh"
SCRIPT_SOURCE_PATH="$BASE_DIR/configure-stop-notify.sh"

usage() {
  cat <<'EOF'
Usage:
  configure-stop-notify.sh
  configure-stop-notify.sh help
  configure-stop-notify.sh init
  configure-stop-notify.sh init-env
  configure-stop-notify.sh menu
  configure-stop-notify.sh install
  configure-stop-notify.sh list-panes
  configure-stop-notify.sh current-pane
  configure-stop-notify.sh name-pane --title TITLE
  configure-stop-notify.sh preview-current
  configure-stop-notify.sh show
  configure-stop-notify.sh show-env
  configure-stop-notify.sh doctor
  configure-stop-notify.sh set-webhook --env-name ENV_NAME --url WEBHOOK_URL
  configure-stop-notify.sh set-route --target SESSION:WINDOW.PANE_INDEX --webhook-env ENV_NAME [--title TITLE] [--pane-id PANE_ID] [--mention @name]
  configure-stop-notify.sh set-current-route --webhook-env ENV_NAME [--title TITLE] [--pane-id PANE_ID] [--mention @name]
  configure-stop-notify.sh rebind-route --target SESSION:WINDOW.PANE_INDEX --webhook-env ENV_NAME [--title TITLE] [--pane-id PANE_ID] [--mention @name]
  configure-stop-notify.sh disable-route --target SESSION:WINDOW.PANE_INDEX
  configure-stop-notify.sh enable-route --target SESSION:WINDOW.PANE_INDEX
  configure-stop-notify.sh remove-route --target SESSION:WINDOW.PANE_INDEX
  configure-stop-notify.sh unbind-route --target SESSION:WINDOW.PANE_INDEX
  configure-stop-notify.sh clear
  configure-stop-notify.sh clear-routes
  configure-stop-notify.sh target-menu [--target SESSION:WINDOW.PANE_INDEX]

Examples:
  configure-stop-notify.sh set-webhook --env-name DISCORD_WEBHOOK_URL_PANE1 --url https://discord.com/api/webhooks/...
  configure-stop-notify.sh set-route --target omx-session:0.1 --webhook-env DISCORD_WEBHOOK_URL_PANE1 --title worker1 --pane-id %1
  configure-stop-notify.sh rebind-route --target omx-session:0.1 --webhook-env DISCORD_WEBHOOK_URL_PANE1 --title worker1 --pane-id %1 --mention @worker
  configure-stop-notify.sh disable-route --target omx-session:0.1
  configure-stop-notify.sh enable-route --target omx-session:0.1
  configure-stop-notify.sh unbind-route --target omx-session:0.1
  configure-stop-notify.sh set-route --target omx-session:0.0 --webhook-env DISCORD_WEBHOOK_URL --title main --pane-id %0
  configure-stop-notify.sh clear
  configure-stop-notify.sh clear-routes

Notes:
  - The hook reads $HOME/.notify/stop-notify.json by default.
  - The hook also reads $HOME/.notify/stop-notify.env for webhook env values when process env vars are missing.
  - The env file also carries CLAWHIP_NOTIFY_STATE_ROOT so tmux pane state can live in a repo-local shared directory.
  - webhook URLs should live in environment variables, not in the JSON file.
  - A route matches by session/window/pane_index and may also pin pane_id for extra stability.
  - Per-pane runtime state is saved under $HOME/.notify/state/:
    - prompt-submit/<session>.<window>.<pane>.json
    - pane-output/<session>.<window>.<pane>.diff
  - Use target-menu from any terminal when the current pane is already occupied by omx/codex.
  - current/target submenus use 0/b to return to the main menu.
  - config is read-only; use the CLI commands above to change routes, webhook envs, titles, pane IDs, or mentions.
  - Set CLAWHIP_DISCORD_MESSAGE_MODE=content to keep the default text payloads.
  - Set CLAWHIP_DISCORD_DRY_RUN=1 to preview the payload without sending it.
EOF
}

ensure_config() {
  mkdir -p "$(dirname "$CONFIG_PATH")"
  if [[ ! -f "$CONFIG_PATH" ]]; then
    cp "$EXAMPLE_PATH" "$CONFIG_PATH"
  fi
}

ensure_env_file() {
  mkdir -p "$(dirname "$ENV_PATH")"
  if [[ ! -f "$ENV_PATH" ]]; then
    cp "$ENV_EXAMPLE_PATH" "$ENV_PATH"
  fi
  ensure_state_root_entry
  mkdir -p "$DEFAULT_NOTIFY_STATE_ROOT"
  chmod 600 "$ENV_PATH"
}

ensure_state_root_entry() {
  python3 - "$ENV_PATH" "$DEFAULT_NOTIFY_PROJECT_ROOT" "$DEFAULT_NOTIFY_STATE_ROOT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
project_root = sys.argv[2]
state_root = sys.argv[3]
lines = path.read_text().splitlines() if path.exists() else []
project_root_needle = "CLAWHIP_NOTIFY_PROJECT_ROOT="
needle = "CLAWHIP_NOTIFY_STATE_ROOT="
project_root_updated = False
updated = False
out = []
for line in lines:
    if line.startswith(project_root_needle):
        out.append(f"CLAWHIP_NOTIFY_PROJECT_ROOT={project_root}")
        project_root_updated = True
    elif line.startswith(needle):
        out.append(f"CLAWHIP_NOTIFY_STATE_ROOT={state_root}")
        updated = True
    if line.startswith(needle):
        continue
    if line.startswith(project_root_needle):
        continue
    if not line.startswith(project_root_needle) and not line.startswith(needle):
        out.append(line)
if not project_root_updated:
    out.append(f"CLAWHIP_NOTIFY_PROJECT_ROOT={project_root}")
if not updated:
    out.append(f"CLAWHIP_NOTIFY_STATE_ROOT={state_root}")
path.write_text("\n".join(out).rstrip() + "\n")
PY
}

install_layout() {
  copy_if_different() {
    local src="$1"
    local dst="$2"
    if [[ -e "$dst" ]] && [[ "$(readlink -f "$src")" == "$(readlink -f "$dst")" ]]; then
      return 0
    fi
    cp "$src" "$dst"
  }

  mkdir -p "$INSTALL_ROOT/hooks"
  copy_if_different "$SCRIPT_SOURCE_PATH" "$INSTALL_ROOT/configure-stop-notify.sh"
  copy_if_different "$HOOK_SOURCE_PATH" "$INSTALL_ROOT/hooks/native-hook.mjs"
  copy_if_different "$SENDTMUX_SOURCE_PATH" "$INSTALL_ROOT/sendtmux.sh"
  copy_if_different "$BASE_DIR/README.md" "$INSTALL_ROOT/README.md"
  copy_if_different "$EXAMPLE_PATH" "$INSTALL_ROOT/stop-notify.example.json"
  copy_if_different "$ENV_EXAMPLE_PATH" "$INSTALL_ROOT/stop-notify.env.example"

  if [[ ! -f "$INSTALL_ROOT/stop-notify.json" ]]; then
    copy_if_different "$EXAMPLE_PATH" "$INSTALL_ROOT/stop-notify.json"
  fi

  if [[ ! -f "$INSTALL_ROOT/stop-notify.env" ]]; then
    copy_if_different "$ENV_EXAMPLE_PATH" "$INSTALL_ROOT/stop-notify.env"
  fi
  ENV_PATH="$INSTALL_ROOT/stop-notify.env" ensure_state_root_entry
  mkdir -p "$DEFAULT_NOTIFY_STATE_ROOT"
  chmod 600 "$INSTALL_ROOT/stop-notify.env"

  chmod 755 "$INSTALL_ROOT/configure-stop-notify.sh"
  chmod 755 "$INSTALL_ROOT/hooks/native-hook.mjs"
  chmod 755 "$INSTALL_ROOT/sendtmux.sh"
  echo "Installed notify assets to: $INSTALL_ROOT"
}

parse_target() {
  local target="$1"
  if [[ ! "$target" =~ ^([^:]+):([0-9]+)\.([0-9]+)$ ]]; then
    echo "Invalid target: $target" >&2
    echo "Expected format: session:window.pane_index (e.g. omx-session:0.0)" >&2
    exit 1
  fi
  TARGET_SESSION="${BASH_REMATCH[1]}"
  TARGET_WINDOW="${BASH_REMATCH[2]}"
  TARGET_PANE_INDEX="${BASH_REMATCH[3]}"
}

current_target() {
  tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}'
}

list_panes_pretty() {
  tmux list-panes -a -F 'target=#{session_name}:#{window_index}.#{pane_index} title=#{pane_title} pane_id=#{pane_id} active=#{pane_active} cmd=#{pane_current_command}'
}

list_panes_for_selection() {
  local tab=$'\t'
  tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}${tab}#{pane_title}${tab}#{pane_active}${tab}#{pane_current_command}"
}

prompt_target() {
  local prompt="${1:-Target (session:window.pane_index, e.g. omx-session:0.0)}"
  local target=""
  read -r -p "$prompt: " target
  if [[ -z "${target:-}" ]]; then
    echo "Skipped: target is required"
    return 1
  fi
  printf '%s\n' "$target"
}

prompt_route_details() {
  local default_env="${1:-DISCORD_WEBHOOK_URL}"
  local target="${2:-}"
  local env_name pane_title pane_id mention
  if [[ -z "${target:-}" ]]; then
    target="$(prompt_target "${3:-Target (session:window.pane_index, e.g. omx-session:0.0)}")" || return 1
  fi
  read -r -p "Webhook env name [${default_env}]: " env_name
  env_name="${env_name:-$default_env}"
  read -r -p "Title (optional): " pane_title
  read -r -p "Pane ID (optional, e.g. %1): " pane_id
  read -r -p "Mention (optional): " mention

  if [[ -n "${mention:-}" ]]; then
    if [[ -n "${pane_title:-}" ]]; then
      if [[ -n "${pane_id:-}" ]]; then
        bash "$0" set-route --target "$target" --webhook-env "$env_name" --title "$pane_title" --pane-id "$pane_id" --mention "$mention"
      else
        bash "$0" set-route --target "$target" --webhook-env "$env_name" --title "$pane_title" --mention "$mention"
      fi
    elif [[ -n "${pane_id:-}" ]]; then
      bash "$0" set-route --target "$target" --webhook-env "$env_name" --pane-id "$pane_id" --mention "$mention"
    else
      bash "$0" set-route --target "$target" --webhook-env "$env_name" --mention "$mention"
    fi
  elif [[ -n "${pane_title:-}" ]]; then
    if [[ -n "${pane_id:-}" ]]; then
      bash "$0" set-route --target "$target" --webhook-env "$env_name" --title "$pane_title" --pane-id "$pane_id"
    else
      bash "$0" set-route --target "$target" --webhook-env "$env_name" --title "$pane_title"
    fi
  elif [[ -n "${pane_id:-}" ]]; then
    bash "$0" set-route --target "$target" --webhook-env "$env_name" --pane-id "$pane_id"
  else
    bash "$0" set-route --target "$target" --webhook-env "$env_name"
  fi
}

prompt_current_target() {
  local target=""
  target="$(current_target 2>/dev/null || true)"
  if [[ -z "${target:-}" ]]; then
    echo "Current pane is unavailable."
    return 1
  fi
  printf '%s\n' "$target"
}

set_pane_title_for_target() {
  local target="${1:-}"
  local prompt="${2:-New title}"
  local title=""
  [[ -n "$target" ]] || return 1
  read -r -p "$prompt: " title
  if [[ -z "${title:-}" ]]; then
    echo "Skipped: empty title"
    return 1
  fi
  tmux select-pane -t "$target" -T "$title"
  echo "Named pane: $target | $title"
}

title_menu() {
  ensure_config
  ensure_env_file
  while true; do
    local target
    if target="$(prompt_pane_target "Select pane for title")"; then
      set_pane_title_for_target "$target" "New title for $target"
      continue
    else
      local rc=$?
      case "$rc" in
        1)
          return 0
          ;;
        2)
          continue
          ;;
      esac
    fi
  done
}

prompt_pane_target() {
  local prompt="${1:-Select pane}"
  local active_lines=()
  local inactive_lines=()
  local pane_lines=()
  local line idx target title active cmd selection
  mapfile -t pane_lines < <(list_panes_for_selection)
  if [[ ${#pane_lines[@]} -eq 0 ]]; then
    echo "No panes available."
    return 1
  fi

  for line in "${pane_lines[@]}"; do
    IFS=$'\t' read -r target title active cmd <<<"$line"
    if [[ "${active:-0}" == "1" ]]; then
      active_lines+=("$line")
    else
      inactive_lines+=("$line")
    fi
  done

  echo >&2
  echo "=== Panes ===" >&2
  echo "Current: $(current_target 2>/dev/null || true)" >&2
  echo "Prompt: $prompt" >&2
  pane_lines=("${active_lines[@]}" "${inactive_lines[@]}")
  for idx in "${!pane_lines[@]}"; do
    IFS=$'\t' read -r target title active cmd <<<"${pane_lines[$idx]}"
    active_mark=""
    [[ "${active:-0}" == "1" ]] && active_mark="* "
    printf '%s) %s%s%s\n' \
      "$((idx + 1))" \
      "$active_mark" \
      "$target" \
      "${title:+ | $title}" >&2
  done
  echo "0/b) back" >&2

  read -r -p "Select pane: " selection
  case "${selection:-}" in
    0|b|B)
      return 1
      ;;
    ''|*[!0-9]*)
      echo "Unknown choice"
      return 2
      ;;
  esac

  if (( selection < 1 || selection > ${#pane_lines[@]} )); then
    echo "Unknown choice"
    return 2
  fi

  IFS=$'\t' read -r target title active cmd <<<"${pane_lines[$((selection - 1))]}"
  printf '%s\n' "$target"
}

run_target_route_action() {
  local action="${1:-}"
  local target="${2:-}"
  if [[ -z "${target:-}" ]]; then
    target="$(prompt_target "Target (session:window.pane_index, e.g. omx-session:0.0)")" || return 1
  fi
  bash "$0" "$action" --target "$target"
}

current_menu() {
  ensure_config
  ensure_env_file
  local target="${1:-}"
  if [[ -z "${target:-}" ]]; then
    target="$(prompt_current_target)" || return 1
  fi
  while true; do
    cat <<'EOF'

=== Current ===
1) rebind
2) disable
3) enable
4) unbind
5) clear
0/b) back
EOF
    echo "Target: $target"
    read -r -p "Choose: " choice
    case "${choice:-}" in
      1)
        prompt_route_details "DISCORD_WEBHOOK_URL" "$target"
        ;;
      2)
        run_target_route_action "disable-route" "$target"
        ;;
      3)
        run_target_route_action "enable-route" "$target"
        ;;
      4)
        run_target_route_action "unbind-route" "$target"
        ;;
      5)
        clear_routes
        ;;
      0|b|B)
        return 0
        ;;
      *)
        echo "Unknown choice"
        ;;
    esac
  done
}

target_menu() {
  ensure_config
  ensure_env_file
  local target="${1:-}"
  if [[ -z "${target:-}" ]]; then
    while true; do
      if target="$(prompt_pane_target "Target for route binding")"; then
        break
      else
        local rc=$?
        case "$rc" in
          1)
            return 0
            ;;
          2)
            echo "No target selected."
            ;;
        esac
      fi
    done
  fi
  while true; do
    cat <<'EOF'

=== Target ===
1) rebind
2) disable
3) enable
4) unbind
5) clear
6) pick different target
0/b) back
EOF
    echo "Target: $target"
    read -r -p "Choose: " choice
    case "${choice:-}" in
      1)
        prompt_route_details "DISCORD_WEBHOOK_URL" "$target"
        ;;
      2)
        run_target_route_action "disable-route" "$target"
        ;;
      3)
        run_target_route_action "enable-route" "$target"
        ;;
      4)
        run_target_route_action "unbind-route" "$target"
        ;;
      5)
        clear_routes
        ;;
      6)
        if target="$(prompt_pane_target "Pick a different target for route binding")"; then
          echo "Target updated: $target"
        else
          local rc=$?
          case "$rc" in
            1)
              ;;
            2)
              echo "Target unchanged."
              ;;
          esac
        fi
        ;;
      0|b|B)
        return 0
        ;;
      *)
        echo "Unknown choice"
        ;;
    esac
  done
}

preview_current() {
  local target title pane_id cwd input_json
  target="$(current_target 2>/dev/null || true)"
  if [[ -z "${target:-}" ]]; then
    echo "Preview requires tmux." >&2
    exit 1
  fi
  title="$(tmux display-message -p -t "$target" '#{pane_title}' 2>/dev/null || true)"
  pane_id="$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null || true)"
  cwd="$(pwd)"
  parse_target "$target"
  input_json="$(
    python3 - "$cwd" "$TARGET_SESSION" "$TARGET_WINDOW" "$TARGET_PANE_INDEX" "$pane_id" "$title" <<'PY'
import json, sys

cwd, session, window, pane_index, pane_id, title = sys.argv[1:]
print(json.dumps({
    "hook_event_name": "stop",
    "cwd": cwd,
    "tmux_session": session,
    "tmux_window": window,
    "tmux_pane_index": pane_index,
    "tmux_pane": pane_id,
    "tmux_title": title,
    "session_id": "preview",
}))
PY
  )"
  CLAWHIP_STOP_NOTIFY_CONFIG="$CONFIG_PATH" \
  CLAWHIP_STOP_NOTIFY_ENV="$ENV_PATH" \
  CLAWHIP_DISCORD_DRY_RUN=1 \
  node "$BASE_DIR/hooks/native-hook.mjs" <<<"$input_json"
}

menu() {
  ensure_config
  ensure_env_file
  while true; do
    local_pane="$(current_target 2>/dev/null || true)"
    local_title="$(tmux display-message -p -t "$local_pane" '#{pane_title}' 2>/dev/null || true)"
    cat <<'EOF'

=== Stop Notify Menu ===
1) current
2) panes
3) target
4) title
5) config
6) env
7) doctor
8) preview current
9) install
10) clear
0/q) exit
EOF
    if [[ -n "${local_pane:-}" ]]; then
      if [[ -n "${local_title:-}" ]]; then
        echo "Current: $local_pane | $local_title"
      else
        echo "Current: $local_pane"
      fi
    fi
    read -r -p "Choose: " choice
    case "${choice:-}" in
      1)
        current_menu
        ;;
      2)
        list_panes_pretty
        ;;
      3)
        target_menu
        ;;
      4)
        title_menu
        ;;
      5)
        bash "$0" show
        ;;
      6)
        bash "$0" show-env
        ;;
      7)
        bash "$0" doctor
        ;;
      8)
        preview_current
        ;;
      9)
        install_layout
        ;;
      10)
        clear_routes
        ;;
      0)
        exit 0
        ;;
      q|Q)
        exit 0
        ;;
      *)
        echo "Unknown choice"
        ;;
    esac
  done
}

clear_routes() {
  ensure_config
  python3 - "$CONFIG_PATH" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
default = data.get("default", {})
if not isinstance(default, dict):
    default = {}
data = {
    "default": {
        "webhook_env": default.get("webhook_env", "DISCORD_WEBHOOK_URL"),
        "mention": default.get("mention", ""),
        "capture_lines": default.get("capture_lines", 400),
        "chunk_size": default.get("chunk_size", 3200),
        "chunk_delay_ms": default.get("chunk_delay_ms", 1000),
    }
}
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
  echo "Cleared all route entries; default settings kept in $CONFIG_PATH"
}

cmd="${1:-menu}"
case "$cmd" in
  init)
    ensure_config
    echo "Initialized: $CONFIG_PATH"
    ;;

  init-env)
    ensure_env_file
    echo "Initialized: $ENV_PATH"
    ;;

  install)
    install_layout
    ;;

  menu)
    menu
    ;;

  clear|clear-routes)
    clear_routes
    ;;

  target-menu)
    shift
    target=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target)
          target="${2:-}"
          shift 2
          ;;
        *)
          echo "Unknown argument: $1" >&2
          usage
          exit 1
          ;;
      esac
    done
    target_menu "$target"
    ;;

  preview-current)
    preview_current
    ;;

  list-panes)
    list_panes_pretty
    ;;

  current-pane)
    tmux display-message -p 'current=#{session_name}:#{window_index}.#{pane_index} title=#{pane_title} pane_id=#{pane_id} cmd=#{pane_current_command}'
    ;;

  name-pane)
    shift
    title=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title)
          title="${2:-}"
          shift 2
          ;;
        *)
          echo "Unknown argument: $1" >&2
          usage
          exit 1
          ;;
      esac
    done
    [[ -n "$title" ]] || { echo "--title is required" >&2; exit 1; }
    tmux select-pane -T "$title"
    echo "Named current pane: $title"
    ;;

  show)
    ensure_config
    cat "$CONFIG_PATH"
    ;;

  show-env)
    ensure_env_file
    cat "$ENV_PATH"
    ;;

  doctor)
    ensure_config
    ensure_env_file
  python3 - "$CONFIG_PATH" "$ENV_PATH" <<'PY'
import json, sys
from pathlib import Path
import os

config_path = Path(sys.argv[1])
env_path = Path(sys.argv[2])
config = json.loads(config_path.read_text())
env = {}
for raw in env_path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    k, v = line.split('=', 1)
    env[k.strip()] = v.strip().strip('"').strip("'")

print(f"config: {config_path}")
print(f"env: {env_path}")
project_root = env.get("CLAWHIP_NOTIFY_PROJECT_ROOT", "")
state_root = env.get("CLAWHIP_NOTIFY_STATE_ROOT", "")
expected_state_root = f"{project_root}/.omx/notify-state" if project_root else ""
if project_root:
    print(f"notify project root: {project_root}")
else:
    print("notify project root: MISSING")
if state_root:
    status = "OK" if state_root == expected_state_root else "CUSTOM"
    print(f"notify state root: {state_root} [{status}]")
    if expected_state_root:
        print(f"expected repo-local state root: {expected_state_root}")
else:
    if expected_state_root:
      print(f"notify state root: MISSING (expected {expected_state_root})")
    else:
      print("notify state root: MISSING")
shell_state_root = os.environ.get("CLAWHIP_NOTIFY_STATE_ROOT", "").strip()
if shell_state_root and shell_state_root != state_root:
    print(f"shell notify state root: {shell_state_root} [MISMATCH]")
    print("warning: shell env and stop-notify.env point at different state roots")
elif shell_state_root:
    print(f"shell notify state root: {shell_state_root} [MATCH]")
else:
    print("shell notify state root: (unset)")
default = config.get("default", {})
routes = config.get("routes", [])
default_env = default.get("webhook_env", "DISCORD_WEBHOOK_URL")
print(f"default webhook env: {default_env} -> {'OK' if env.get(default_env) else 'MISSING'}")
if state_root:
    state_path = Path(state_root)
    if state_path.exists():
        print("notify state root exists: yes")
        print(f"notify state root writable: {'yes' if os.access(state_path, os.W_OK) else 'no'}")
    else:
        print("notify state root exists: no")
        print("notify state root writable: unknown (missing dir)")
print("target format: session:window.pane_index (e.g. omx-session:0.0)")
print("target example: omx-session:0.0")
if not routes:
    print("routes: (none)")
else:
    print("routes:")
    for route in routes:
        name = route.get("name", "(unnamed)")
        match = route.get("match", {})
        webhook_env = route.get("webhook_env", default_env)
        mention = route.get("mention", "")
        # same fallback as the hook: a route without "enabled" follows default.enabled
        enabled = route.get("enabled", default.get("enabled", True))
        status = "DISABLED" if enabled is False else ("OK" if env.get(webhook_env) else "MISSING")
        target = f"{match.get('session','*')}:{match.get('window','*')}.{match.get('pane_index','*')}"
        pane_id = match.get("pane_id", match.get("pane", ""))
        title = match.get("title", "")
        extra = []
        if title:
            extra.append(f"title={title}")
        if pane_id:
            extra.append(f"pane_id={pane_id}")
        extra_text = f" {' '.join(extra)}" if extra else ""
        print(
            f"  - {name} target={target} (session:window.pane_index){extra_text} "
            f"webhook_env={webhook_env} [{status}] mention={mention or '(none)'}"
        )
PY
    ;;

  set-webhook)
    shift
    env_name=""
    url=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --env-name)
          env_name="${2:-}"
          shift 2
          ;;
        --url)
          url="${2:-}"
          shift 2
          ;;
        *)
          echo "Unknown argument: $1" >&2
          usage
          exit 1
          ;;
      esac
    done
    [[ -n "$env_name" ]] || { echo "--env-name is required" >&2; exit 1; }
    [[ -n "$url" ]] || { echo "--url is required" >&2; exit 1; }
    ensure_env_file
    python3 - "$ENV_PATH" "$env_name" "$url" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text().splitlines()
needle = f"{key}="
updated = False
out = []
for line in lines:
    if line.startswith(needle):
        out.append(f"{key}={value}")
        updated = True
    else:
        out.append(line)
if not updated:
    out.append(f"{key}={value}")
path.write_text("\n".join(out).rstrip() + "\n")
PY
    chmod 600 "$ENV_PATH"
    echo "Saved webhook env: $env_name"
    echo "Env file: $ENV_PATH"
    ;;

  set-route)
    shift
    target=""
    webhook_env=""
    pane_title=""
    pane_id=""
    mention=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target)
          target="${2:-}"
          shift 2
          ;;
        --webhook-env)
          webhook_env="${2:-}"
          shift 2
          ;;
        --title)
          pane_title="${2:-}"
          shift 2
          ;;
        --pane-id)
          pane_id="${2:-}"
          shift 2
          ;;
        --mention)
          mention="${2:-}"
          shift 2
          ;;
        *)
          echo "Unknown argument: $1" >&2
          usage
          exit 1
          ;;
      esac
    done
    [[ -n "$target" ]] || { echo "--target is required" >&2; exit 1; }
    [[ -n "$webhook_env" ]] || { echo "--webhook-env is required" >&2; exit 1; }
    parse_target "$target"
    ensure_config
    python3 - "$CONFIG_PATH" "$TARGET_SESSION" "$TARGET_WINDOW" "$TARGET_PANE_INDEX" "$webhook_env" "$pane_title" "$pane_id" "$mention" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
session, window, pane_index, webhook_env, pane_title, pane_id, mention = sys.argv[2:]
data = json.loads(path.read_text())
data.setdefault("default", {
    "webhook_env": "DISCORD_WEBHOOK_URL",
    "mention": "",
    "capture_lines": 400,
    "chunk_size": 3200,
    "chunk_delay_ms": 1000,
})
routes = data.setdefault("routes", [])
match = {"session": session, "window": window, "pane_index": pane_index}
if pane_title:
    match["title"] = pane_title
if pane_id:
    match["pane_id"] = pane_id
route = next(
    (
        r
        for r in routes
        if r.get("match", {}).get("session") == session
        and r.get("match", {}).get("window") == window
        and r.get("match", {}).get("pane_index") == pane_index
    ),
    None,
)
if route is None:
    route = {"name": f"{session}-{window}-{pane_index}", "match": match}
    routes.append(route)
else:
    route["match"] = match
route["webhook_env"] = webhook_env
if mention:
    route["mention"] = mention
else:
    route.pop("mention", None)
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
    echo "Saved route for $target -> $webhook_env"
    [[ -n "$pane_title" ]] && echo "Title: $pane_title"
    [[ -n "$pane_id" ]] && echo "Pane ID: $pane_id"
    [[ -n "$mention" ]] && echo "Mention: $mention"
    echo "Config: $CONFIG_PATH"
    ;;

  set-current-route)
    shift
    webhook_env=""
    pane_title=""
    pane_id=""
    mention=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --webhook-env)
          webhook_env="${2:-}"
          shift 2
          ;;
        --title)
          pane_title="${2:-}"
          shift 2
          ;;
        --pane-id)
          pane_id="${2:-}"
          shift 2
          ;;
        --mention)
          mention="${2:-}"
          shift 2
          ;;
        *)
          echo "Unknown argument: $1" >&2
          usage
          exit 1
          ;;
      esac
    done
    [[ -n "$webhook_env" ]] || { echo "--webhook-env is required" >&2; exit 1; }
    target="$(current_target)"
    if [[ -n "$mention" ]]; then
      if [[ -n "$pane_title" ]]; then
        if [[ -n "$pane_id" ]]; then
          bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --title "$pane_title" --pane-id "$pane_id" --mention "$mention"
        else
          bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --title "$pane_title" --mention "$mention"
        fi
      elif [[ -n "$pane_id" ]]; then
        bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --pane-id "$pane_id" --mention "$mention"
      else
        bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --mention "$mention"
      fi
    elif [[ -n "$pane_title" ]]; then
      if [[ -n "$pane_id" ]]; then
        bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --title "$pane_title" --pane-id "$pane_id"
      else
        bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --title "$pane_title"
      fi
    elif [[ -n "$pane_id" ]]; then
      bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --pane-id "$pane_id"
    else
      bash "$0" set-route --target "$target" --webhook-env "$webhook_env"
    fi
    ;;

  rebind-route)
    shift
    target=""
    webhook_env=""
    pane_title=""
    pane_id=""
    mention=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target)
          target="${2:-}"
          shift 2
          ;;
        --webhook-env)
          webhook_env="${2:-}"
          shift 2
          ;;
        --title)
          pane_title="${2:-}"
          shift 2
          ;;
        --pane-id)
          pane_id="${2:-}"
          shift 2
          ;;
        --mention)
          mention="${2:-}"
          shift 2
          ;;
        *)
          echo "Unknown argument: $1" >&2
          usage
          exit 1
          ;;
      esac
    done
    [[ -n "$target" ]] || { echo "--target is required" >&2; exit 1; }
    [[ -n "$webhook_env" ]] || { echo "--webhook-env is required" >&2; exit 1; }
    parse_target "$target"
    ensure_config
    if [[ -n "$mention" ]]; then
      if [[ -n "$pane_title" ]]; then
        if [[ -n "$pane_id" ]]; then
          bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --title "$pane_title" --pane-id "$pane_id" --mention "$mention"
        else
          bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --title "$pane_title" --mention "$mention"
        fi
      elif [[ -n "$pane_id" ]]; then
        bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --pane-id "$pane_id" --mention "$mention"
      else
        bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --mention "$mention"
      fi
    elif [[ -n "$pane_title" ]]; then
      if [[ -n "$pane_id" ]]; then
        bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --title "$pane_title" --pane-id "$pane_id"
      else
        bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --title "$pane_title"
      fi
    elif [[ -n "$pane_id" ]]; then
      bash "$0" set-route --target "$target" --webhook-env "$webhook_env" --pane-id "$pane_id"
    else
      bash "$0" set-route --target "$target" --webhook-env "$webhook_env"
    fi
    ;;

  disable-route)
    shift
    target=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target)
          target="${2:-}"
          shift 2
          ;;
        *)
          echo "Unknown argument: $1" >&2
          usage
          exit 1
          ;;
      esac
    done
    [[ -n "$target" ]] || { echo "--target is required" >&2; exit 1; }
    parse_target "$target"
    ensure_config
    python3 - "$CONFIG_PATH" "$TARGET_SESSION" "$TARGET_WINDOW" "$TARGET_PANE_INDEX" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
session, window, pane_index = sys.argv[2:]
data = json.loads(path.read_text())
routes = data.get("routes", [])
updated = False
for route in routes:
    match = route.get("match", {})
    if (
        match.get("session") == session
        and match.get("window") == window
        and match.get("pane_index") == pane_index
    ):
        route["enabled"] = False
        updated = True
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
if not updated:
    sys.stderr.write("No route matched target\n")
    sys.exit(1)
PY
    echo "Disabled route for $target"
    ;;

  enable-route)
    shift
    target=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target)
          target="${2:-}"
          shift 2
          ;;
        *)
          echo "Unknown argument: $1" >&2
          usage
          exit 1
          ;;
      esac
    done
    [[ -n "$target" ]] || { echo "--target is required" >&2; exit 1; }
    parse_target "$target"
    ensure_config
    python3 - "$CONFIG_PATH" "$TARGET_SESSION" "$TARGET_WINDOW" "$TARGET_PANE_INDEX" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
session, window, pane_index = sys.argv[2:]
data = json.loads(path.read_text())
routes = data.get("routes", [])
updated = False
for route in routes:
    match = route.get("match", {})
    if (
        match.get("session") == session
        and match.get("window") == window
        and match.get("pane_index") == pane_index
    ):
        route["enabled"] = True
        updated = True
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
if not updated:
    sys.stderr.write("No route matched target\n")
    sys.exit(1)
PY
    echo "Enabled route for $target"
    ;;

  remove-route)
    shift
    target=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target)
          target="${2:-}"
          shift 2
          ;;
        *)
          echo "Unknown argument: $1" >&2
          usage
          exit 1
          ;;
      esac
    done
    [[ -n "$target" ]] || { echo "--target is required" >&2; exit 1; }
    parse_target "$target"
    ensure_config
    python3 - "$CONFIG_PATH" "$TARGET_SESSION" "$TARGET_WINDOW" "$TARGET_PANE_INDEX" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
session, window, pane_index = sys.argv[2:]
data = json.loads(path.read_text())
routes = data.get("routes", [])
data["routes"] = [
    r for r in routes
    if not (
        r.get("match", {}).get("session") == session
        and r.get("match", {}).get("window") == window
        and r.get("match", {}).get("pane_index") == pane_index
    )
]
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
    echo "Removed route for $target"
    ;;

  unbind-route)
    shift
    target=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target)
          target="${2:-}"
          shift 2
          ;;
        *)
          echo "Unknown argument: $1" >&2
          usage
          exit 1
          ;;
      esac
    done
    [[ -n "$target" ]] || { echo "--target is required" >&2; exit 1; }
    bash "$0" remove-route --target "$target"
    ;;

  ""|menu)
    menu
    ;;

  -h|--help|help)
    usage
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    usage
    exit 1
    ;;
esac
