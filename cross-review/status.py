#!/usr/bin/env python3
"""cross-review status as a GitHub-like PR list. Called by status.sh, which passes the config.

One line per PR, newest first. Open PRs on top:

  WAITING            the current head has no review yet (the next cron pass picks it up)
  IN REVIEW          a review is running now
  CHANGES REQUESTED  a reviewer asked for changes — the author fixes and pushes (then it is WAITING again)
  REVIEWED           reviewed with comments only
  APPROVED           every reviewer approved — merge it on GitHub
  NEEDS YOU          reviewed MAX_ROUNDS times and still changing — automatic review stopped, you decide
  SKIPPED            draft / no-cross-review label / from a fork / author not trusted

Below, PRs merged or closed in the last CROSS_REVIEW_DONE_DAYS days (default 1), at most 6.

With CR_HISTORY="<repo>|<PR>" (status.sh <repo> <PR>): every review round of that PR instead.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import unicodedata
from datetime import datetime
from pathlib import Path

COLOR = not (os.environ.get("NO_COLOR") or os.environ.get("CR_NO_COLOR")) and (
    sys.stdout.isatty() or os.environ.get("FORCE_COLOR"))


def c(code: str) -> str:
    return code if COLOR else ""


RESET, BOLD, DIM = c("\033[0m"), c("\033[1m"), c("\033[2m")
RED, GREEN, YELLOW, CYAN, MAGENTA, PURPLE = (c("\033[31m"), c("\033[32m"), c("\033[33m"), c("\033[36m"),
                                             c("\033[35m"), c("\033[38;5;141m"))

STATES = {  # key: (label, color, icon)
    "needs_you": ("NEEDS YOU", YELLOW + BOLD, "◆"),
    "changes": ("CHANGES REQUESTED", RED + BOLD, "●"),
    "running": ("IN REVIEW", CYAN, "●"),
    "waiting": ("WAITING", YELLOW, "●"),
    "reviewed": ("REVIEWED", MAGENTA, "●"),
    "approved": ("APPROVED", GREEN + BOLD, "●"),
    "skipped": ("SKIPPED", DIM, "○"),
    "merged": ("MERGED", PURPLE, "✓"),
    "closed": ("CLOSED", DIM + RED, "✕"),
}
OPEN_ORDER = ["needs_you", "changes", "running", "waiting", "reviewed", "approved", "skipped"]
ANSI = re.compile(r"\x1b\[[0-9;]*m")


# ── text width (CJK titles are double width) ──────────────────
def width(s: str) -> int:
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in ANSI.sub("", s))


def fit(s: str, w: int) -> str:
    if width(s) <= w:
        return s + " " * (w - width(s))
    out, n = "", 0
    for ch in s:
        cw = 2 if unicodedata.east_asian_width(ch) in "WF" else 1
        if n + cw > w - 1:
            break
        out, n = out + ch, n + cw
    return out + "…" + " " * (w - n - 1)


def ago(ts: float) -> str:
    s = int(time.time() - ts)
    if s < 60:
        return "now"
    if s < 3600:
        return f"{s // 60}m ago"
    if s < 86400:
        return f"{s // 3600}h ago"
    return f"{s // 86400}d ago"


def parse_time(v: str | None) -> float:
    if not v:
        return 0.0
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


# ── local review state ───────────────────────────────────────
def running_reviews() -> set[tuple[str, str]]:
    """(repo, pr) of cross-review.sh processes — the script itself, or bash running it."""
    out: set[tuple[str, str]] = set()
    try:
        ps = subprocess.run(["ps", "-eo", "args="], capture_output=True, text=True).stdout
    except OSError:
        return out
    for line in ps.splitlines():
        a = line.split()
        if len(a) >= 3 and a[0].endswith("cross-review.sh") and a[2].isdigit():
            out.add((a[1], a[2]))
        elif len(a) >= 4 and re.search(r"(^|/)bash$", a[0]) and a[1].endswith("cross-review.sh") and a[3].isdigit():
            out.add((a[2], a[3]))
    return out


def summarize_report(path: Path) -> dict:
    """Verdict, findings by severity and test failure from a report cross-review.sh wrote."""
    verdict, sev, tests_failed, sec, author, secrets = "", {"高": 0, "中": 0, "低": 0}, False, "", "", False
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.search(r"/ author: ([\w-]+) /", line)              # "- head: `…` / author: codex / reviewed: …"
        if m and not author:
            author = m.group(1)
        if line.startswith("## "):
            sec = line[3:].strip()
            continue
        if line.startswith("- tests:") and re.search(r"exit=[1-9]", line):
            tests_failed = True
        if re.match(r"- secrets: [1-9]\d* found", line):
            secrets = True
        if sec == "判定" and not verdict and line.strip():
            m = re.search(r"[A-Z_]{4,}", line)
            verdict = m.group(0) if m else line.split()[0]
        m = re.match(r"- \[(高|中|低)\]", line)
        if sec == "指摘" and m:
            sev[m.group(1)] += 1
    return {"verdict": verdict or "?", "sev": sev, "tests_failed": tests_failed, "author": author, "secrets": secrets}


def mmss(sec: float) -> str:
    sec = int(max(sec, 0))
    return f"{sec // 60}:{sec % 60:02d}"


def short_cmd(cmd: str) -> str:
    m = re.match(r"""^/bin/(?:ba)?sh -lc ['"](.*)['"]$""", cmd.strip())
    return (m.group(1) if m else cmd).strip()


