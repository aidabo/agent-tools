#!/usr/bin/env python3
"""Review status board for the monitor session (monitor.sh).

Main part: cross-review (../cross-review/status.sh) — a GitHub-like PR list, one line
per PR with its review state, author → reviewers and verdicts. Refreshed every 20 s
because it calls the GitHub API.

Below it, one short line per tmux session with what each AI pane is doing, read from
the live pane screen: 作業中 (working) / 確認待ち (a dialog or permission prompt is
waiting for you) / 入力途中 (typed but not sent) / 待機 (idle). Detailed per-turn
notifications go to Discord (configure-stop-notify.sh), not here.

  status.py [--interval SEC] [--review-interval SEC] [--once]

Keys: r = refresh now, q = quit.
"""
from __future__ import annotations

import argparse
import os
import re
import select
import subprocess
import sys
import termios
import threading
import time
import tty
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
CROSS_REVIEW_STATUS = HERE.parent / "cross-review" / "status.sh"

RESET, BOLD, DIM = "\033[0m", "\033[1m", "\033[2m"
RED, GREEN, YELLOW, CYAN = "\033[31m", "\033[32m", "\033[33m", "\033[36m"

ANSI = re.compile(r"\x1b\[[0-9;]*m")
DIM_SPAN = re.compile(r"\x1b\[2m.*?(\x1b\[0m|\x1b\[22m|$)")
SPINNER_TITLE = re.compile(r"^[⠀-⣿]")          # braille spinner in the pane title
CLAUDE_SPINNER = re.compile(r"…\s*\((\d+[hms]\s*)+")     # Claude Code: "Thinking… (39s ·"
CHOICE = re.compile(r"^\d+\.\s")                          # "❯ 1. Yes" — permission / dialog choice

STATES = {
    "busy": ("作業中", CYAN),
    "attention": ("確認待ち", YELLOW + BOLD),
    "typing": ("入力途中", DIM),
    "idle": ("待機", GREEN),
}


# ── tmux / processes ─────────────────────────────────────────
def run(*cmd: str) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def process_children() -> dict[int, list[str]]:
    children: dict[int, list[str]] = {}
    for line in run("ps", "-eo", "pid=,ppid=,args=").splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1].isdigit():
            children.setdefault(int(parts[1]), []).append(parts[2])
    return children


def agent_of(shell_pid: int, children: dict[int, list[str]]) -> str:
    """Which AI CLI runs in the pane (same rules as cross-review/notify.sh)."""
    for args in children.get(shell_pid, []):
        if "claw/deepseek" in args:
            return "deepseek"
        if "bin/codex" in args:
            return "codex"
        if args == "claude" or args.startswith("claude "):
            return "claude"
    return ""


def classify(pane_id: str, title: str) -> str:
    raw = run("tmux", "capture-pane", "-e", "-p", "-t", pane_id).splitlines()
    plain = [ANSI.sub("", line) for line in raw]
    tail = "\n".join(plain[-12:])
    if SPINNER_TITLE.match(title) or "esc to interrupt" in tail or CLAUDE_SPINNER.search(tail):
        return "busy"
    idx = max((i for i, l in enumerate(plain) if l.lstrip().startswith(("›", "❯"))), default=-1)
    if idx < 0:
        return "attention"                       # no input box: a dialog is open
    text = ANSI.sub("", DIM_SPAN.sub("", raw[idx])).strip().lstrip("›❯").strip()
    if CHOICE.match(text):
        return "attention"
    return "typing" if text else "idle"


def current_session() -> str:
    pane = os.environ.get("TMUX_PANE")
    return run("tmux", "display-message", "-p", "-t", pane, "#S").strip() if pane else ""


def agent_lines() -> list[str]:
    """One line per session: "ThinkAI-Agents  1.1 deepseek 待機 · 1.3 codex 作業中"."""
    me = current_session()
    children = process_children()
    fmt = "#{session_name}\t#{window_index}.#{pane_index}\t#{pane_id}\t#{pane_pid}\t#{pane_title}"
    sessions: dict[str, list[str]] = {}
    for line in run("tmux", "list-panes", "-a", "-F", fmt).splitlines():
        parts = line.split("\t", 4)
        if len(parts) != 5 or parts[0] == me or not parts[3].isdigit():
            continue
        session, index, pane_id, pid, title = parts
        agent = agent_of(int(pid), children)
        if agent:
            label, color = STATES[classify(pane_id, title)]
            sessions.setdefault(session, []).append(f"{DIM}{index}{RESET} {agent} {color}{label}{RESET}")
    if not sessions:
        return [f"  {DIM}AI エージェントの pane がありません{RESET}"]
    return [f"  {session}  " + " · ".join(cells) for session, cells in sessions.items()]


