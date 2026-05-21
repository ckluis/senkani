#!/usr/bin/env python3
"""
Tests for `check_envelope_size.py` — the helper that scope-groom
mode invokes between phase 5 (Audit the questions) and phase 6
(Run the interview) to detect items whose scope likely exceeds the
60-min autonomous round envelope.

Originating item:
`process-gap-scope-groom-meaty-size-envelope-check-2026-05-19`.

These tests cover the four Acceptance scenarios + the Kleppmann
audit-shape contract:
    1. size: meaty fires the question (regardless of bullet count).
    2. >5 top-level acceptance bullets fires the question (regardless
       of size).
    3. No-fire when size is small AND bullets ≤5.
    4. Nested sub-bullets do NOT inflate the count (Torvalds audit).
    5. JSON output carries the full suggested_question for SKILL.md to
       hand to AskUserQuestion (Kleppmann audit-shape).

Stdlib-only (`unittest`); no operator setup needed.

Usage:
    python3 tools/autonomous/test_check_envelope_size.py
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))
import check_envelope_size as ces  # type: ignore  # noqa: E402


HELPER = THIS_DIR / "check_envelope_size.py"


def _write_item(tmpdir: Path, *, size: str | None, acceptance: str,
                name: str = "test-item.md") -> Path:
    path = tmpdir / name
    size_line = f"size: {size}\n" if size else ""
    path.write_text(
        "---\n"
        "id: test-item\n"
        "title: 'Test item'\n"
        "status: manual\n"
        + size_line
        + "---\n\n"
        + acceptance,
        encoding="utf-8",
    )
    return path


def _run(item: Path) -> tuple[int, dict]:
    proc = subprocess.run(
        [sys.executable, str(HELPER), str(item)],
        capture_output=True, text=True,
    )
    if proc.returncode == 2:
        raise RuntimeError(f"helper error: {proc.stderr}")
    return proc.returncode, json.loads(proc.stdout)


class TestEnvelopeSizeHelper(unittest.TestCase):

    def test_size_meaty_fires_regardless_of_bullet_count(self) -> None:
        """Acceptance scenario 1: size: meaty alone is enough to
        fire the envelope-size question, even with a single
        acceptance bullet."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            item = _write_item(tmp, size="meaty", acceptance=(
                "## Acceptance\n"
                "- [ ] Add a single function and ship\n"
            ))
            rc, out = _run(item)
            self.assertEqual(rc, 1, "exit 1 when fire")
            self.assertTrue(out["should_fire"])
            reason_kinds = {r["kind"] for r in out["reasons"]}
            self.assertIn("size", reason_kinds)
            self.assertEqual(out["size"], "meaty")
            self.assertEqual(out["bullet_count"], 1)

    def test_size_large_also_fires(self) -> None:
        """`size: large` is reserved per the originating item's text
        ('size: meaty OR any future size: large') — verify the
        MEATY_SIZE_TOKENS tuple covers both."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            item = _write_item(tmp, size="large", acceptance=(
                "## Acceptance\n"
                "- [ ] Single bullet\n"
            ))
            rc, out = _run(item)
            self.assertEqual(rc, 1)
            self.assertEqual(out["size"], "large")
            self.assertIn("large", out["meaty_size_tokens"])

    def test_more_than_five_bullets_fires(self) -> None:
        """Acceptance scenario 2: >5 top-level acceptance bullets
        fires even when size is small. Boundary: 6 bullets fires;
        5 bullets does not (next test)."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            acceptance = (
                "## Acceptance\n"
                "- [ ] one\n"
                "- [ ] two\n"
                "- [ ] three\n"
                "- [ ] four\n"
                "- [ ] five\n"
                "- [ ] six\n"
            )
            item = _write_item(tmp, size="small", acceptance=acceptance)
            rc, out = _run(item)
            self.assertEqual(rc, 1)
            self.assertEqual(out["bullet_count"], 6)
            reason_kinds = {r["kind"] for r in out["reasons"]}
            self.assertIn("bullet_count", reason_kinds)

    def test_small_with_five_bullets_no_fire(self) -> None:
        """Acceptance scenario 3: no-fire when size is small AND
        bullets ≤ threshold. Confirms the threshold is strict-greater
        (5 bullets does NOT fire; 6 does)."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            acceptance = (
                "## Acceptance\n"
                "- [ ] one\n"
                "- [ ] two\n"
                "- [ ] three\n"
                "- [ ] four\n"
                "- [ ] five\n"
            )
            item = _write_item(tmp, size="small", acceptance=acceptance)
            rc, out = _run(item)
            self.assertEqual(rc, 0, "exit 0 when no fire")
            self.assertFalse(out["should_fire"])
            self.assertEqual(out["reasons"], [])
            self.assertEqual(out["bullet_count"], 5)
            self.assertIsNone(out["suggested_question"])

    def test_nested_sub_bullets_not_counted(self) -> None:
        """Torvalds audit: parameterized sub-bullets (any indented
        `- [ ]` line) MUST NOT inflate the trigger count. Only
        zero-indent top-level bullets count."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            acceptance = (
                "## Acceptance\n"
                "- [ ] top one with sub-bullets:\n"
                "    - [ ] sub a\n"
                "    - [ ] sub b\n"
                "    - [ ] sub c\n"
                "- [ ] top two\n"
            )
            item = _write_item(tmp, size="small", acceptance=acceptance)
            rc, out = _run(item)
            self.assertEqual(rc, 0)
            self.assertEqual(out["bullet_count"], 2,
                             "only top-level bullets count")

    def test_bullets_outside_acceptance_section_not_counted(self) -> None:
        """A `- [ ]` line in `## Notes` or `## Pre-grooming notes`
        MUST NOT count toward the trigger. Only bullets inside the
        `## Acceptance` section count."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            body = (
                "## Scope\n"
                "Some scope text.\n\n"
                "## Acceptance\n"
                "- [ ] one\n"
                "- [ ] two\n\n"
                "## Notes\n"
                "- [ ] not counted\n"
                "- [ ] also not counted\n"
                "- [ ] still not\n"
                "- [ ] etc\n"
                "- [ ] etc\n"
                "- [ ] etc\n"
                "- [ ] etc\n"
            )
            item = _write_item(tmp, size="small", acceptance=body)
            rc, out = _run(item)
            self.assertEqual(rc, 0)
            self.assertEqual(out["bullet_count"], 2)

    def test_kleppmann_output_shape_carries_full_question(self) -> None:
        """Kleppmann audit-shape: the JSON output's
        `suggested_question` carries the full header / text / options
        record so SKILL.md can hand it directly to AskUserQuestion
        without re-rendering. Three options exactly: (a), (b), (c)."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            item = _write_item(tmp, size="meaty", acceptance=(
                "## Acceptance\n"
                "- [ ] anything\n"
            ))
            rc, out = _run(item)
            self.assertEqual(rc, 1)
            q = out["suggested_question"]
            self.assertIsNotNone(q)
            self.assertIn("header", q)
            self.assertIn("text", q)
            self.assertIn("options", q)
            self.assertEqual(len(q["options"]), 3,
                             "three options: (a), (b), (c)")
            for opt in q["options"]:
                self.assertIn("label", opt)
                self.assertIn("description", opt)
            self.assertEqual(q["header"], ces.CANONICAL_QUESTION_HEADER)
            self.assertLessEqual(len(q["header"]), 12,
                                 "AskUserQuestion header max 12 chars")
            labels = [o["label"] for o in q["options"]]
            self.assertTrue(any("(a)" in l for l in labels))
            self.assertTrue(any("(b)" in l for l in labels))
            self.assertTrue(any("(c)" in l for l in labels))

    def test_no_size_frontmatter_falls_back_to_bullet_count(self) -> None:
        """An item without a `size:` frontmatter key MUST not crash;
        it falls back to bullet-count evaluation only. Reasonable
        default — older items pre-date the size convention."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            item = _write_item(tmp, size=None, acceptance=(
                "## Acceptance\n"
                "- [ ] one\n"
                "- [ ] two\n"
            ))
            rc, out = _run(item)
            self.assertEqual(rc, 0)
            self.assertIsNone(out["size"])
            self.assertEqual(out["bullet_count"], 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
