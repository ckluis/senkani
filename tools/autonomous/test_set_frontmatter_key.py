#!/usr/bin/env python3
"""
Tests for `set_frontmatter_key.py` — the single-write helper that
close-mode rounds (build, groom, scope-groom, abort+split) MUST use to
write `tests_delta:`, `docs_synced:`, `shipped:`, etc., instead of
blindly appending.

The originating finding is
`process-gap-close-mode-duplicate-frontmatter-keys-2026-05-20`:
two recent close rounds produced files with duplicated
`tests_delta:` and `docs_synced:` keys because the trailing scope-
groom defaults written at an earlier round were not removed when the
later close round appended its load-bearing values.

These tests assert the helper's three load-bearing contracts:
  (a) Appends when the key is absent.
  (b) Replaces in-place when the key is present exactly once.
  (c) Dedupes when the key is present multiple times — keeping the
      first occurrence (with new value) and dropping later copies.

Stdlib-only (`unittest`); no operator setup needed.

Usage:
    python3 tools/autonomous/test_set_frontmatter_key.py
"""
from __future__ import annotations
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))
import set_frontmatter_key as sfk  # type: ignore  # noqa: E402
import roundtrip  # type: ignore  # noqa: E402


FRESH_ITEM = """\
---
id: fresh-item
title: "Fresh item with no tests_delta or docs_synced yet"
status: in_progress
type: hygiene
size: tiny
roster: [Torvalds]
affects: [feature_changed]
blocked_by: []
created: 2026-05-20
last_touched: 2026-05-20
---

# Fresh item

## Scope
Nothing shipped yet.
"""

ITEM_WITH_BOTH_KEYS = """\
---
id: scope-groomed-then-closed
title: "Item with scope-groom defaults left at bottom"
status: in_progress
type: feature
size: medium
roster: [Schneier]
affects: [feature_added]
blocked_by: []
scope_groomable: true
scope_groomed: 2026-05-06
scope_groomed_by: senkani-autonomous
tests_delta: "n/a (scope decisions only, no code shipped)"
docs_synced: []
created: 2026-05-01
last_touched: 2026-05-20
---

# Mixed item

## Scope
Already scope-groomed; now ready to close as shipped.
"""

ITEM_WITH_DUPED_KEYS = """\
---
id: already-duped
title: "File where two close rounds already double-wrote"
status: done
shipped: 2026-05-20
tests_delta: "2878 → 2888 (+10)"
docs_synced: [CHANGELOG.md]
type: infra
size: meaty
roster: [Kleppmann]
affects: [feature_added]
blocked_by: []
tests_target: 10
tests_delta: "n/a (scope decisions only, no code shipped)"
docs_synced: []
created: 2026-05-03
last_touched: 2026-05-20
---

# Already-duped item

## Scope
This file already has duplicate `tests_delta` and `docs_synced` keys
from two prior close rounds. The helper must dedupe on write.
"""


class TestSetKeyAppendsWhenAbsent(unittest.TestCase):
    """(a) — single-write helper appends when key is absent."""

    def test_appends_tests_delta_to_fresh_item(self):
        out = sfk.set_key(FRESH_ITEM, "tests_delta", '"2900 → 2905 (+5)"')
        # Key appears exactly once.
        self.assertEqual(out.count("\ntests_delta:"), 1)
        self.assertIn('tests_delta: "2900 → 2905 (+5)"', out)
        # roundtrip Pass 0 must agree it's not a dupe.
        self.assertEqual(roundtrip.find_duplicate_frontmatter_keys(out), [])

    def test_appends_docs_synced_inline_list(self):
        out = sfk.set_key(FRESH_ITEM, "docs_synced", "[CHANGELOG.md, README.md]")
        self.assertEqual(out.count("\ndocs_synced:"), 1)
        self.assertIn("docs_synced: [CHANGELOG.md, README.md]", out)

    def test_body_is_preserved_verbatim(self):
        out = sfk.set_key(FRESH_ITEM, "shipped", "2026-05-20")
        # H2 + body content unchanged below the `---` close.
        self.assertIn("# Fresh item", out)
        self.assertIn("## Scope\nNothing shipped yet.", out)


