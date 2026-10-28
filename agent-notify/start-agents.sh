#!/usr/bin/env bash
# shellcheck disable=SC2312
set -euo pipefail

# ── Config & args ─────────────────────────────────────────────
force_new=false
# The hook-log monitor pane is opt-in (--monitor). By default every pane is a
# plain agent pane, one per entry in agents.yaml.
with_monitor=false
# Session name: argument > AGENTS_SESSION > `session:` in agents.yaml > "<workspace folder>-agents"
session="${AGENTS_SESSION:-}"

for arg in "$@"; do
  case "$arg" in
    --force)   force_new=true ;;
    --monitor) with_monitor=true ;;
    -*)      echo "Unknown flag: $arg" >&2; exit 1 ;;
    *)       session="$arg" ;;
  esac
done

script_dir="$(dirname "$(readlink -f "$0")")"

# Workspace = a folder holding several repos (e.g. ~/work/legacy), marked by its agents.yaml.
# Panes start there and notify state lives in <workspace>/.omx/notify-state.
# AGENTS_PROJECT_ROOT wins; otherwise the nearest folder at or above the current directory with an
# agents.yaml (so `yarn agents` in any repo of the workspace finds it); otherwise two levels above this script.
find_workspace() {
  local d
  d="$(pwd)"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/agents.yaml" && "$d" != "$script_dir" ]]; then echo "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}
if [[ -n "${AGENTS_PROJECT_ROOT:-}" ]]; then
  repo_root="$(cd "$AGENTS_PROJECT_ROOT" && pwd)"
else
  repo_root="$(find_workspace || { cd "$script_dir/../.." && pwd; })"
fi
# Pane list: AGENTS_YAML, else <workspace>/agents.yaml, else the one next to this script.
agents_yaml="${AGENTS_YAML:-$repo_root/agents.yaml}"
[[ -n "${AGENTS_YAML:-}" || -f "$agents_yaml" ]] || agents_yaml="$script_dir/agents.yaml"
monitor_script="$script_dir/monitor-hook-log.py"
notify_config_script="$script_dir/configure-stop-notify.sh"
notify_state_root="$repo_root/.omx/notify-state"
hook_log="$notify_state_root/hook-invocations.log"

# ── Prerequisites ─────────────────────────────────────────────
if ! command -v tmux >/dev/null 2>&1; then
  echo "[start-agents] tmux is required but was not found in PATH." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[start-agents] python3 is required but was not found in PATH." >&2
  exit 1
fi
if [[ ! -f "$agents_yaml" ]]; then
  echo "[start-agents] Missing agents.yaml: $agents_yaml" >&2
  exit 1
fi
if [[ "$with_monitor" == "true" && ! -f "$monitor_script" ]]; then
  echo "[start-agents] Missing monitor script: $monitor_script" >&2
  exit 1
fi
if [[ ! -f "$notify_config_script" ]]; then
  echo "[start-agents] Missing notify config script: $notify_config_script" >&2
  exit 1
fi

