#!/usr/bin/env python3
"""
Tests for `roundtrip.py`'s Pass 0 duplicate-frontmatter-key check.

Verifies the contract from
`process-frontmatter-duplicate-blocked-by-keys-2026-05-09`:
roundtrip.py MUST exit non-zero when ANY backlog or completed file declares
a top-level frontmatter key more than once.

Stdlib-only (`unittest` + `subprocess`); no operator setup needed.

Usage:
    python3 tools/autonomous/test_roundtrip_duplicate_keys.py
"""
from __future__ import annotations
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))
import roundtrip  # type: ignore  # noqa: E402

CLEAN_ITEM = """\
---
id: clean-test-item
title: "A perfectly normal item"
status: open
type: hygiene
size: tiny
roster: [Torvalds]
affects: [feature_changed]
blocked_by: []
created: 2026-05-09
last_touched: 2026-05-09
---

# A perfectly normal item

## Scope
Nothing to see here.
"""

DUPLICATE_BLOCKED_BY = """\
---
id: dup-test-item
title: "Item with duplicate blocked_by key (the load-bearing case)"
status: blocked
type: hygiene
blocked_by: [some-real-blocker]
blocked_reason: "real reason"
parent_finding: "x"
blocked_by: []
created: 2026-05-09
last_touched: 2026-05-09
---

# Item with duplicate blocked_by key

## Scope
The trailing `blocked_by: []` overrides the load-bearing line under PyYAML.
"""

DUPLICATE_STATUS = """\
---
id: dup-status-item
title: "Triple-declared status field"
status: open
type: hygiene
status: in_progress
status: done
created: 2026-05-09
last_touched: 2026-05-09
---

# Triple-declared status field
"""


class TestFindDuplicateFrontmatterKeys(unittest.TestCase):
    """Unit tests for the pure helper."""

    def test_clean_returns_empty_list(self):
        self.assertEqual(roundtrip.find_duplicate_frontmatter_keys(CLEAN_ITEM), [])

    def test_blocked_by_dup_is_detected(self):
        dups = roundtrip.find_duplicate_frontmatter_keys(DUPLICATE_BLOCKED_BY)
        self.assertEqual(dups, ["blocked_by"])

    def test_triple_declared_key_listed_once(self):
        dups = roundtrip.find_duplicate_frontmatter_keys(DUPLICATE_STATUS)
        self.assertEqual(dups, ["status"])

    def test_no_frontmatter_returns_empty(self):
        self.assertEqual(roundtrip.find_duplicate_frontmatter_keys("no frontmatter here"), [])

    def test_unterminated_frontmatter_returns_empty(self):
        self.assertEqual(roundtrip.find_duplicate_frontmatter_keys("---\nid: x\nno_close_here\n"), [])


class TestPassZeroIntegration(unittest.TestCase):
    """End-to-end: synthesize a spec/ tree, run pass_zero_duplicate_keys."""

    def _make_tree(self, td: Path, *, with_dup: bool):
        backlog = td / "autonomous" / "backlog"
        backlog.mkdir(parents=True)
        (backlog / "clean-test-item.md").write_text(CLEAN_ITEM)
        if with_dup:
            (backlog / "dup-test-item.md").write_text(DUPLICATE_BLOCKED_BY)
        # Pass 0 also walks completed/ — exercise that path.
        completed = td / "autonomous" / "completed" / "2026"
        completed.mkdir(parents=True)
        (completed / "2026-05-01-other-item.md").write_text(CLEAN_ITEM.replace("clean-test-item", "other-completed-item"))

    def test_pass_zero_clean_tree_is_silent(self):
        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            self._make_tree(td, with_dup=False)
            failures = roundtrip.pass_zero_duplicate_keys(td)
            self.assertEqual(failures, [], f"unexpected failures: {failures}")

    def test_pass_zero_flags_duplicate_in_backlog(self):
        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            self._make_tree(td, with_dup=True)
            failures = roundtrip.pass_zero_duplicate_keys(td)
            self.assertEqual(len(failures), 1, f"expected 1 failure, got: {failures}")
            self.assertIn("dup-test-item.md", failures[0])
            self.assertIn("blocked_by", failures[0])

    def test_pass_zero_flags_duplicate_in_completed(self):
        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            (td / "autonomous" / "backlog").mkdir(parents=True)
            completed = td / "autonomous" / "completed" / "2026"
            completed.mkdir(parents=True)
            (completed / "2026-05-09-dup.md").write_text(DUPLICATE_STATUS)
            failures = roundtrip.pass_zero_duplicate_keys(td)
            self.assertEqual(len(failures), 1, f"expected 1 failure, got: {failures}")
            self.assertIn("2026-05-09-dup.md", failures[0])
            self.assertIn("status", failures[0])


class TestRoundtripScriptExitCode(unittest.TestCase):
    """Subprocess-level: roundtrip.py must exit non-zero on any duplicate."""

    def test_script_exits_nonzero_on_duplicate(self):
        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            backlog = td / "autonomous" / "backlog"
            backlog.mkdir(parents=True)
            (backlog / "dup-test-item.md").write_text(DUPLICATE_BLOCKED_BY)
            result = subprocess.run(
                [sys.executable, str(THIS_DIR / "roundtrip.py"), str(td)],
                capture_output=True, text=True, timeout=30,
            )
            self.assertNotEqual(result.returncode, 0,
                                f"expected non-zero, got {result.returncode}; stdout={result.stdout!r}")
            self.assertIn("duplicate frontmatter key", result.stdout,
                          f"expected dup-key error in stdout, got: {result.stdout!r}")
            self.assertIn("blocked_by", result.stdout)

    def test_script_exits_zero_on_clean_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            backlog = td / "autonomous" / "backlog"
            backlog.mkdir(parents=True)
            (backlog / "clean-test-item.md").write_text(CLEAN_ITEM)
            result = subprocess.run(
                [sys.executable, str(THIS_DIR / "roundtrip.py"), str(td)],
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0,
                             f"expected exit 0 on clean tree; stdout={result.stdout!r}; stderr={result.stderr!r}")
            self.assertIn("Pass 0", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
