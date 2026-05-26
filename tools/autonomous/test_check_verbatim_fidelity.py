#!/usr/bin/env python3
"""
Tests for `check_verbatim_fidelity.py` — the helper that asserts a
hand-pasted block in a target file is byte-for-byte the staged
verbatim text.

Originating item:
`process-gap-operator-hand-edit-verbatim-fidelity-unverified-2026-05-26`.

The three defect classes the originating finding names (and the
helper MUST catch) are pinned by dedicated tests:
    1. match        — identical paste -> identical, exit 0.
    2. dropped line  — a list bullet removed -> line_count_mismatch, exit 1.
    3. reflowed line — two lines joined into one -> mismatch, exit 1.

Plus the structural-correctness cases Torvalds/Kleppmann flagged:
    4. paraphrase    — same line count, differing content -> content_mismatch.
    5. block-not-found — start marker absent -> block_not_found, exit 1.
    6. ambiguous start marker — >1 start match -> ambiguous_start_marker.
    7. end-marker exclusive boundary — the end line is NOT in the block.
    8. trailing-final-newline normalized — newline-only delta is NOT a defect.
    9. internal blank line preserved — a content-bearing blank line IS compared.
   10. JSON output shape (Kleppmann audit-trail invariant).

Stdlib-only (`unittest`); no operator setup needed.

Usage:
    python3 tools/autonomous/test_check_verbatim_fidelity.py
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
import check_verbatim_fidelity as cvf  # type: ignore  # noqa: E402

HELPER = THIS_DIR / "check_verbatim_fidelity.py"

# A representative staged block: the start-marker line plus a small
# multi-line body including a list bullet and a long line — the shapes
# the originating finding's dropped-bullet + reflow defects hit.
STAGED_BLOCK = (
    "5.7. **External-surfaces check.** Before running the interview, call\n"
    "     the external-surfaces scanner:\n"
    "\n"
    "     * status: in_progress -> status: manual\n"
    "     * add scope_groomable: true (preserve any existing flag)\n"
    "     This is a deliberately long line meant to be reflowed by a "
    "careless paste into two physical lines, which the helper must catch.\n"
)

START = r"^5\.7\. \*\*External-surfaces check\.\*\*"
END = r"^6\. \*\*Run the interview\*\*"

# The surrounding target context (phase 5 before, phase 6 after) so the
# end marker is exercised as an exclusive boundary.
TARGET_PREFIX = (
    "### Phase order (scope-groom mode)\n"
    "\n"
    "5. **Audit the questions** — same roster.\n"
    "\n"
)
TARGET_SUFFIX = (
    "6. **Run the interview** — call AskUserQuestion.\n"
    "\n"
    "7. **Synthesis** — translate answers.\n"
)


def _write(tmp: Path, name: str, text: str) -> Path:
    p = tmp / name
    p.write_text(text, encoding="utf-8")
    return p


def _run(staged: Path, target: Path, *, start: str = START,
         end: str | None = END, include_end: bool = False) -> tuple[int, dict]:
    cmd = [sys.executable, str(HELPER),
           "--staged", str(staged), "--target", str(target),
           "--start-marker", start]
    if end is not None:
        cmd += ["--end-marker", end]
    if include_end:
        cmd.append("--include-end-marker")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode == 2:
        raise RuntimeError(f"helper error: {proc.stderr}")
    return proc.returncode, json.loads(proc.stdout)


class TestVerbatimFidelity(unittest.TestCase):

    def test_match_is_identical(self) -> None:
        """Defect class 0 (the happy path): a verbatim paste extracts to
        exactly the staged block -> identical, exit 0, empty diff."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            staged = _write(tmp, "staged.txt", STAGED_BLOCK)
            target = _write(tmp, "target.md",
                            TARGET_PREFIX + STAGED_BLOCK + TARGET_SUFFIX)
            rc, out = _run(staged, target)
            self.assertEqual(rc, 0, "exit 0 when identical")
            self.assertTrue(out["identical"])
            self.assertFalse(out["should_fire"])
            self.assertEqual(out["reasons"], [])
            self.assertEqual(out["diff"], "")
            self.assertIsNone(out["first_diff_line"])

    def test_dropped_line_fails(self) -> None:
        """Defect class 1: the paste dropped the `add scope_groomable`
        bullet. Line count differs -> line_count_mismatch, exit 1."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            staged = _write(tmp, "staged.txt", STAGED_BLOCK)
            dropped = STAGED_BLOCK.replace(
                "     * add scope_groomable: true (preserve any existing flag)\n",
                "")
            target = _write(tmp, "target.md",
                            TARGET_PREFIX + dropped + TARGET_SUFFIX)
            rc, out = _run(staged, target)
            self.assertEqual(rc, 1, "exit 1 when a line was dropped")
            self.assertFalse(out["identical"])
            kinds = {r["kind"] for r in out["reasons"]}
            self.assertIn("line_count_mismatch", kinds)
            self.assertLess(out["landed_line_count"], out["staged_line_count"])
            self.assertIsNotNone(out["first_diff_line"])
            self.assertNotEqual(out["diff"], "")

    def test_reflowed_line_fails(self) -> None:
        """Defect class 2: the long final line was reflowed into two
        physical lines. Boundaries move -> mismatch, exit 1."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            staged = _write(tmp, "staged.txt", STAGED_BLOCK)
            reflowed = STAGED_BLOCK.replace(
                "     This is a deliberately long line meant to be reflowed by "
                "a careless paste into two physical lines, which the helper "
                "must catch.\n",
                "     This is a deliberately long line meant to be reflowed by "
                "a careless paste\n"
                "     into two physical lines, which the helper must catch.\n")
            target = _write(tmp, "target.md",
                            TARGET_PREFIX + reflowed + TARGET_SUFFIX)
            rc, out = _run(staged, target)
            self.assertEqual(rc, 1, "exit 1 when a line was reflowed")
            self.assertFalse(out["identical"])
            self.assertNotEqual(out["reasons"], [])
            self.assertNotEqual(out["diff"], "")

    def test_paraphrase_fails(self) -> None:
        """Defect class 3: same line count, but a word changed. The
        content_mismatch branch fires (count equal, content differs)."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            staged = _write(tmp, "staged.txt", STAGED_BLOCK)
            paraphrased = STAGED_BLOCK.replace(
                "     * status: in_progress -> status: manual\n",
                "     * status: in_progress becomes status: manual\n")
            target = _write(tmp, "target.md",
                            TARGET_PREFIX + paraphrased + TARGET_SUFFIX)
            rc, out = _run(staged, target)
            self.assertEqual(rc, 1, "exit 1 on paraphrase")
            kinds = {r["kind"] for r in out["reasons"]}
            self.assertIn("content_mismatch", kinds)
            self.assertEqual(out["landed_line_count"], out["staged_line_count"])

    def test_block_not_found(self) -> None:
        """Start marker matches nothing -> block_not_found, exit 1.
        block_found is False, landed_line_count null."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            staged = _write(tmp, "staged.txt", STAGED_BLOCK)
            target = _write(tmp, "target.md", TARGET_PREFIX + TARGET_SUFFIX)
            rc, out = _run(staged, target)
            self.assertEqual(rc, 1)
            self.assertFalse(out["block_found"])
            self.assertEqual(out["start_match_count"], 0)
            self.assertIsNone(out["landed_line_count"])
            kinds = {r["kind"] for r in out["reasons"]}
            self.assertIn("block_not_found", kinds)

    def test_ambiguous_start_marker(self) -> None:
        """The start marker matches two lines -> ambiguous_start_marker
        reason (first match used for extraction), exit 1."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            staged = _write(tmp, "staged.txt", STAGED_BLOCK)
            # Two copies of the block -> two start-marker matches.
            target = _write(
                tmp, "target.md",
                TARGET_PREFIX + STAGED_BLOCK + "\n" + STAGED_BLOCK + "\n"
                + TARGET_SUFFIX)
            rc, out = _run(staged, target)
            self.assertEqual(rc, 1)
            self.assertEqual(out["start_match_count"], 2)
            kinds = {r["kind"] for r in out["reasons"]}
            self.assertIn("ambiguous_start_marker", kinds)

    def test_end_marker_is_exclusive(self) -> None:
        """The end-marker line MUST NOT be part of the extracted block
        (awk idiom). With a clean paste, exclusion yields identical."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            staged = _write(tmp, "staged.txt", STAGED_BLOCK)
            # No blank gutter before phase 6 — proves the boundary is the
            # marker, not a blank line.
            target = _write(tmp, "target.md",
                            TARGET_PREFIX + STAGED_BLOCK + TARGET_SUFFIX)
            rc, out = _run(staged, target)
            self.assertEqual(rc, 0, "end marker excluded -> identical")
            self.assertTrue(out["end_marker_found"])

    def test_include_end_marker_changes_block(self) -> None:
        """--include-end-marker pulls the phase-6 line into the block, so
        the same staged text (which lacks it) now mismatches."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            staged = _write(tmp, "staged.txt", STAGED_BLOCK)
            target = _write(tmp, "target.md",
                            TARGET_PREFIX + STAGED_BLOCK + TARGET_SUFFIX)
            rc, out = _run(staged, target, include_end=True)
            self.assertEqual(rc, 1)
            self.assertTrue(out["include_end_marker"])
            self.assertGreater(out["landed_line_count"], out["staged_line_count"])

    def test_trailing_final_newline_normalized(self) -> None:
        """A staged file that lacks the single trailing newline the landed
        block has (or vice versa) is NOT a content defect — splitlines
        normalizes the final terminator. Identical, exit 0."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            # staged has no trailing newline; target block does.
            staged = _write(tmp, "staged.txt", STAGED_BLOCK.rstrip("\n"))
            target = _write(tmp, "target.md",
                            TARGET_PREFIX + STAGED_BLOCK + TARGET_SUFFIX)
            rc, out = _run(staged, target)
            self.assertEqual(rc, 0, "final-newline delta is not a defect")
            self.assertTrue(out["identical"])

    def test_internal_blank_line_is_compared(self) -> None:
        """An internal (content-bearing) blank line is preserved by
        splitlines and therefore still compared: dropping the blank line
        between the scanner sentence and the first bullet is a defect."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            staged = _write(tmp, "staged.txt", STAGED_BLOCK)
            # Remove the internal blank line (line 3 of STAGED_BLOCK).
            no_blank = STAGED_BLOCK.replace(
                "     the external-surfaces scanner:\n"
                "\n"
                "     * status: in_progress -> status: manual\n",
                "     the external-surfaces scanner:\n"
                "     * status: in_progress -> status: manual\n")
            target = _write(tmp, "target.md",
                            TARGET_PREFIX + no_blank + TARGET_SUFFIX)
            rc, out = _run(staged, target)
            self.assertEqual(rc, 1, "internal blank line drop is a defect")
            self.assertFalse(out["identical"])

    def test_no_end_marker_runs_to_eof(self) -> None:
        """With no --end-marker, the block runs to EOF. Staged text that
        equals start-line..EOF is identical; end_marker_found is null."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            # Block-to-EOF: staged is the block plus everything after it.
            tail = STAGED_BLOCK + "\n" + TARGET_SUFFIX
            staged = _write(tmp, "staged.txt", tail)
            target = _write(tmp, "target.md", TARGET_PREFIX + tail)
            rc, out = _run(staged, target, end=None)
            self.assertEqual(rc, 0)
            self.assertIsNone(out["end_marker_found"])
            self.assertIsNone(out["end_marker"])

    def test_json_output_shape(self) -> None:
        """Kleppmann audit-trail invariant: the JSON output carries every
        documented field so a walk (and future audits) can read counts,
        first-diff line, reasons, and the full diff."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            staged = _write(tmp, "staged.txt", STAGED_BLOCK)
            dropped = STAGED_BLOCK.replace(
                "     * add scope_groomable: true (preserve any existing flag)\n",
                "")
            target = _write(tmp, "target.md",
                            TARGET_PREFIX + dropped + TARGET_SUFFIX)
            _, out = _run(staged, target)
            for key in ("staged", "target", "start_marker", "end_marker",
                        "include_end_marker", "block_found", "start_match_count",
                        "end_marker_found", "identical", "should_fire",
                        "staged_line_count", "landed_line_count",
                        "first_diff_line", "reasons", "diff"):
                self.assertIn(key, out, f"missing JSON key: {key}")
            self.assertEqual(out["should_fire"], not out["identical"])
            for r in out["reasons"]:
                self.assertIn("kind", r)
                self.assertIn("detail", r)


if __name__ == "__main__":
    unittest.main(verbosity=2)
