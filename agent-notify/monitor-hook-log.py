#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


RESET = "\033[0m"
DIM = "\033[2m"
RED = "\033[31m"
YELLOW = "\033[33m"
GREEN = "\033[32m"
CYAN = "\033[36m"
WHITE = "\033[37m"

if os.environ.get("NO_COLOR") or os.environ.get("CLICOLOR") == "0" or os.environ.get("TERM") == "dumb":
    RESET = DIM = RED = YELLOW = GREEN = CYAN = WHITE = ""


def color(text: str, code: str) -> str:
    return f"{code}{text}{RESET}"


def parse_fields(line: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for token in line.strip().split():
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        fields[key] = value
    return fields


def render(line: str, expected_root: str) -> str:
    raw = line.rstrip("\n")
    fields = parse_fields(raw)
    state_root = fields.get("state_root", "")
    project_root = fields.get("project_root", "")
    repo_root = fields.get("repo_root", "")
    event = fields.get("event", "")

    if not raw.strip():
        return ""

    if "state_root=" in raw and not state_root:
        return color(raw, RED)

    if expected_root and state_root and state_root != expected_root:
        return color(raw, RED)

    if expected_root and not state_root:
        return color(raw, YELLOW)

    if event == "stop" and project_root and repo_root and project_root != repo_root:
        return color(raw, YELLOW)

    if "provider=codex" in raw:
        return color(raw, CYAN)

    return color(raw, GREEN)


def _emit_new_lines(
    path: Path, expected_root: str, last_size: int, buf: str
) -> tuple[int, str]:
    """Read new content from *path* since *last_size*, emit complete lines.

    Returns (new_last_size, remaining_buffer).
    Partial lines (no trailing ``\\n``) are kept in *buf* and prepended
    to the next read.
    """
    try:
        size = path.stat().st_size
    except FileNotFoundError:
        return 0, buf
    except OSError:
        return last_size, buf

    if size < last_size:
        last_size = 0
    if size > last_size:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            fh.seek(last_size)
            data = fh.read()
            for ch in data:
                buf += ch
                if ch == "\n":
                    rendered = render(buf, expected_root)
                    if rendered:
                        print(rendered)
                    buf = ""
        last_size = size
    return last_size, buf


def _tail_inotify(path: Path, expected_root: str) -> None:
    """Tail *path* via inotifywait for real-time updates."""
    parent = path.parent
    filename = path.name
    proc = subprocess.Popen(
        ["inotifywait", "-m", "-e", "modify", "-e", "create",
         "--format", "%e %f", str(parent)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True,
    )
    last_size = path.stat().st_size if path.exists() else 0
    buf = ""
    try:
        for event_line in proc.stdout:
            parts = event_line.strip().split(" ", 1)
            if len(parts) != 2:
                continue
            events, fname = parts
            if fname != filename:
                continue
            if "CREATE" in events:
                last_size = 0
            if not path.exists():
                continue
            last_size, buf = _emit_new_lines(
                path, expected_root, last_size, buf
            )
    except KeyboardInterrupt:
        print()
    finally:
        try:
            proc.kill()
        except OSError:
            pass
        proc.wait()


def _tail_poll(path: Path, expected_root: str) -> None:
    """Tail *path* via periodic 0.5 s polling."""
    last_size = path.stat().st_size if path.exists() else 0
    buf = ""
    while True:
        try:
            last_size, buf = _emit_new_lines(
                path, expected_root, last_size, buf
            )
            time.sleep(0.5)
        except KeyboardInterrupt:
            print()
            return
        except Exception as exc:  # noqa: BLE001
            print(color(f"[monitor] {exc}", RED))
            time.sleep(1.0)


def tail_follow(path: Path, expected_root: str) -> None:
    last_size = 0
    if path.exists():
        last_size = path.stat().st_size
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()

    project_root = expected_root.rsplit("/.omx/notify-state", 1)[0]
    print(color("=== Notify Monitor ===", WHITE))
    print(color(f"project_root: {project_root}", WHITE))
    print(color(f"state_root: {expected_root}", WHITE))
    print(color(f"hook_log: {path}", WHITE))
    print(color("Tail follows...", DIM))

    if shutil.which("inotifywait") is not None:
        _tail_inotify(path, expected_root)
    else:
        _tail_poll(path, expected_root)


def tail_stdin(expected_root: str) -> None:
    """Read lines from *stdin* and render them."""
    project_root = expected_root.rsplit("/.omx/notify-state", 1)[0]
    print(color("=== Notify Monitor (stdin) ===", WHITE))
    print(color(f"project_root: {project_root}", WHITE))
    print(color(f"state_root: {expected_root}", WHITE))
    print(color("Reading from stdin...", DIM))
    try:
        for line in sys.stdin:
            rendered = render(line, expected_root)
            if rendered:
                print(rendered)
    except KeyboardInterrupt:
        print()


def main() -> int:
    args = sys.argv[1:]
    stdin_mode = "--stdin" in args
    if stdin_mode:
        args = [a for a in args if a != "--stdin"]
    if len(args) < 1:
        print("Usage:", file=sys.stderr)
        print(f"  {sys.argv[0]} <project-root> <hook-log>", file=sys.stderr)
        print(f"  {sys.argv[0]} --stdin <project-root>", file=sys.stderr)
        return 1
    project_root = Path(args[0]).resolve()
    expected_root = str(project_root / ".omx" / "notify-state")
    if stdin_mode:
        tail_stdin(expected_root)
    else:
        if len(args) < 2:
            print("Error: <hook-log> required without --stdin", file=sys.stderr)
            return 1
        hook_log = Path(args[1]).resolve()
        tail_follow(hook_log, expected_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
