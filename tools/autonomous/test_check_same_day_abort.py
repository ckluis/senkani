#!/usr/bin/env python3
"""
Tests for `check_same_day_abort.py` — the helper that powers the
Step 3 "Same-day-abort skip" sub-rule in `/senkani-autonomous`.

Originating finding:
`process-gap-aborted-item-same-day-repick-2026-05-21`. Operator
scope-groom 2026-05-23 chose mechanism (A) — time-based skip with
re-eligibility = next ISO date OR last_touched bump.

These tests assert five load-bearing contracts:

  (a) Clean file (no abort headers) → empty stdout + exit 0.
  (b) Single `## Groom abort note <date>` header → stdout = that date.
  (c) Multiple abort headers across forms (Groom / Build / Scope-groom
      / Decompose) → stdout = chronologically latest ISO date.
  (d) "Groom abort retry note <date>" variant is recognized.
  (e) Missing or unreadable file → exit 2; stdout empty.

Stdlib-only (`unittest`); no operator setup needed.

Usage:
    python3 tools/autonomous/test_check_same_day_abort.py
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
HELPER = THIS_DIR / "check_same_day_abort.py"

CLEAN_ITEM = """\
---
id: clean-item
status: open
type: bug
---

# Clean item

No abort sections here.
"""

SINGLE_ABORT = """\
---
id: single-abort
status: manual
---

# Single abort

## Groom abort note 2026-05-21

Body of the abort note.
"""

MULTI_ABORT = """\
---
id: multi-abort
status: manual
---

# Multi abort

## Groom abort note 2026-05-19

First abort.

## Build abort note 2026-05-22 — envelope too big

Second abort.

## Scope-groom abort note 2026-05-20

Third abort.
"""

RETRY_NOTE = """\
---
id: retry-note
status: manual
---

# Retry-note form

## Groom abort note 2026-05-21

First round.

## Groom abort retry note 2026-05-21 (round 2)

Same-day re-pick — exactly the thrashing case.
"""


def run(path: Path) -> tuple[str, str, int]:
    """Invoke the helper and return (stdout, stderr, exit_code)."""
    proc = subprocess.run(
        [sys.executable, str(HELPER), str(path)],
        capture_output=True,
        text=True,
    )
    return proc.stdout.strip(), proc.stderr, proc.returncode


class CheckSameDayAbortTests(unittest.TestCase):
    """Five contracts above, one method per contract."""

    def test_clean_file_returns_empty(self) -> None:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".md", delete=False, encoding="utf-8"
        ) as f:
            f.write(CLEAN_ITEM)
            path = Path(f.name)
        try:
            stdout, _, rc = run(path)
            self.assertEqual(stdout, "")
            self.assertEqual(rc, 0)
        finally:
            path.unlink(missing_ok=True)

    def test_single_abort_returns_date(self) -> None:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".md", delete=False, encoding="utf-8"
        ) as f:
            f.write(SINGLE_ABORT)
            path = Path(f.name)
        try:
            stdout, _, rc = run(path)
            self.assertEqual(stdout, "2026-05-21")
            self.assertEqual(rc, 0)
        finally:
            path.unlink(missing_ok=True)

    def test_multi_abort_returns_latest_across_forms(self) -> None:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".md", delete=False, encoding="utf-8"
        ) as f:
            f.write(MULTI_ABORT)
            path = Path(f.name)
        try:
            stdout, _, rc = run(path)
            # Latest of 05-19 / 05-22 / 05-20 = 05-22
            self.assertEqual(stdout, "2026-05-22")
            self.assertEqual(rc, 0)
        finally:
            path.unlink(missing_ok=True)

    def test_retry_note_form_recognized(self) -> None:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".md", delete=False, encoding="utf-8"
        ) as f:
            f.write(RETRY_NOTE)
            path = Path(f.name)
        try:
            stdout, _, rc = run(path)
            self.assertEqual(stdout, "2026-05-21")
            self.assertEqual(rc, 0)
        finally:
            path.unlink(missing_ok=True)

    def test_missing_file_returns_exit_2(self) -> None:
        stdout, stderr, rc = run(Path("/tmp/does-not-exist-xyz123.md"))
        self.assertEqual(rc, 2)
        self.assertIn("No such file", stderr)

    def test_pick_precedence_skip_semantics(self) -> None:
        """End-to-end sanity: the pick-precedence rule says 'skip if
        latest abort date == today AND last_touched != today'. This
        test reproduces the round-time computation for a fixture
        where the abort date IS today — operator can't bump
        last_touched same-day, the loop must skip."""
        today_iso = "2026-05-23"
        same_day = f"""\
---
id: same-day-aborted
status: manual
groomable: true
last_touched: 2026-05-21
---

# Same-day aborted fixture

## Groom abort note {today_iso}

Aborted today; round 2 would thrash without the skip rule.
"""
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".md", delete=False, encoding="utf-8"
        ) as f:
            f.write(same_day)
            path = Path(f.name)
        try:
            stdout, _, rc = run(path)
            # Helper returns today's date; the round's pick precedence
            # combines this with the item's `last_touched:` to decide
            # the skip (test of the combination logic lives at the
            # pick site — here we verify the helper's output is
            # exactly the input the rule needs).
            self.assertEqual(stdout, today_iso)
            self.assertEqual(rc, 0)
        finally:
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
