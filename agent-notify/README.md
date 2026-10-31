# Stop-notify assets

Repo-managed notification assets for tmux -> Discord stop notifications.

## Layout

- `configure-stop-notify.sh` — setup / install / preview menu
- `hooks/native-hook.mjs` — stop hook payload formatter and sender
- `stop-notify.example.json` — sample route configuration
- `stop-notify.env.example` — sample env file for webhook URLs

## Agent launcher (`start-agents.sh`, `yarn agents`)

- one tmux pane per agent in `agents.yaml` (4 agents → 2x2 grid); add or edit entries there to change the panes
- every pane is a plain shell with the identity env (`CLAWHIP_NOTIFY_*`) exported — start any AI agent in it
- `cli: claude|codex|deepseek|none` in `agents.yaml` starts that CLI in the pane automatically and exports `CROSS_REVIEW_AGENT=<cli>` for cross-review (`command:` overrides the launch command); `none` leaves a plain shell
- `deepseek` has no fixed path: the pane's shell resolves it from `PATH` (`~/.bashrc` etc.). If it is not on `PATH`, `export DEEPSEEK_LAUNCHER=/path/to/deepseek` before starting the panes (`config.local.sh` is read by cross-review only, not by the launcher)
- the hook-log monitor pane is off by default; `start-agents.sh --monitor` adds it back as an extra pane
- an existing session with the expected pane count is re-attached; `--force` always starts a new one
- workspaces: a workspace is a folder holding several repos (backend, frontend, …), like `~/work/legacy`. Put an `agents.yaml` at its root; `yarn agents` run from any repo inside it walks up, finds that file, starts the panes in the workspace root and keeps notify state in `<workspace>/.omx/notify-state`. Without one, it falls back to two levels above this script and the `agents.yaml` here
- session name: first argument > `AGENTS_SESSION` > `session:` in `agents.yaml` > `<workspace folder>-agents`, so two workspaces can run side by side
- overrides: `AGENTS_PROJECT_ROOT=/path` (workspace root), `AGENTS_YAML=/path/agents.yaml`
- new workspace: `cp agents.yaml ~/work/<workspace>/agents.yaml`, edit the panes, and add `"agents": "bash <path to>/agent-notify/start-agents.sh"` to each repo's package.json (or just run that command from inside the workspace)

## Status board (`monitor.sh`, `status.py`)

A separate tmux session, `agents-monitor`, shows the cross-review status and what each agent is doing — so the work panes stay clean and you look only when you want to. Detailed per-turn notifications go to Discord (stop-notify), not here.