def last_action(events: Path) -> tuple[str, int]:
    """(what the reviewer did last, number of tool steps) from a claude stream-json or codex --json file."""
    last, steps = "starting", 0
    for line in events.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") == "assistant":                                  # claude
            for part in (e.get("message") or {}).get("content") or []:
                if part.get("type") == "tool_use":
                    steps += 1
                    inp = part.get("input") or {}
                    arg = inp.get("file_path") or inp.get("pattern") or inp.get("command") or ""
                    last = f"{part.get('name')} {Path(arg).name if inp.get('file_path') else arg}".strip()
                elif part.get("type") == "text":
                    last = "writing"
        elif e.get("type") == "result":
            last = "finishing"
        item = e.get("item") or {}                                         # codex
        if e.get("type") == "item.started" and item.get("type") == "command_execution":
            steps += 1
            last = short_cmd(item.get("command") or "")
        elif e.get("type") == "item.completed" and item.get("type") == "agent_message":
            last = "thinking"
    return last, steps


def review_progress(wt: str) -> str:
    """What a running review is doing, from <worktree>/.cross-review written by cross-review.sh."""
    work = Path(wt) / ".cross-review"
    try:
        phase, start = (work / "phase").read_text().split()[:2]
        start_ts = float(start)
    except (OSError, ValueError):
        return "starting"
    now = time.time()
    if phase == "tests":
        return f"running tests {mmss(now - start_ts)}"
    parts = []
    for ev in sorted(work.glob("*.events.jsonl")):
        who = ev.name.split(".")[0]
        last, steps = last_action(ev)
        quiet = now - ev.stat().st_mtime
        alive = f"{GREEN}active{RESET}" if quiet < 45 else f"{YELLOW}quiet {mmss(quiet)}{RESET}"
        parts.append(f"{CYAN}{who}{RESET} {fit(last, 34).rstrip()} · {steps} steps · {alive}")
    elapsed = f"{mmss(now - start_ts)}"
    return (" | ".join(parts) + f" · {elapsed}") if parts else f"starting reviewers {elapsed}"


def inbox_for(inbox: Path, repo: str, num: int) -> list[tuple[str, bool]]:
    """(author agent, notified) for review pointers still waiting in an author's inbox."""
    out = []
    for f in sorted(inbox.glob(f"*/{repo}-pr{num}-*.txt")):
        out.append((f.parent.name, Path(str(f) + ".notified").exists()))
    return out


