#!/usr/bin/env python3
"""
Tests for check-backlog-statuses.py repository-wide decomposition checks.

Usage:
    python3 tools/autonomous/test_check_backlog_statuses.py
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


THIS_DIR = Path(__file__).resolve().parent


def write_item(path: Path, item_id: str, status: str, extra: str = "") -> None:
    path.write_text(
        f"---\n"
        f"id: {item_id}\n"
        f"title: {item_id}\n"
        f"status: {status}\n"
        f"type: feature\n"
        f"size: small\n"
        f"{extra}"
        f"---\n"
        f"# {item_id}\n",
        encoding="utf-8",
    )


def run_check(backlog_dir: Path) -> tuple[int, str, str]:
    proc = subprocess.run(
        [
            sys.executable,
            str(THIS_DIR / "check-backlog-statuses.py"),
            str(backlog_dir),
        ],
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def write_item_with_body(path: Path, item_id: str, status: str, extra: str, body: str) -> None:
    path.write_text(
        f"---\n"
        f"id: {item_id}\n"
        f"title: {item_id}\n"
        f"status: {status}\n"
        f"type: feature\n"
        f"size: small\n"
        f"{extra}"
        f"---\n"
        f"# {item_id}\n"
        f"\n"
        f"{body}\n",
        encoding="utf-8",
    )


class DecomposedParentClosureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.backlog = self.root / "backlog"
        self.completed = self.root / "completed" / "2026"
        self.backlog.mkdir(parents=True)
        self.completed.mkdir(parents=True)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_manual_ready_parent_with_all_done_children_is_flagged(self) -> None:
        write_item(
            self.backlog / "parent.md",
            "parent",
            "manual_ready",
            "decomposed: 2026-05-23\nsplit_into: [child-a, child-b]\n",
        )
        write_item(self.completed / "child-a.md", "child-a", "done")
        write_item(self.completed / "child-b.md", "child-b", "done")

        rc, stdout, stderr = run_check(self.backlog)

        self.assertEqual(rc, 1, msg=f"stdout={stdout!r} stderr={stderr!r}")
        self.assertIn("all children `status: done`", stdout)

    def test_done_parent_with_all_done_children_is_ok(self) -> None:
        write_item(
            self.backlog / "parent.md",
            "parent",
            "done",
            "decomposed: 2026-05-23\nsplit_into: [child-a, child-b]\n",
        )
        write_item(self.completed / "child-a.md", "child-a", "done")
        write_item(self.completed / "child-b.md", "child-b", "done")

        rc, stdout, stderr = run_check(self.backlog)

        self.assertEqual(rc, 0, msg=f"stdout={stdout!r} stderr={stderr!r}")

    def test_manual_ready_parent_with_unfinished_child_is_ok(self) -> None:
        write_item(
            self.backlog / "parent.md",
            "parent",
            "manual_ready",
            "decomposed: 2026-05-23\nsplit_into: [child-a, child-b]\n",
        )
        write_item(self.completed / "child-a.md", "child-a", "done")
        write_item(self.backlog / "child-b.md", "child-b", "open")

        rc, stdout, stderr = run_check(self.backlog)

        self.assertEqual(rc, 0, msg=f"stdout={stdout!r} stderr={stderr!r}")


class CompletedDecomposedParentEvidenceTests(unittest.TestCase):
    """Option-C close-mode auto-stub recognition tests.

    Per `process-gap-close-mode-execution-evidence-invariant-vs-
    decomposed-parent-contract-2026-05-23` (operator chose Option C
    2026-05-24): completed decomposed parents must have at minimum
    an auto-stub `## Execution evidence` section (the close-mode
    sweep appends one). Operator-written evidence also satisfies.
    Absent evidence indicates the sweep bypassed the auto-stub path
    and is a data-hygiene flag.
    """

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.backlog = self.root / "backlog"
        self.completed = self.root / "completed" / "2026"
        self.backlog.mkdir(parents=True)
        self.completed.mkdir(parents=True)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_completed_decomposed_parent_with_auto_stub_evidence_is_ok(self) -> None:
        body = (
            "## Execution evidence 2026-05-24\n\n"
            "Operator confirmed decomposition is correct (decomposed: 2026-05-23, "
            "split_into: [child-a, child-b]). Children shipped independently via "
            "their own build/groom rounds. See `## Proposed decomposition "
            "2026-05-23` for the split record.\n"
        )
        write_item_with_body(
            self.completed / "2026-05-24-parent.md",
            "parent",
            "done",
            "decomposed: 2026-05-23\nsplit_into: [child-a, child-b]\nshipped: 2026-05-24\n",
            body,
        )

        rc, stdout, stderr = run_check(self.backlog)

        self.assertEqual(rc, 0, msg=f"stdout={stdout!r} stderr={stderr!r}")

    def test_completed_decomposed_parent_with_operator_evidence_is_ok(self) -> None:
        body = (
            "## Execution evidence 2026-05-24\n\n"
            "Operator manually verified each child's deliverable matched the "
            "decomposition's acceptance subset. Children shipped 2026-05-22 through "
            "2026-05-23 across commits abc123/def456/ghi789.\n"
        )
        write_item_with_body(
            self.completed / "2026-05-24-parent.md",
            "parent",
            "done",
            "decomposed: 2026-05-23\nsplit_into: [child-a, child-b]\nshipped: 2026-05-24\n",
            body,
        )

        rc, stdout, stderr = run_check(self.backlog)

        self.assertEqual(rc, 0, msg=f"stdout={stdout!r} stderr={stderr!r}")

    def test_completed_decomposed_parent_without_evidence_is_flagged(self) -> None:
        body = (
            "## Proposed decomposition 2026-05-23\n\n"
            "Split into child-a + child-b per operator interview.\n"
        )
        write_item_with_body(
            self.completed / "2026-05-24-parent.md",
            "parent",
            "done",
            "decomposed: 2026-05-23\nsplit_into: [child-a, child-b]\nshipped: 2026-05-24\n",
            body,
        )

        rc, stdout, stderr = run_check(self.backlog)

        self.assertEqual(rc, 1, msg=f"stdout={stdout!r} stderr={stderr!r}")
        self.assertIn("no `## Execution evidence`", stdout)
        self.assertIn("Option-C close-mode auto-stub", stdout)

    def test_completed_non_decomposed_item_without_evidence_is_ok(self) -> None:
        # Items that did NOT come through decompose-mode never had a
        # `decomposed:` field; the check should skip them.
        body = "Some body without an evidence heading.\n"
        write_item_with_body(
            self.completed / "2026-05-24-regular-item.md",
            "regular-item",
            "done",
            "shipped: 2026-05-24\n",
            body,
        )

        rc, stdout, stderr = run_check(self.backlog)

        self.assertEqual(rc, 0, msg=f"stdout={stdout!r} stderr={stderr!r}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
