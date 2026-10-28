#!/usr/bin/env python3
"""Look for secrets in the lines a PR adds. Called by cross-review.sh before the AI reviewers run.

  secret_scan.py <diff.patch>     → one line per hit: "path:line  rule  masked-value"; exit 1 if any

Only added lines (and added file names) are checked, so a secret that was already in the
repository before the PR is not reported again. Values are always masked in the output,
because the result goes into the review report, which is posted as a PR comment.

A line can opt out with a comment containing "secret-scan: allow" (e.g. a documented test
fixture). Obvious placeholders (example, dummy, xxx, your-…, ${VAR}, process.env…) are skipped.
"""
from __future__ import annotations

import re
import sys

RULES: list[tuple[str, re.Pattern[str]]] = [
    ("AWS access key id", re.compile(r"\b((?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[0-9A-Z]{16})\b")),
    ("AWS secret access key", re.compile(
        r"(?i)aws.{0,20}(?:secret|private).{0,20}[=:]\s*[\"']?([A-Za-z0-9/+=]{40})\b")),
    ("private key", re.compile(r"(-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----)")),
    ("GitHub token", re.compile(r"\b((?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})\b")),
    ("Slack token", re.compile(r"\b(xox[abposr]-[A-Za-z0-9-]{10,})\b")),
    ("Slack/Discord webhook", re.compile(
        r"(https://(?:hooks\.slack\.com/services|(?:canary\.|ptb\.)?discord(?:app)?\.com/api/webhooks)/[A-Za-z0-9_/-]{20,})")),
    ("Anthropic API key", re.compile(r"\b(sk-ant-[A-Za-z0-9_-]{20,})")),
    ("OpenAI-style API key", re.compile(r"\b(sk-(?!ant-)(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{32,})")),
    ("Google API key", re.compile(r"\b(AIza[0-9A-Za-z_-]{35})\b")),
    ("Stripe secret key", re.compile(r"\b((?:sk|rk)_live_[0-9A-Za-z]{20,})\b")),
    ("JWT", re.compile(r"\b(eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})\b")),
    ("password / secret assignment", re.compile(
        # also as the end of a longer name: dbPassword, DB_PASSWORD, stripeApiKey
        r"(?i)[A-Za-z0-9_]*(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?key|auth[_-]?token|private[_-]?key)"
        r"\b[\"']?\s*[:=]\s*[\"']([^\"'\s]{8,})[\"']")),
    ("URL with credentials", re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s:/@\"']+:([^\s@/\"']{6,})@[^\s\"']+")),
]
SECRET_FILES = re.compile(
    r"(^|/)(\.env(\.[A-Za-z0-9_.-]+)?|id_(rsa|dsa|ecdsa|ed25519)|[^/]+\.(pem|key|p12|pfx|keystore|jks)|credentials(\.json)?|"
    r"service[-_]account[^/]*\.json)$")
SAFE_FILES = re.compile(r"(\.env\.(example|sample|template|dist)|\.example|\.sample)$")
PLACEHOLDER = re.compile(
    r"(?i)(^\$[A-Za-z_]|example|sample|dummy|placeholder|changeme|change_me|your[-_]|xxx|\*\*\*|<[^>]*>|\$\{|\$\(|process\.env|"
    r"os\.environ|getenv|test|fake|mock|redacted|\.\.\.)")
ALLOW = "secret-scan: allow"


def mask(value: str) -> str:
    value = value.strip()
    return value[:4] + "****" + (f"({len(value)} chars)" if len(value) > 8 else "")


def scan(diff_text: str) -> list[str]:
    hits: list[str] = []
    path, line_no = "", 0
    for raw in diff_text.splitlines():
        if raw.startswith("+++ "):
            path = raw[4:].removeprefix("b/") if raw[4:] != "/dev/null" else ""
            if path and SECRET_FILES.search(path) and not SAFE_FILES.search(path):
                hits.append(f"{path}  secret-looking file added or changed  (check it is meant to be in git)")
            continue
        if raw.startswith("@@"):
            m = re.search(r"\+(\d+)", raw)
            line_no = int(m.group(1)) - 1 if m else 0
            continue
        if raw.startswith("-") or raw.startswith("\\"):
            continue
        line_no += 1
        if not raw.startswith("+") or not path:
            continue
        text = raw[1:]
        if ALLOW in text:
            continue
        for rule, pattern in RULES:
            for m in pattern.finditer(text):
                value = m.group(1)
                if rule != "private key" and PLACEHOLDER.search(value):
                    continue
                if rule == "password / secret assignment" and len(set(value)) < 4:   # "********", "aaaaaaaa"
                    continue
                hits.append(f"{path}:{line_no}  {rule}  {mask(value)}")
    return hits


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        hits = scan(fh.read())
    for h in dict.fromkeys(hits):          # same hit twice (two rules on one value) → once
        print(h)
    return 1 if hits else 0


if __name__ == "__main__":
    raise SystemExit(main())