# ── one line per PR ──────────────────────────────────────────
def reviewer_cells(reviews: dict[str, dict]) -> str:
    cells = []
    for r, s in reviews.items():
        v = s["verdict"]
        mark, col = {"APPROVE": ("✓", GREEN), "CHANGES_REQUESTED": ("✗", RED)}.get(v, ("~", MAGENTA))
        sev = " ".join(f"{k}{n}" for k, n in s["sev"].items() if n)
        test = (f" {RED}tests✗{RESET}" if s["tests_failed"] else "") + (f" {RED}{BOLD}secrets✗{RESET}" if s.get("secrets") else "")
        cells.append(f"{col}{r} {mark}{RESET}{(' ' + DIM + sev + RESET) if sev else ''}{test}")
    return "  ".join(cells)


def review_rounds(cfg: dict, repo: str, num: int) -> list[tuple[str, float, dict[str, dict]]]:
    """Every reviewed head of a PR, oldest first: (sha8, when, {reviewer: report summary})."""
    rounds: dict[str, tuple[float, dict[str, dict]]] = {}
    for done in Path(cfg["state_dir"]).glob(f"{repo}-{num}-*.done"):
        m = re.fullmatch(rf"{re.escape(repo)}-{num}-([0-9a-f]{{8}})-([a-z]+)\.done", done.name)
        if not m:
            continue
        sha, r = m.groups()
        report = Path(cfg["report_dir"]) / f"{repo}-pr{num}-{sha}-{r}.md"
        summary = summarize_report(report) if report.is_file() else {
            "verdict": "?", "sev": {}, "tests_failed": False, "author": ""}
        when, revs = rounds.get(sha, (0.0, {}))
        revs[r] = summary
        rounds[sha] = (max(when, done.stat().st_mtime), revs)
    return sorted(((sha, w, revs) for sha, (w, revs) in rounds.items()), key=lambda x: x[1])


def all_approved(revs: dict[str, dict]) -> bool:
    return bool(revs) and all(s["verdict"] == "APPROVE" and not s["tests_failed"] and not s.get("secrets")
                              for s in revs.values())


def classify(pr: dict, cfg: dict, running: set[tuple[str, str]]) -> dict:
    repo, num = cfg["name"], pr["number"]
    sha = (pr.get("headRefOid") or "")[:8]
    labels = [l["name"] for l in pr.get("labels") or []]
    author_login = (pr.get("author") or {}).get("login", "")
    agent = next((l.split(":", 1)[1] for l in labels if l.startswith("author:")), "")
    rounds = review_rounds(cfg, repo, num)
    reviews: dict[str, dict] = next((revs for s, _, revs in rounds if s == sha), {})
    # when the current head has no review (stopped, skipped, waiting), the last result is the newest earlier round
    earlier = [r for r in rounds if r[0] != sha]
    last = earlier[-1] if earlier else None
    approved = next((r[0] for r in reversed(rounds) if all_approved(r[2])), "")
    inbox = inbox_for(Path(cfg["inbox_dir"]), repo, num)
    # the agent that wrote the PR: author:X label > the reviews' author line > whose inbox got the review
    agent = agent or next((s["author"] for _, _, revs in rounds for s in revs.values()
                           if s["author"] not in ("", "unknown")), "") \
        or (inbox[0][0] if inbox else "")
    note = ""
    if pr["state"] == "MERGED":
        key, when = "merged", parse_time(pr.get("mergedAt"))
    elif pr["state"] == "CLOSED":
        key, when = "closed", parse_time(pr.get("closedAt"))
    else:
        when = parse_time(pr.get("updatedAt"))
        trusted = f" {cfg['trusted']} "
        if pr.get("isDraft"):
            key, note = "skipped", "draft"
        elif "no-cross-review" in labels:
            key, note = "skipped", "no-cross-review"
        elif pr.get("isCrossRepository"):
            key, note = "skipped", "from a fork"
        elif f" {author_login} " not in trusted:
            key, note = "skipped", f"author {author_login} not trusted"
        elif (repo, str(num)) in running:
            key, note = "running", review_progress(cfg.get("wt", ""))
        elif not reviews and (Path(cfg["state_dir"]) / f"{repo}-{num}.limit").exists():
            key, note = "needs_you", f"review stopped — merge on GitHub, or cross-review.sh {repo} {num} --force"
        elif not reviews:
            key, note = "waiting", "next cron pass"
        else:
            verdicts = {s["verdict"] for s in reviews.values()}
            if "CHANGES_REQUESTED" in verdicts or any(s["tests_failed"] or s.get("secrets") for s in reviews.values()):
                key = "changes"
                who = agent or (inbox[0][0] if inbox else "author")
                told = all(n for _, n in inbox) if inbox else True
                note = f"→ {who} fixing" if told else f"→ {who} (not told yet: busy)"
            elif verdicts == {"APPROVE"}:
                key, note = "approved", "→ merge on GitHub"
            else:
                key = "reviewed"
    if key in ("merged", "closed") and inbox:
        note = f"inbox: {inbox[0][0]} {len(inbox)} left"
    if key in ("needs_you", "skipped") and rounds:
        extra = f"{len(rounds)} rounds" + (f", all approved at {approved}" if approved else ", never all approved")
        note = f"{note} · {extra}" if note else extra
    return {"key": key, "when": when, "repo": repo, "num": num, "title": pr.get("title", ""),
            "agent": agent, "reviews": reviews, "note": note,
            "last": last if not reviews and key not in ("running",) else None}