class ReviewStatus:
    """cross-review/status.sh, run in the background so gh never blocks the board."""

    def __init__(self, interval: float):
        self.interval = interval
        self.lines: list[str] = [f"{DIM}cross-review: 読み込み中…{RESET}"]
        self.updated = 0.0
        self.lock = threading.Lock()
        self.wake = threading.Event()
        if CROSS_REVIEW_STATUS.is_file():
            threading.Thread(target=self.loop, daemon=True).start()
        else:
            self.lines = []

    def loop(self) -> None:
        while True:
            env = dict(os.environ, FORCE_COLOR="1", CR_MAX_LINES=str(review_lines_free()))
            try:
                res = subprocess.run(["bash", str(CROSS_REVIEW_STATUS)], capture_output=True, text=True,
                                     timeout=120, env=env)
                lines = (res.stdout or res.stderr).rstrip("\n").splitlines()
            except (OSError, subprocess.TimeoutExpired) as exc:
                lines = [f"{RED}cross-review: {exc}{RESET}"]
            with self.lock:
                self.lines, self.updated = lines, time.time()
            # while a review runs, refresh fast so its progress (current step, active/quiet) moves
            busy = any("IN REVIEW" in ANSI.sub("", line) for line in lines[1:])
            self.wake.wait(min(5.0, self.interval) if busy else self.interval)
            self.wake.clear()

    def render(self) -> list[str]:
        with self.lock:
            if not self.lines:
                return []
            stamp = f"  {DIM}({datetime.fromtimestamp(self.updated):%H:%M:%S} 更新){RESET}" if self.updated else ""
            return [self.lines[0] + stamp, *self.lines[1:]]


AGENT_ROWS = [1]   # agent lines in the last frame (the review list gets the rest of the height)


def review_lines_free() -> int:
    """Lines the cross-review part may use: the pane height minus the clock line, the blank line,
    the agent header and the agent rows."""
    rows = os.get_terminal_size().lines if sys.stdout.isatty() else 40
    return max(10, rows - 3 - AGENT_ROWS[0] - 1)


def frame(reviews: ReviewStatus) -> str:
    agents = agent_lines()
    AGENT_ROWS[0] = len(agents)
    return "\n".join([
        f"{DIM}{datetime.now():%H:%M:%S}   r: 更新  q: 終了  前のセッションへ: prefix + L{RESET}",
        *reviews.render(),
        "",
        f"{BOLD}エージェント{RESET}",
        *agents,
    ])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--interval", type=float, default=3.0, help="agent refresh seconds (default 3)")
    ap.add_argument("--review-interval", type=float, default=20.0, help="cross-review refresh seconds (default 20)")
    ap.add_argument("--once", action="store_true", help="print once and exit")
    args = ap.parse_args()

    if args.once:
        reviews = ReviewStatus(interval=1e9)
        deadline = time.time() + 30
        while not reviews.updated and reviews.lines and time.time() < deadline:
            time.sleep(0.1)
        print(frame(reviews))
        return 0

    reviews = ReviewStatus(args.review_interval)
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd) if sys.stdin.isatty() else None
    try:
        if saved:
            tty.setcbreak(fd)
        # alternate screen + overwrite in place: clearing with ESC[2J would push every frame into tmux scrollback
        sys.stdout.write("\033[?1049h\033[?25l")
        while True:
            body = "\n".join(line + "\033[K" for line in frame(reviews).split("\n"))
            sys.stdout.write("\033[H" + body + "\033[J")
            sys.stdout.flush()
            shown_review = reviews.updated
            deadline = time.time() + args.interval
            while time.time() < deadline:
                ready, _, _ = select.select([sys.stdin] if saved else [], [], [], 0.2)
                if ready:
                    # os.read, not sys.stdin.read: buffered stdin would keep arrow-key bytes that select can't see
                    keys = os.read(fd, 1024).decode(errors="ignore")
                    if "q" in keys or "Q" in keys:
                        return 0
                    if "r" in keys or "R" in keys:
                        reviews.wake.set()
                        break
                if reviews.updated != shown_review:          # new cross-review result: show it now
                    break
    except KeyboardInterrupt:
        return 0
    finally:
        sys.stdout.write("\033[?25h\033[?1049l")
        if saved:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    raise SystemExit(main())