# ── Parse agents.yaml via embedded python3 ────────────────────
# Returns agent config as tab-separated lines: name<TAB>role<TAB>brief
# Prints "N=<count>" first, then one line per agent.
parse_agents() {
  python3 - "$agents_yaml" <<'PYEOF'
import sys
from pathlib import Path

yaml_path = Path(sys.argv[1])
raw = yaml_path.read_text(encoding="utf-8")

data = {"agents": []}

# Try safe yaml load first; if unavailable, use a basic line-based parser
try:
    import yaml  # type: ignore[import-untyped]
    data = yaml.safe_load(raw)
except ImportError:
    lines = raw.splitlines()
    current_agent = None
    in_brief = False
    brief_lines = []

    for line in lines:
        stripped = line.strip()

        # Skip comments and blank lines
        if stripped.startswith("#"):
            continue
        if not stripped:
            # Blank line: flush current agent if we are collecting brief
            if current_agent is not None and in_brief and brief_lines:
                current_agent["brief"] = "\n".join(brief_lines).strip()
                data["agents"].append(current_agent)
                current_agent = None
                in_brief = False
                brief_lines = []
            elif current_agent is not None and not in_brief:
                # Could still be inside a block scalar (|---) — harmless no-op
                pass
            continue

        # Detect indentation level on first meaningful content
        if stripped == "agents:":
            continue

        # Top-level session name (not indented)
        if line.startswith("session:"):
            data["session"] = stripped.split(":", 1)[1].strip().strip('"').strip("'")
            continue

        # New agent entry
        if stripped.startswith("- name:"):
            # Flush previous agent
            if current_agent is not None:
                if brief_lines:
                    current_agent["brief"] = "\n".join(brief_lines).strip()
                data["agents"].append(current_agent)
            current_agent = {
                "name": stripped.split(":", 1)[1].strip(),
                "role": "",
                "brief": "",
            }
            in_brief = False
            brief_lines = []
            continue

        if current_agent is None:
            continue

        # cli / command fields (which AI CLI to start in the pane)
        if stripped.startswith("cli:") or stripped.startswith("command:"):
            key, val = stripped.split(":", 1)
            current_agent[key] = val.strip().strip('"').strip("'")
            in_brief = False
            continue

        # role field
        if stripped.startswith("role:"):
            current_agent["role"] = stripped.split(":", 1)[1].strip()
            in_brief = False
            continue

        # brief field
        if stripped.startswith("brief:") or stripped.startswith("brief >-"):
            in_brief = True
            brief_lines = []
            val = stripped.split(":", 1)[1].strip()
            # val might be "|" (literal block) or ">-" (folded block) or empty (inline value on next line)
            if val and val not in ("|", ">-", ">"):
                brief_lines.append(val)
                in_brief = False
            continue

        # Collect brief body lines
        if in_brief:
            # A new top-level key terminates the brief
            if ":" in stripped and not stripped.startswith("-") and not stripped.startswith("#"):
                in_brief = False
                current_agent["brief"] = "\n".join(brief_lines).strip()
                data["agents"].append(current_agent)
                current_agent = None
                brief_lines = []
                continue
            brief_lines.append(stripped)
            continue

    # Flush last agent
    if current_agent is not None:
        if brief_lines:
            current_agent["brief"] = "\n".join(brief_lines).strip()
        data["agents"].append(current_agent)

if not data or "agents" not in data or not data["agents"]:
    print("N=0")
    sys.exit(0)

agents = data["agents"]
print(f"N={len(agents)}")
print("\x1e".join(["S", str(data.get("session") or "").strip()]))
for a in agents:
    name = a.get("name", "agent").strip()
    role = str(a.get("role") or a.get("cli") or name).strip()
    brief = a.get("brief", "").strip()
    # Encode newlines as \x1f for safe transport over pipe
    encoded = brief.replace("\n", "\x1f")
    cli = str(a.get("cli", "") or "").strip()
    command = str(a.get("command", "") or "").strip()
    # \x1e (record separator) between fields: bash `read` collapses consecutive tabs
    # (tab is IFS whitespace), so an empty brief would shift cli/command into the wrong field.
    print("\x1e".join(["A", name, role, encoded, cli, command]))
PYEOF
}

# Collect parsed output into a temp file so we don't lose it in a pipe subshell
parsed_file="$(mktemp)"
trap 'rm -f "$parsed_file"' EXIT

parse_agents > "$parsed_file" 2>/dev/null || {
  echo "[start-agents] Failed to parse $agents_yaml." >&2
  exit 1
}

first_line="$(head -1 "$parsed_file")"
N="${first_line#N=}"

if [[ -z "$session" ]]; then
  session="$(awk -F $'\x1e' '$1 == "S" { print $2 }' "$parsed_file")"
fi
if [[ -z "$session" ]]; then
  # tmux session names can't contain "." or ":"
  session="$(basename "$repo_root" | tr '.:' '__')-agents"
fi

if [[ -z "$N" || "$N" -eq 0 ]]; then
  echo "[start-agents] No agents defined in $agents_yaml." >&2
  exit 1
fi