def render_line(it: dict, repo_w: int) -> str:
    label, color, icon = STATES[it["key"]]
    head = f"  {color}{icon} {label:<17}{RESET} {DIM}{fit(it['repo'], repo_w)}{RESET} {('#' + str(it['num'])):<5} "
    title = fit(it["title"], 44)
    # who wrote it → who reviewed it, e.g. "codex → claude ✓ 低2"
    pending = it["key"] in ("waiting", "running")
    if it["reviews"]:
        cells = reviewer_cells(it["reviews"])
    elif it.get("last"):
        cells = f"{DIM}last {it['last'][0]}:{RESET} " + reviewer_cells(it["last"][2])
    else:
        cells = f"{DIM}{'…' if pending else '—'}{RESET}"
    who = f"{it['agent'] or '?'} → " + cells
    note = (f"  {it['note']}" if it["key"] == "running" else f"  {DIM}{it['note']}{RESET}") if it["note"] else ""
    when = f"{DIM}{ago(it['when']):>7}{RESET}" if it["when"] else " " * 7
    return f"{head}{title}  {when}  {who}{note}"


def history(repo: str, num: int, gh_repo: str, cfg: dict) -> int:
    """Every review round of one PR, oldest first — what to look at before deciding."""
    res = subprocess.run(["gh", "pr", "view", str(num), "-R", gh_repo, "--json", "title,state,headRefOid,commits"],
                         capture_output=True, text=True)
    pr = json.loads(res.stdout) if res.returncode == 0 and res.stdout else {}
    head = (pr.get("headRefOid") or "")[:8]
    print(f"{BOLD}{repo} #{num}{RESET} {pr.get('title', '')}  {DIM}{pr.get('state', '?')} · head {head or '?'}"
          f" · {len(pr.get('commits') or [])} commits{RESET}")
    rounds = review_rounds(cfg, repo, num)
    if not rounds:
        print(f"  {DIM}まだレビューされていません{RESET}")
        return 0
    for i, (sha, when, revs) in enumerate(rounds, 1):
        mark = f"{GREEN}all approved{RESET}" if all_approved(revs) else ""
        cur = f" {BOLD}← head{RESET}" if sha == head else ""
        print(f"  {i:>2}. {datetime.fromtimestamp(when):%m/%d %H:%M}  {sha}  {reviewer_cells(revs)}  {mark}{cur}")
    if head and head not in {r[0] for r in rounds}:
        print(f"  {YELLOW}head {head} はまだレビューされていません（止めた・スキップ・待ち）{RESET}")
    last_sha = rounds[-1][0]
    reports = sorted(Path(cfg["report_dir"]).glob(f"{repo}-pr{num}-{last_sha}-*.md"))
    print(f" 最後のレビュー（{last_sha}）:")
    for r in reports:
        print(f"  {r}")
    approved = next((r[0] for r in reversed(rounds) if all_approved(r[2])), "")
    print(f" 全員 APPROVE だった最後: {approved or 'なし'}")
    return 0


