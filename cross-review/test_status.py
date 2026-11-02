#!/usr/bin/env python3
"""status.py classify() on fake state / report files.  python3 -m unittest cross-review/test_status.py"""
import os
import re
import sys
import tempfile
import time
import unittest
from pathlib import Path

os.environ["CR_NO_COLOR"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parent))
import status as S  # noqa: E402

PLAIN = re.compile(r"\x1b\[[0-9;]*m")


class Classify(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.state, self.reports, inbox = root / "s", root / "r", root / "i"
        for d in (self.state, self.reports, inbox):
            d.mkdir()
        self.cfg = {"name": "x", "state_dir": str(self.state), "report_dir": str(self.reports),
                    "inbox_dir": str(inbox), "trusted": "me", "wt": ""}
        self.age = 3600

    def tearDown(self):
        self.tmp.cleanup()

    def round(self, sha: str, verdict: str, tests_failed: bool = False):
        """One review round on head `sha` (8 hex) by codex and deepseek; later calls are newer."""
        self.age -= 60
        for r in ("codex", "deepseek"):
            done = self.state / f"x-9-{sha}-{r}.done"
            done.touch()
            os.utime(done, (time.time() - self.age,) * 2)
            tests = "- exit=1: yarn typecheck" if tests_failed else "- ok: yarn test"
            (self.reports / f"x-pr9-{sha}-{r}.md").write_text(
                f"- head: `{sha}` / author: claude / reviewed: x\n- tests: {tests}\n- secrets: none\n\n## 判定\n{verdict}\n",
                encoding="utf-8")

    def classify(self, head: str):
        pr = {"number": 9, "title": "t", "state": "OPEN", "headRefOid": head + "00", "updatedAt": "",
              "labels": [{"name": "author:claude"}], "author": {"login": "me"}}
        it = S.classify(pr, self.cfg, set())
        return it, PLAIN.sub("", S.render_line(it, 4))

    def test_approved(self):
        self.round("aaaaaaaa", "APPROVE")
        it, line = self.classify("aaaaaaaa")
        self.assertEqual((it["key"], it["final"]), ("approved", ""))
        self.assertNotIn("→ APPROVED", line)

    def test_changes_requested_by_a_reviewer_has_no_final(self):
        self.round("aaaaaaaa", "CHANGES_REQUESTED")
        it, line = self.classify("aaaaaaaa")
        self.assertEqual((it["key"], it["final"]), ("changes", ""))
        self.assertIn("claude fixing", line)

    def test_all_approve_with_tests_failed_shows_final(self):
        self.round("aaaaaaaa", "APPROVE", tests_failed=True)
        it, line = self.classify("aaaaaaaa")
        self.assertEqual((it["key"], it["final"]), ("changes", "APPROVED"))
        self.assertIn("→ APPROVED", line)
        self.assertIn("claude fixing · tests✗: see the reports", line)
        self.assertNotIn("secrets✗", line)

    def test_needs_you_names_the_approved_head(self):
        self.round("bbbbbbbb", "CHANGES_REQUESTED")
        self.round("aaaaaaaa", "APPROVE", tests_failed=True)
        (self.state / "x-9.limit").touch()
        it, line = self.classify("cccccccc")
        self.assertEqual(it["key"], "needs_you")
        self.assertEqual(it["final"], "APPROVED @aaaaaaaa (head cccccccc not reviewed)")
        self.assertIn("never all approved", line)

    def test_needs_you_after_changes_has_no_final(self):
        self.round("aaaaaaaa", "CHANGES_REQUESTED")
        (self.state / "x-9.limit").touch()
        it, _ = self.classify("cccccccc")
        self.assertEqual((it["key"], it["final"]), ("needs_you", ""))


if __name__ == "__main__":
    unittest.main()