expected_panes="$N"
[[ "$with_monitor" == "true" ]] && expected_panes="$((N + 1))"
echo "[start-agents] Found $N agent(s), expecting $expected_panes pane(s)."

# ── Re-attach check ───────────────────────────────────────────
if [[ "$force_new" != "true" ]] && tmux has-session -t "$session" 2>/dev/null; then
  pane_count="$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$pane_count" == "$expected_panes" ]]; then
    echo "[start-agents] Session '$session' exists with $pane_count pane(s). Attaching."
    bash "$script_dir/monitor.sh" --detach || true
    tmux attach -t "$session"
    exit 0
  fi
  echo "[start-agents] Session '$session' has $pane_count pane(s) (expected $expected_panes). Creating new session."
fi

launch_session="$session"
if tmux has-session -t "$session" 2>/dev/null; then
  launch_session="${session}-$(date +%Y%m%d%H%M%S)"
fi

# ── Helper: capture pane ID with retry ────────────────────────
capture_pane_id() {
  local target="$1"
  local pane_id=""
  for _ in 1 2 3; do
    pane_id="$(tmux display-message -p -t "$target" -F '#{pane_id}' 2>/dev/null || true)"
    if [[ -n "$pane_id" ]]; then
      echo "$pane_id"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# ── Helper: wait until shell is ready (prompt visible) ────────
wait_until_shell_ready() {
  local target="$1"
  local max_wait=50  # 5 seconds (50 * 100ms)
  local i=0
  while [[ $i -lt $max_wait ]]; do
    local cap
    cap="$(tmux capture-pane -p -t "$target" 2>/dev/null | tail -5 || true)"
    # Common prompt-ending characters: $ # > % ] (e.g., $, # for root, > for python/PSQL, ] for irb/fish, % for zsh)
    if echo "$cap" | grep -qE '[$#>%]|]\s*$'; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# ── Helper: build identity env-var export string ──────────────
build_identity_export() {
  local session_name="$1"
  local role="$2"
  local target="$3"
  local pane_id="$4"
  local title="$5"
  local window_index="${target#*:}"
  local pane_index="${target##*.}"
  window_index="${window_index%%.*}"

  printf 'export CLAWHIP_NOTIFY_SESSION=%q CLAWHIP_NOTIFY_PANE_ROLE=%q CLAWHIP_NOTIFY_PANE_TARGET=%q CLAWHIP_NOTIFY_PANE_ID=%q CLAWHIP_NOTIFY_PANE_TITLE=%q CLAWHIP_NOTIFY_WINDOW_INDEX=%q CLAWHIP_NOTIFY_PANE_INDEX=%q CLAWHIP_NOTIFY_STATE_ROOT=%q CLAWHIP_NOTIFY_PROJECT_ROOT=%q' \
    "$session_name" "$role" "$target" "$pane_id" "$title" "$window_index" "$pane_index" "$notify_state_root" "$repo_root"
}

# ── Cleanup helper ────────────────────────────────────────────
cleanup_and_exit() {
  echo "[start-agents] ERROR: $1" >&2
  if tmux has-session -t "$launch_session" 2>/dev/null; then
    tmux kill-session -t "$launch_session" 2>/dev/null || true
  fi
  exit 1
}

# ── Load agent config into arrays ─────────────────────────────
declare -a AGENT_NAMES=()
declare -a AGENT_ROLES=()
declare -a AGENT_BRIEFS=()
declare -a AGENT_CLIS=()
declare -a AGENT_COMMANDS=()

while IFS=$'\x1e' read -r tag name role brief_encoded cli command; do
  [[ "$tag" != "A" ]] && continue
  AGENT_NAMES+=("$name")
  AGENT_ROLES+=("$role")
  # Restore newlines from \x1f encoding
  brief_decoded="${brief_encoded//$'\x1f'/$'\n'}"
  AGENT_BRIEFS+=("$brief_decoded")
  AGENT_CLIS+=("$cli")
  AGENT_COMMANDS+=("$command")
done < <(tail -n +2 "$parsed_file")

# ── Create tmux session ───────────────────────────────────────
echo "[start-agents] Creating session: $launch_session"
tmux new-session -d -s "$launch_session" -n agents -c "$repo_root" || cleanup_and_exit "Failed to create session"

# ── Enable pane status bar showing agent name — role ─────────
# Shows agent identity as a one-line bar at the top of each pane border.
tmux set-window-option -t "$launch_session" pane-border-status top 2>/dev/null || true
tmux set-window-option -t "$launch_session" pane-border-format '#{pane_title}  (#{session_name}:#{window_index}.#{pane_index} #{pane_id})' 2>/dev/null || true

# ── Build pane layout ─────────────────────────────────────────
# One pane per agent, plus a monitor pane when --monitor is given.
# 2 panes side by side; 3+ panes tiled (4 → 2x2 grid).

declare -a AGENT_PANE_IDS=()
declare -a AGENT_TARGETS=()
monitor_pane_id=""

# The first pane already exists from new-session
first_pane_id="$(capture_pane_id "$launch_session" 2>/dev/null || true)"
if [[ -z "$first_pane_id" ]]; then
  cleanup_and_exit "Could not capture first pane ID"
fi
AGENT_PANE_IDS+=("$first_pane_id")

for ((i = 2; i <= N; i++)); do
  next_id="$(tmux split-window -h -P -F '#{pane_id}' -t "${AGENT_PANE_IDS[-1]}" -c "$repo_root" 2>/dev/null || true)"
  if [[ -z "$next_id" ]]; then
    cleanup_and_exit "Failed to create pane for agent $i"
  fi
  AGENT_PANE_IDS+=("$next_id")
  # Re-tile after each split so the next split has room.
  tmux select-layout -t "$launch_session" tiled >/dev/null 2>&1 || true
done

if [[ "$with_monitor" == "true" ]]; then
  monitor_pane_id="$(tmux split-window -v -P -F '#{pane_id}' -t "${AGENT_PANE_IDS[-1]}" -c "$repo_root" 2>/dev/null || true)"
  if [[ -z "$monitor_pane_id" ]]; then
    cleanup_and_exit "Failed to create monitor pane"
  fi
fi

if [[ "$expected_panes" -eq 2 ]]; then
  tmux select-layout -t "$launch_session" even-horizontal
elif [[ "$expected_panes" -ge 3 ]]; then
  tmux select-layout -t "$launch_session" tiled
fi

# ── Configure each agent pane ─────────────────────────────────
for agent_idx in "${!AGENT_NAMES[@]}"; do
  name="${AGENT_NAMES[$agent_idx]}"
  role="${AGENT_ROLES[$agent_idx]}"
  brief="${AGENT_BRIEFS[$agent_idx]}"
  pane_id="${AGENT_PANE_IDS[$agent_idx]:-}"

  if [[ -z "$pane_id" ]]; then
    echo "[start-agents] WARNING: no pane for agent '$name' (index $agent_idx)" >&2
    continue
  fi

  # Set pane title (displayed in the pane border status bar)
  pane_title="$name — $role"
  tmux select-pane -t "$pane_id" -T "$pane_title" 2>/dev/null || true

  # Wait for shell to be ready
  wait_until_shell_ready "$pane_id" || echo "[start-agents] WARNING: shell not ready in '$name' pane" >&2

  # Capture target
  target="$(tmux display-message -p -t "$pane_id" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)"
  AGENT_TARGETS+=("$target")

  # Export identity env vars (before `clear`, so the long export line doesn't stay on screen)
  identity_export="$(build_identity_export "$launch_session" "$role" "$target" "$pane_id" "$name")"
  tmux send-keys -t "$pane_id" "$identity_export" C-m

  # ── Resolve the AI CLI (agents.yaml `cli:`) ────────────────
  # cross-review（~/work/legacy/10-agent-tools/cross-review/PROTOCOL.md）は CROSS_REVIEW_AGENT で
  # 自分の名前を知る。CLI は起動時に CLAUDE.md / AGENTS.md を読むので、ここで起動すれば最初から有効。
  cli="${AGENT_CLIS[$agent_idx]:-}"
  command="${AGENT_COMMANDS[$agent_idx]:-}"
  if [[ -z "$command" ]]; then
    case "$cli" in
      claude)   command="claude" ;;
      codex)    command="codex" ;;
      deepseek) command="bash $HOME/claw/deepseek" ;;
      ""|none)  command="" ;;
      *)        echo "[start-agents] WARNING: unknown cli '$cli' for '$name' — leaving a plain shell" >&2 ;;
    esac
  fi
  if [[ -n "$cli" && "$cli" != none ]]; then
    tmux send-keys -t "$pane_id" "export CROSS_REVIEW_AGENT=$(printf '%q' "$cli")" C-m
  fi

  # Clear and display brief (only when agents.yaml gives one)
  tmux send-keys -t "$pane_id" "clear" C-m
  sleep 0.1
  if [[ -n "$brief" ]]; then
  tmux send-keys -t "$pane_id" "printf '%s\n' '=== $name ($role) ==='" C-m

  # Send brief line-by-line (printf handles special chars)
  while IFS= read -r bline; do
    if [[ -z "$bline" ]]; then
      tmux send-keys -t "$pane_id" "" C-m
    else
      # Escape single quotes for shell
      escaped="${bline//\'/\'\\\'\'}"
      tmux send-keys -t "$pane_id" "printf '%s\n' '$escaped'" C-m
    fi
  done <<< "$brief"

  tmux send-keys -t "$pane_id" "printf '%s\n' '' '$name ready.'" C-m
  fi

  if [[ -n "$command" ]]; then
    tmux send-keys -t "$pane_id" "$command" C-m
    echo "[start-agents] Started '$command' in '$name'"
  fi

  echo "[start-agents] Configured pane $pane_id as '$name' (target: $target)"