def main() -> int:
    # name|gh repo|review worktree|report dir (per repo: reports live in each repo's workspace)
    repos = [(line.split("|") + ["", ""])[:4] for line in os.environ.get("CR_REPOS", "").splitlines() if "|" in line]
    base = {k: os.environ.get(f"CR_{k.upper()}", "") for k in ("state_dir", "inbox_dir", "trusted")}
    if os.environ.get("CR_HISTORY"):                       # status.sh <repo> <PR>
        want_repo, want_num = os.environ["CR_HISTORY"].split("|")
        for name, gh_repo, wt, report_dir in repos:
            if name == want_repo:
                return history(name, int(want_num), gh_repo, dict(base, report_dir=report_dir))
        print(f"unknown repo: {want_repo}", file=sys.stderr)
        return 1
    done_days = float(os.environ.get("CROSS_REVIEW_DONE_DAYS", "1"))
    running = running_reviews()
    items, errors = [], []
    for name, gh_repo, wt, report_dir in repos:
        cfg = dict(base, name=name, wt=wt, report_dir=report_dir, trusted=base["trusted"] or gh_repo.split("/")[0])
        res = subprocess.run(
            ["gh", "pr", "list", "-R", gh_repo, "--state", "all", "-L", "40", "--json",
             "number,title,state,headRefOid,isDraft,labels,isCrossRepository,author,updatedAt,mergedAt,closedAt"],
            capture_output=True, text=True)
        if res.returncode != 0:
            errors.append(f"  {RED}{name}: PR を取得できません: {(res.stderr or '').strip().splitlines()[:1]}{RESET}")
            continue
        for pr in json.loads(res.stdout or "[]"):
            items.append(classify(pr, cfg, running))

    open_items = sorted((i for i in items if i["key"] in OPEN_ORDER), key=lambda i: -i["when"])
    cutoff = time.time() - done_days * 86400
    done_items = sorted((i for i in items if i["key"] in ("merged", "closed") and i["when"] >= cutoff),
                        key=lambda i: -i["when"])
    repo_w = max([width(r[0]) for r in repos] or [10])

    counts = {k: sum(1 for i in open_items if i["key"] == k) for k in OPEN_ORDER}
    summary = " · ".join(f"{STATES[k][1]}{counts[k]} {STATES[k][0].lower()}{RESET}"
                         for k in OPEN_ORDER if counts[k] and k != "skipped")
    print(f"{BOLD}cross-review{RESET}  {summary or DIM + 'no open PRs' + RESET}")
    if not repos:
        print(f"  {YELLOW}対象リポジトリがありません（config.local.sh の REPOS）{RESET}")
    print(*errors, sep="\n") if errors else None
    print(f" {BOLD}Open{RESET}")
    print("\n".join(render_line(i, repo_w) for i in open_items) or f"  {DIM}none{RESET}")
    print(f" {BOLD}Done{RESET} {DIM}(last {done_days * 24:g}h){RESET}")
    print("\n".join(render_line(i, repo_w) for i in done_items[:6]) or f"  {DIM}none{RESET}")
    if len(done_items) > 6:
        print(f"  {DIM}… {len(done_items) - 6} more{RESET}")
    print(os.environ.get("CR_CRON_LINE", ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
