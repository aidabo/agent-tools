#!/usr/bin/env python3
"""Live review feed for the review pane of the monitor session. Called by live.sh, which passes the config.

Follows, as they grow:
  - the watch log (each cron pass: which PR, tests, reviewing, done, posted, notified),
    without the "already reviewed / nothing to do" lines every pass writes for unchanged PRs
  - <review worktree>/.cross-review/tests.log while tests run
  - <review worktree>/.cross-review/<reviewer>.events.jsonl — every step the reviewer takes:
    ▸ a tool call (Read / Grep / git diff …), ✎ what it writes, ⚠ a refused call, ✓ when it finishes
"""
from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

COLOR = not os.environ.get("NO_COLOR")
RESET, BOLD, DIM = ("\033[0m", "\033[1m", "\033[2m") if COLOR else ("", "", "")
RED, GREEN, YELLOW, CYAN = ("\033[31m", "\033[32m", "\033[33m", "\033[36m") if COLOR else ("", "", "", "")


def out(text: str) -> None:
    print(f"{DIM}{datetime.now():%H:%M:%S}{RESET} {text}", flush=True)


class Follow:
    """New complete lines of a file since the last call; starts over when the file is replaced or truncated."""

    def __init__(self, path: Path, from_end: bool):
        self.path, self.ino, self.pos, self.buf = path, None, 0, ""
        if from_end and path.exists():
            st = path.stat()
            self.ino, self.pos = st.st_ino, st.st_size

    def lines(self) -> list[str]:
        try:
            st = self.path.stat()
        except OSError:
            return []
        if st.st_ino != self.ino or st.st_size < self.pos:
            self.ino, self.pos, self.buf = st.st_ino, 0, ""
        if st.st_size == self.pos:
            return []
        with self.path.open("rb") as fh:
            fh.seek(self.pos)
            data = fh.read()
        self.pos += len(data)
        text = self.buf + data.decode("utf-8", "replace")
        *done, self.buf = text.split("\n")
        return done


def one_line(s: str, n: int = 110) -> str:
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


def rel(path: str, wt: str) -> str:
    return path[len(wt) + 1:] if wt and path.startswith(wt + "/") else path


def render_event(who: str, e: dict, wt: str, started: dict) -> list[str]:
    tag = f"{CYAN}{who:<8}{RESET}"
    rows: list[str] = []
    t = e.get("type")
    if t == "system" and e.get("subtype") == "init":
        started[who] = time.time()
        tools = e.get("tools") or []
        # locked down it is Read/Grep/Glob/Bash; a long list means the lockdown did not apply
        names = ", ".join(tools) if len(tools) <= 8 else f"{YELLOW}{len(tools)} tools (not locked down?){RESET}"
        rows.append(f"{tag} started · {names}")
    elif t == "assistant":                                                    # claude
        for part in (e.get("message") or {}).get("content") or []:
            if part.get("type") == "tool_use":
                inp = part.get("input") or {}
                arg = rel(inp.get("file_path") or "", wt) or inp.get("pattern") or inp.get("command") or ""
                rows.append(f"{tag} ▸ {part.get('name')} {one_line(arg, 90)}")
            elif part.get("type") == "text" and part.get("text", "").strip():
                rows.append(f"{tag} {DIM}✎ {one_line(part['text'])}{RESET}")
    elif t == "user":
        for part in (e.get("message") or {}).get("content") or []:
            if isinstance(part, dict) and part.get("is_error"):
                body = part.get("content") if isinstance(part.get("content"), str) else json.dumps(part.get("content"))
                rows.append(f"{tag} {YELLOW}⚠ {one_line(body, 100)}{RESET}")
    elif t == "result":
        took = f" in {int(time.time() - started.get(who, time.time()))}s" if who in started else ""
        ok = e.get("subtype") == "success"
        rows.append(f"{tag} {GREEN + '✓ finished' if ok else RED + '✗ ' + str(e.get('subtype'))}{took}{RESET}")
    item = e.get("item") or {}                                                 # codex
    if t == "item.started" and item.get("type") == "command_execution":
        rows.append(f"{tag} ▸ $ {one_line(item.get('command', ''), 100)}")
    elif t == "item.completed" and item.get("type") == "agent_message":
        rows.append(f"{tag} {DIM}✎ {one_line(item.get('text', ''))}{RESET}")
    elif t == "turn.completed":
        rows.append(f"{tag} {GREEN}✓ finished{RESET}")
    return rows


class LogFilter:
    """Drop the per-pass noise for PRs that are already reviewed; color the steps that matter."""

    def __init__(self):
        self.pending = ""

    def feed(self, line: str) -> list[str]:
        if not line.strip():
            return []
        if "] PR #" in line and "head=" in line:          # wait: is it followed by "already reviewed"?
            held, self.pending = self.pending, line
            return [held] if held else []
        if "already reviewed" in line or "nothing to do" in line:
            self.pending = ""
            return []
        held, self.pending = self.pending, ""
        color = (RED if ("FAILED" in line or "failed" in line or "error" in line.lower() or "secret scan" in line) else
                 GREEN if ("done:" in line or "posted" in line or "通知しました" in line) else
                 BOLD if "reviewing with" in line else "")
        return ([held] if held else []) + [f"{color}{line}{RESET}" if color else line]


def main() -> int:
    log = Path(os.environ.get("CR_LOG", str(Path.home() / ".cache/cross-review/watch.log")))
    wts = [l.split("|", 1) for l in os.environ.get("CR_WTS", "").splitlines() if "|" in l]

    print(f"{BOLD}review — live{RESET}  {DIM}(each cron pass and every step of a running review){RESET}", flush=True)
    # recent history first (last reviews), then follow
    filt = LogFilter()
    try:
        recent = log.read_text(encoding="utf-8", errors="replace").splitlines()[-400:]
    except OSError:
        recent = []
    shown = [r for line in recent for r in filt.feed(line)][-12:]
    for line in shown:
        print(f"{DIM}  {line}{RESET}" if COLOR else f"  {line}", flush=True)
    print(f"{DIM}── following ──{RESET}", flush=True)

    log_f = Follow(log, from_end=True)
    work = {name: Path(wt) / ".cross-review" for name, wt in wts}
    tests_f = {name: Follow(d / "tests.log", from_end=True) for name, d in work.items()}
    event_f: dict[Path, Follow] = {}
    started: dict[str, float] = {}
    while True:
        for line in log_f.lines():
            for row in filt.feed(line):
                out(row)
        for name, d in work.items():
            for line in tests_f[name].lines():
                if line.strip():
                    out(f"{DIM}tests    │ {one_line(line, 120)}{RESET}")
            for ev in sorted(d.glob("*.events.jsonl")):
                if ev not in event_f:
                    # a file that appeared after we started is a new review: read it from the top
                    event_f[ev] = Follow(ev, from_end=ev.stat().st_mtime < START)
                who = ev.name.split(".")[0]
                for line in event_f[ev].lines():
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    for row in render_event(who, e, str(Path(d).parent), started):
                        out(row)
        time.sleep(1)


START = time.time()

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0)
