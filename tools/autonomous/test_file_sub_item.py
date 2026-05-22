#!/usr/bin/env python3
"""
Tests for `file_sub_item.py` — the per-item-file emitter the
/senkani-autonomous decompose mode calls once per child during phase 7
synthesis.

These tests assert the load-bearing contracts:
  (a) Happy path: valid frontmatter + scope + acceptance → file written
      with expected sections.
  (b) Idempotency: existing target file → exit code 1, no overwrite.
  (c) Status enum: invalid --status → exit code 2.
  (d) Type enum: invalid --type → exit code 2.
  (e) Missing scope-file → exit code 2.
  (f) Companion-flag invariant: --groomable true with --status open →
      exit code 2.
  (g) Optional fields: --priority + --phase + --tests-target render
      correctly when present and are omitted when absent.

Stdlib-only (`unittest`); no operator setup needed.

Usage:
    python3 tools/autonomous/test_file_sub_item.py
"""
from __future__ import annotations
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent


def _write_tmp(parent: Path, name: str, content: str) -> Path:
    p = parent / name
    p.write_text(content, encoding="utf-8")
    return p


def _run(
    *args: str,
    backlog_dir: Path,
) -> tuple[int, str, str]:
    """Run file_sub_item.py with the given args + a backlog override."""
    cmd = [
        sys.executable,
        str(THIS_DIR / "file_sub_item.py"),
        "--backlog-dir",
        str(backlog_dir),
        *args,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


class TestFileSubItem(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_root = Path(self.tmp.name)
        self.backlog = self.tmp_root / "backlog"
        self.backlog.mkdir()
        self.scope_path = _write_tmp(
            self.tmp_root, "scope.md",
            "Schema migration: 3 tables + indexes.\n",
        )
        self.accept_path = _write_tmp(
            self.tmp_root, "accept.md",
            "- [ ] Tables created.\n- [ ] Indexes present.\n",
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _base_args(self) -> list[str]:
        return [
            "--id", "phase-test-1-schema-migration",
            "--title", "Test child item: schema migration",
            "--status", "open",
            "--type", "feature",
            "--size", "small",
            "--phase", "V",
            "--priority", "P2",
            "--roster", "Majors,Tufte",
            "--affects", "feature_added,session_database",
            "--blocked-by", "phase-v2-canonical-trace-row",
            "--parent-finding", "phase-test-parent — decomposition 2026-05-22 (1 of 3)",
            "--tests-target", "4",
            "--created", "2026-05-22",
            "--last-touched", "2026-05-22",
            "--scope-file", str(self.scope_path),
            "--acceptance-file", str(self.accept_path),
        ]

    def test_happy_path_writes_file(self) -> None:
        rc, stdout, stderr = _run(*self._base_args(), backlog_dir=self.backlog)
        self.assertEqual(rc, 0, msg=f"stderr={stderr!r}")
        target = self.backlog / "phase-test-1-schema-migration.md"
        self.assertTrue(target.exists())
        self.assertIn(str(target.resolve()), stdout)

        text = target.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("---\n"))
        self.assertIn("id: phase-test-1-schema-migration", text)
        self.assertIn("status: open", text)
        self.assertIn("type: feature", text)
        self.assertIn("size: small", text)
        self.assertIn("phase: V", text)
        self.assertIn("priority: P2", text)
        self.assertIn("roster: [Majors, Tufte]", text)
        self.assertIn(
            "affects: [feature_added, session_database]", text,
        )
        self.assertIn(
            "blocked_by: [phase-v2-canonical-trace-row]", text,
        )
        # parent_finding may be unquoted (em-dash + parens are valid in
        # plain YAML scalars); assert the value is present regardless of
        # quoting.
        self.assertIn(
            "parent_finding: phase-test-parent — decomposition 2026-05-22 (1 of 3)",
            text,
        )
        self.assertIn("tests_target: 4", text)
        self.assertIn("\n# Test child item: schema migration\n", text)
        self.assertIn("## Scope\n\nSchema migration: 3 tables", text)
        self.assertIn(
            "## Acceptance\n\n- [ ] Tables created.\n- [ ] Indexes present.",
            text,
        )

    def test_idempotency_refuses_overwrite(self) -> None:
        rc1, _, _ = _run(*self._base_args(), backlog_dir=self.backlog)
        self.assertEqual(rc1, 0)
        rc2, _, stderr2 = _run(*self._base_args(), backlog_dir=self.backlog)
        self.assertEqual(rc2, 1)
        self.assertIn("refuse to overwrite", stderr2)

    def test_invalid_status_exits_2(self) -> None:
        args = self._base_args()
        # Replace --status open with --status bogus
        i = args.index("--status")
        args[i + 1] = "bogus"
        rc, _, stderr = _run(*args, backlog_dir=self.backlog)
        self.assertEqual(rc, 2)
        self.assertIn("--status", stderr)
        self.assertIn("not in taxonomy", stderr)

    def test_invalid_type_exits_2(self) -> None:
        args = self._base_args()
        i = args.index("--type")
        args[i + 1] = "not-a-real-type"
        rc, _, stderr = _run(*args, backlog_dir=self.backlog)
        self.assertEqual(rc, 2)
        self.assertIn("--type", stderr)

    def test_missing_scope_file_exits_2(self) -> None:
        args = self._base_args()
        i = args.index("--scope-file")
        args[i + 1] = str(self.tmp_root / "does-not-exist.md")
        rc, _, stderr = _run(*args, backlog_dir=self.backlog)
        self.assertEqual(rc, 2)
        self.assertIn("--scope-file", stderr)

    def test_groomable_requires_manual_status(self) -> None:
        args = self._base_args() + ["--groomable"]
        # --status is "open" in base_args; --groomable with open should fail
        rc, _, stderr = _run(*args, backlog_dir=self.backlog)
        self.assertEqual(rc, 2)
        self.assertIn("--groomable", stderr)

    def test_optional_fields_omitted_when_unset(self) -> None:
        # Base args minus --phase, --priority, --tests-target.
        args = [
            "--id", "phase-test-min",
            "--title", "Minimal child",
            "--status", "open",
            "--type", "feature",
            "--size", "small",
            "--roster", "Torvalds",
            "--affects", "feature_added",
            "--blocked-by", "",
            "--created", "2026-05-22",
            "--last-touched", "2026-05-22",
            "--scope-file", str(self.scope_path),
            "--acceptance-file", str(self.accept_path),
        ]
        rc, _, stderr = _run(*args, backlog_dir=self.backlog)
        self.assertEqual(rc, 0, msg=f"stderr={stderr!r}")
        text = (self.backlog / "phase-test-min.md").read_text(encoding="utf-8")
        self.assertNotIn("phase:", text)
        self.assertNotIn("priority:", text)
        self.assertNotIn("tests_target:", text)
        self.assertIn("blocked_by: []", text)


if __name__ == "__main__":
    unittest.main()