done

# ── Start monitor in the dedicated monitor pane (--monitor only) ─
if [[ -n "$monitor_pane_id" ]]; then
  monitor_pane_title="monitor"
  tmux select-pane -t "$monitor_pane_id" -T "$monitor_pane_title" 2>/dev/null || true
  wait_until_shell_ready "$monitor_pane_id" || echo "[start-agents] WARNING: shell not ready in monitor pane" >&2
  tmux send-keys -t "$monitor_pane_id" "clear" C-m
  sleep 0.1
  tmux send-keys -t "$monitor_pane_id" "python3 '$monitor_script' '$repo_root' '$hook_log'" C-m
  echo "[start-agents] Started monitor in pane $monitor_pane_id"
fi

# ── Auto-bind stop-notify routes for all agent panes ──────────
if [[ -f "$HOME/.notify/stop-notify.json" && -f "$HOME/.notify/stop-notify.env" ]]; then
  for i in "${!AGENT_NAMES[@]}"; do
    target="${AGENT_TARGETS[$i]:-}"
    pane_id="${AGENT_PANE_IDS[$i]:-}"
    name="${AGENT_NAMES[$i]}"
    agent_num=$((i + 1))

    [[ -z "$target" ]] && continue

    webhook_env="DISCORD_WEBHOOK_URL_AGENT${agent_num}"
    # Only bind if the env var is set (or if it could be in the env file)
    if [[ -v "$webhook_env" ]] || grep -q "^${webhook_env}=" "$HOME/.notify/stop-notify.env" 2>/dev/null; then
      bash "$notify_config_script" set-route --target "$target" --webhook-env "$webhook_env" --title "$name" --pane-id "$pane_id" 2>/dev/null || true
      echo "[start-agents] Bound route for '$name': $target -> $webhook_env"
    else
      echo "[start-agents] SKIP route for '$name': $webhook_env not set (set it with configure-stop-notify.sh set-webhook)"
    fi
  done
else
  echo "[start-agents] SKIP route binding: $HOME/.notify/stop-notify.{json,env} not found"
fi

# ── Status board in its own session (monitor.sh; switch to it when you want to look) ─
bash "$script_dir/monitor.sh" --detach || true

# ── Attach ────────────────────────────────────────────────────
echo "[start-agents] Attaching to session '$launch_session'."
tmux attach -t "$launch_session"