class TestSetKeyReplacesInPlace(unittest.TestCase):
    """(b) — single-write helper replaces in-place when key is present."""

    def test_replaces_existing_single_tests_delta(self):
        out = sfk.set_key(
            ITEM_WITH_BOTH_KEYS,
            "tests_delta",
            '"2900 → 2910 (+10)"',
        )
        # Exactly one occurrence — the in-place replacement.
        self.assertEqual(out.count("\ntests_delta:"), 1)
        # Old value is GONE.
        self.assertNotIn("n/a (scope decisions only", out)
        # New value present.
        self.assertIn('tests_delta: "2900 → 2910 (+10)"', out)
        # roundtrip Pass 0 agrees.
        self.assertEqual(roundtrip.find_duplicate_frontmatter_keys(out), [])

    def test_replaces_existing_single_docs_synced(self):
        out = sfk.set_key(
            ITEM_WITH_BOTH_KEYS,
            "docs_synced",
            "[CHANGELOG.md, spec/autonomous/PROCESS.md]",
        )
        self.assertEqual(out.count("\ndocs_synced:"), 1)
        self.assertIn("docs_synced: [CHANGELOG.md, spec/autonomous/PROCESS.md]", out)

    def test_position_of_first_occurrence_preserved(self):
        # The replacement happens at the location of the FIRST
        # occurrence — the relative ordering of other keys is intact.
        before = ITEM_WITH_BOTH_KEYS
        out = sfk.set_key(before, "tests_delta", '"99 → 100 (+1)"')
        # `scope_groomed:` appears before `tests_delta:` in the
        # source; the replacement must preserve that order.
        scope_idx = out.find("scope_groomed:")
        td_idx = out.find("tests_delta:")
        last_touched_idx = out.find("last_touched:")
        self.assertLess(scope_idx, td_idx)
        self.assertLess(td_idx, last_touched_idx)


class TestSetKeyDedupesExistingDupes(unittest.TestCase):
    """(c) — single-write helper dedupes when key is duplicated."""

    def test_dedupes_two_tests_delta_keeping_new_value(self):
        # Pre-condition: file has dupes.
        self.assertEqual(
            roundtrip.find_duplicate_frontmatter_keys(ITEM_WITH_DUPED_KEYS),
            ["tests_delta", "docs_synced"],
        )
        out = sfk.set_key(
            ITEM_WITH_DUPED_KEYS,
            "tests_delta",
            '"2878 → 2888 (+10)"',
        )
        self.assertEqual(out.count("\ntests_delta:"), 1)
        # The stale "scope decisions only" copy is gone.
        self.assertNotIn("n/a (scope decisions only", out)
        # The new value is present.
        self.assertIn('tests_delta: "2878 → 2888 (+10)"', out)

    def test_dedupes_two_docs_synced(self):
        out = sfk.set_key(
            ITEM_WITH_DUPED_KEYS,
            "docs_synced",
            "[CHANGELOG.md]",
        )
        self.assertEqual(out.count("\ndocs_synced:"), 1)

    def test_repairs_both_keys_via_two_calls(self):
        # End-to-end repair flow — two helper calls, one per key —
        # leaves the file dupe-free per roundtrip Pass 0.
        step1 = sfk.set_key(ITEM_WITH_DUPED_KEYS, "tests_delta", '"2878 → 2888 (+10)"')
        step2 = sfk.set_key(step1, "docs_synced", "[CHANGELOG.md]")
        self.assertEqual(roundtrip.find_duplicate_frontmatter_keys(step2), [])


class TestCLIIntegration(unittest.TestCase):
    """Subprocess-level: the CLI helper invocation pattern close-mode
    rounds use must produce dupe-free files end-to-end."""

    def test_cli_dedupes_known_affected_fixture(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "fixture.md"
            f.write_text(ITEM_WITH_DUPED_KEYS)
            # Pre-condition: dupes present.
            self.assertEqual(len(roundtrip.find_duplicate_frontmatter_keys(f.read_text())), 2)
            # Run the helper twice — once per key.
            for key, value in (
                ("tests_delta", '"2878 → 2888 (+10)"'),
                ("docs_synced", "[CHANGELOG.md]"),
            ):
                result = subprocess.run(
                    [sys.executable, str(THIS_DIR / "set_frontmatter_key.py"), str(f), key, value],
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0,
                                 f"helper exit non-zero: stderr={result.stderr!r}")
            # Post-condition: roundtrip Pass 0 green.
            self.assertEqual(roundtrip.find_duplicate_frontmatter_keys(f.read_text()), [])

    def test_cli_empty_list_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "fixture.md"
            f.write_text(FRESH_ITEM)
            result = subprocess.run(
                [sys.executable, str(THIS_DIR / "set_frontmatter_key.py"),
                 str(f), "docs_synced", "--empty-list"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("docs_synced: []", f.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