- one board for all workspaces: it lists every tmux session that has AI panes, and cross-review covers every repo in its config
- `start-agents.sh` creates it in the background; `monitor.sh` (`yarn monitor` in a repo whose package.json has `"monitor": "bash <path to>/agent-notify/monitor.sh"`) creates it if missing and switches to it — inside tmux it switches the client, outside it attaches. `prefix + L` takes you back
- main part: the cross-review PR list (`../cross-review/status.sh`) — one line per PR like GitHub: state (WAITING / IN REVIEW / CHANGES REQUESTED / REVIEWED / APPROVED, then recently MERGED / CLOSED), title, author → reviewers with verdicts; refreshed every 20 s, `r` refreshes now, `q` closes the board
- it draws on the alternate screen, so old frames never pile up in tmux scrollback
- the lower pane, "review — live" (`../cross-review/live.sh`), follows reviews as they happen: each cron pass (which PR, tests, review start, done, comment posted, author notified) and every step of a running review (tool calls, what it writes, refused calls). Reviews themselves run from cron, so closing the pane doesn't stop them
- below that, one line per session with each AI pane (claude / codex / deepseek, found from the pane's processes): 作業中 / 確認待ち (dialog or permission prompt) / 入力途中 / 待機
- `python3 status.py --once` prints the board once; `AGENTS_MONITOR_SESSION` changes the session name

## Turning Discord off / on

`"enabled": false` in the `default` block of `~/.notify/stop-notify.json` stops every route that doesn't set its own
`enabled` (routes registered by `start-agents.sh` don't), so nothing is sent while the hooks keep running.
Set it back to `true` (or remove it) to send again. `doctor` shows such routes as `[DISABLED]`.

## Common actions

- `install` — copy the assets into `~/.notify`
- `disable-route --target SESSION:WINDOW.PANE_INDEX` — keep the binding but stop notifications
- `enable-route --target SESSION:WINDOW.PANE_INDEX` — re-enable a disabled binding
- `unbind-route --target SESSION:WINDOW.PANE_INDEX` — remove the binding entirely
- `clear` / `clear-routes` — remove all configured pane routes and keep only the `default` block
- `rebind-route --target SESSION:WINDOW.PANE_INDEX ...` — update target, webhook env, title, or mention in one step
- `set-current-route` / menu item `rebind current route` — update the current pane binding after a pane rename or webhook change
- `target-menu [--target SESSION:WINDOW.PANE_INDEX]` — compact target menu for rebind / disable / enable / unbind / clear actions
- main menu now routes `current` and `target` into dedicated submenus
- main menu includes `clear` to wipe all route entries while keeping defaults
- submenu `0/b` returns to the main menu instead of exiting
- `title` is a separate main-menu flow that lists panes with the active pane first and shows the current pane, then prompts for a new name
- target format is shown as `session:window.pane_index` with concrete examples like `omx-session:0.0`
- `doctor` prints a target-format reminder line before listing routes
- `doctor` also prints a concrete target example line for easier copy/paste
- `doctor` route lines keep `target=...` but also note `session:window.pane_index`
- `sendtmux.sh` is the local helper OpenClaw should call when it sees an `st ...` command
- `openclaw-sendtmux-rule.txt` contains a copy-paste rule for OpenClaw console setup
- `sendtmux.sh` uses a brief delay before Enter, configurable with `SENDTMUX_DELAY_SECONDS`
- runtime stop-hook state is stored under `~/.notify/state/` per pane:
  - `prompt-submit/<session>.<window>.<pane>.json` — UserPromptSubmit records (includes `first_prompt_excerpt` / `first_prompt_summary` on first turn)
  - `prompt-boundary/<session>.<window>.<pane>.json` — boundary markers for conversation start anchoring (includes `first_prompt_excerpt` / `first_prompt_summary`)
  - `pane-output/<session>.<window>.<pane>.diff` — raw tmux pane capture on stop
- hook invocation logging is appended to `~/.notify/state/hook-invocations.log`
- if a stop event arrives without direct tmux metadata, the hook falls back to the newest matching `prompt-submit` state before it gives up
- when a launcher exports stable pane identity variables, the hook prefers those first:
  - `CLAWHIP_NOTIFY_SESSION`
  - `CLAWHIP_NOTIFY_PANE_ROLE`
  - `CLAWHIP_NOTIFY_PANE_TARGET`
  - `CLAWHIP_NOTIFY_PANE_ID`
  - `CLAWHIP_NOTIFY_PANE_TITLE`
  - `CLAWHIP_NOTIFY_WINDOW_INDEX`
  - `CLAWHIP_NOTIFY_PANE_INDEX`
- for sandboxed or split-process runs, set `CLAWHIP_NOTIFY_PROJECT_ROOT` to the repo checkout path and keep `CLAWHIP_NOTIFY_STATE_ROOT` under `.../.omx/notify-state`
- `doctor` warns when the shell env root and the env-file root differ, and it also reports whether the shared state directory exists and is writable
- native hook logs now include `project_root`, `state_root`, `repo_root`, and `worktree_root` so a monitor pane can see exactly which checkout is active
- the hook log also includes `pane_role` when the launcher exports it
- stop notifications queue Discord delivery to a detached background worker under `~/.notify/state/discord-dispatch/` so the tmux stop event can return immediately
- the Stop hook itself also queues a detached stop worker under `~/.notify/state/stop-dispatch/` before any tmux capture/slicing work, so Codex does not wait on capture or webhook formatting
- the detached worker is a short-lived Node OS process started per stop event, not a long-lived daemon
- the default Discord chunk size is `3200`; override it with `CLAWHIP_NOTIFY_CHUNK_SIZE`
- the default tmux settle delay before Stop capture is `400ms`; override it with `CLAWHIP_STOP_CAPTURE_DELAY_MS`
- the chunk size is measured as plain text before Discord payload wrapping, so keep it below the 4000-character limit with some headroom
- stop output now captures the **full current conversation** (all turns), not just the last assistant response
- the hook saves `first_prompt_excerpt` and `first_prompt_summary` in the prompt-boundary state on the first `UserPromptSubmit` of each conversation session; subsequent turns preserve these fields
- on stop, `extractConversationTail` first tries to find the FIRST `› ...` user prompt line that matches `first_prompt_excerpt` and returns all content from that point forward — this covers the entire conversation from start to stop
- when `first_prompt_excerpt` is available, the capture window is doubled (up to 5000 lines) to ensure long conversations are fully contained
- the prompt line matching now strips trailing ellipsis (`...` / `…`) before comparison, fixing cases where long prompts are elided at the terminal width
- if the first-prompt anchor succeeds, all turns (user prompts and assistant replies) are included; boilerplate filtering still removes hook markers, `›` prompt lines, context counters, and status lines
- if the first-prompt anchor is not available (legacy state, or the conversation was too long for the capture window), the hook falls back to the last prompt (`prompt_excerpt`) and after that to visible boundary markers (`UserPromptSubmit`, `**Assistant**`), and finally to a bounded 120-line tail
- `UserPromptSubmit` writes a prompt-boundary marker under `~/.notify/state/prompt-boundary/` so the stop hook can anchor to the most recent send event directly
- when this repo-managed hook is wired only for `UserPromptSubmit` and `Stop`, the `UserPromptSubmit` path records state and exits cleanly without trying to launch the separate OMX bridge itself
- stop messages are sent as Discord markdown chunks; prose stays plain, and diff-like sections are wrapped in `diff` fences for syntax color
- capture uses the launcher-exported `session:window.pane_index` as the primary target and keeps the exported pane ID as a fallback and route guard
- if tmux metadata is missing or pane capture fails, the hook exits without sending a Discord message
- if the captured pane tail is empty after prompt/status/boilerplate cleanup, the hook exits without sending a Discord message
- per-agent webhook env names should follow the launcher rule:
  - `DISCORD_WEBHOOK_URL_AGENT1`
  - `DISCORD_WEBHOOK_URL_AGENT2`
  - if a specific agent env is missing, the hook falls back to `DISCORD_WEBHOOK_URL`

## Execution model

```text
tmux Stop event
  -> native-hook.mjs
  -> capture tmux output
  -> write dispatch job under ~/.notify/state/discord-dispatch/
  -> spawn detached Node worker
  -> return immediately

detached worker
  -> read job file
  -> curl Discord webhook
  -> write dispatch.log
  -> exit
```

## CLI configuration examples

The `config` main-menu item is read-only; use command-line subcommands to change settings:

```bash
./configure-stop-notify.sh set-webhook --env-name DISCORD_WEBHOOK_URL_PANE1 --url https://discord.com/api/webhooks/...
./configure-stop-notify.sh set-route --target omx-session:0.1 --webhook-env DISCORD_WEBHOOK_URL_PANE1 --title worker1
./configure-stop-notify.sh rebind-route --target omx-session:0.1 --webhook-env DISCORD_WEBHOOK_URL_PANE1 --title worker1 --mention @worker
./configure-stop-notify.sh disable-route --target omx-session:0.1
./configure-stop-notify.sh enable-route --target omx-session:0.1
./configure-stop-notify.sh unbind-route --target omx-session:0.1
./configure-stop-notify.sh clear
```

## Canonical install target

`$HOME/.notify`

The install menu copies the repo-managed assets into `~/.notify` and can keep
compatibility symlinks under `~/.clawhip` if needed.
