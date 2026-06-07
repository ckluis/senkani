#!/usr/bin/env python3
"""
Tests for `check_categorical_block.py` — the helper that scope-groom
mode invokes between phase 7 (Synthesis from answers) and phase 8
(Re-audit) to detect Acceptance content matching categorically-non-
autonomous action patterns.

Originating item:
`process-gap-build-round-categorical-action-vetting-2026-05-07`.

The helper itself returns a deterministic JSON record + exit code.
These tests assert the seven Acceptance scenarios from that item
plus an output-shape contract Schneier raised in audit: the JSON
must carry enough detail (pattern name, regex, matched excerpt,
line number, section heading) for SKILL.md's override prompt body
section to render a complete audit record.

Stdlib-only (`unittest`); no operator setup needed.

Usage:
    python3 tools/autonomous/test_check_categorical_block.py
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
import check_categorical_block as ccb  # type: ignore  # noqa: E402


HELPER = THIS_DIR / "check_categorical_block.py"


def _write_item(tmpdir: Path, body: str, name: str = "test-item.md") -> Path:
    path = tmpdir / name
    path.write_text(
        "---\n"
        "id: test-item\n"
        "title: 'Test item'\n"
        "status: in_progress\n"
        "---\n\n"
        + body,
        encoding="utf-8",
    )
    return path


def _run(item: Path, manifest: Path | None = None) -> tuple[int, dict]:
    cmd = [sys.executable, str(HELPER), str(item)]
    if manifest is not None:
        cmd.extend(["--manifest", str(manifest)])
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode == 2:
        raise RuntimeError(f"helper error: {proc.stderr}")
    return proc.returncode, json.loads(proc.stdout)


class TestCategoricalBlockHelper(unittest.TestCase):

    def test_acceptance_5_multi_pattern_match_all_listed(self) -> None:
        """Acceptance scenario 5: multi-pattern match — all matches
        listed in the JSON output, prompt asked once (SKILL.md
        responsibility; helper just lists them)."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            body = (
                "## Acceptance\n"
                "- [ ] Run `git push origin main` after the rebase\n"
                "- [ ] Then `gh pr merge --auto` the staged PR\n"
                "- [ ] Bump `Package.resolved` to pin the mlx-swift-lm SHA\n"
            )
            item = _write_item(tmp, body)
            rc, out = _run(item)
            self.assertEqual(rc, 1, "exit 1 when matches found")
            matched_names = {m["pattern_name"] for m in out["matched"]}
            self.assertIn("git-push-to-protected-branch", matched_names)
            self.assertIn("gh-pr-merge-into-protected", matched_names)
            self.assertIn("package-resolved-dep-pin-edit", matched_names)
            self.assertGreaterEqual(len(out["matched"]), 3)

    def test_acceptance_3_no_match_clean_pass(self) -> None:
        """Acceptance scenario 3: no match → exit 0, scope-groom
        flips to `open` without an override prompt."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            body = (
                "## Acceptance\n"
                "- [ ] Add a Swift unit test for `TokenFilter.scrub`\n"
                "- [ ] Run `swift test --filter TokenFilterTests`\n"
                "- [ ] Update `spec/architecture.md` with the new contract\n"
            )
            item = _write_item(tmp, body)
            rc, out = _run(item)
            self.assertEqual(rc, 0, "exit 0 when no matches")
            self.assertEqual(out["matched"], [])

    def test_acceptance_1_pattern_match_skill_md_self_edit(self) -> None:
        """Pattern #3 (meta-recursive SKILL.md edit) fires on items
        whose Acceptance proposes editing the loop's own playbook.
        This is the trigger that the 2026-05-07 abort note named
        explicitly as out-of-envelope."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            body = (
                "## Acceptance\n"
                "- [ ] Document the new safety guard in "
                "`~/.claude/skills/senkani-autonomous/SKILL.md`\n"
            )
            item = _write_item(tmp, body)
            rc, out = _run(item)
            self.assertEqual(rc, 1)
            self.assertEqual(len(out["matched"]), 1)
            self.assertEqual(out["matched"][0]["pattern_name"],
                             "skill-md-self-edit")

    def test_acceptance_6_manifest_merge_adds_operator_patterns(self) -> None:
        """Acceptance scenario 6: operator-added regex matches are
        detected alongside skill defaults; defaults still fire when
        manifest list is empty. Set-union merge."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            manifest = tmp / "manifest.yaml"
            manifest.write_text(
                "version: 2\n"
                "scope_groom:\n"
                "  categorical_block:\n"
                "    - name: ship-to-staging-bucket\n"
                "      regex: 'aws s3 cp .* s3://prod-staging/'\n"
                "    - name: kubernetes-context-switch\n"
                "      regex: 'kubectl config use-context prod'\n",
                encoding="utf-8",
            )
            body = (
                "## Acceptance\n"
                "- [ ] Run `aws s3 cp build.tar s3://prod-staging/`\n"
                "- [ ] Then `kubectl config use-context prod` to flip\n"
                "- [ ] Also `gh pr merge` afterwards\n"
            )
            item = _write_item(tmp, body)
            rc, out = _run(item, manifest=manifest)
            self.assertEqual(rc, 1)
            matched_names = {m["pattern_name"] for m in out["matched"]}
            self.assertIn("ship-to-staging-bucket", matched_names)
            self.assertIn("kubernetes-context-switch", matched_names)
            self.assertIn("gh-pr-merge-into-protected", matched_names,
                          "defaults still fire alongside manifest")
            self.assertEqual(out["manifest_patterns_total"], 2)
            self.assertEqual(out["default_patterns_total"], 8)

    def test_acceptance_6_empty_manifest_block_keeps_defaults(self) -> None:
        """Defaults-only mode: manifest entry omitted entirely is
        equivalent to the eight skill defaults."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            manifest = tmp / "manifest.yaml"
            manifest.write_text(
                "version: 2\n"
                "project: test\n",
                encoding="utf-8",
            )
            body = (
                "## Acceptance\n"
                "- [ ] sudo systemctl restart launchd\n"
            )
            item = _write_item(tmp, body)
            rc, out = _run(item, manifest=manifest)
            self.assertEqual(rc, 1)
            self.assertEqual(out["manifest_patterns_total"], 0)
            self.assertEqual(out["default_patterns_total"], 8)
            self.assertEqual(out["matched"][0]["pattern_name"],
                             "sudo-invocation")

    def test_acceptance_7_settings_local_marker_exception(self) -> None:
        """Pattern #6 (settings.local.json edits) has a marker
        exception: edits to lines tagged with `// scope-groom-managed:`
        (from the sibling item's narrow-rule writer) do NOT trigger.
        Edits OUTSIDE marker-tagged context DO trigger."""
        marker = ccb.SCOPE_GROOM_MARKER
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)

            body_with_marker = (
                "## Acceptance\n"
                f"- [ ] Append to `.claude/settings.local.json` {marker} <id>\n"
            )
            item = _write_item(tmp, body_with_marker, name="marker.md")
            rc, out = _run(item)
            self.assertEqual(rc, 0, "marker-tagged edits do NOT trigger")
            self.assertEqual(out["matched"], [])

            body_no_marker = (
                "## Acceptance\n"
                "- [ ] Manually edit `.claude/settings.local.json` to add "
                "the Bash rule allowing `gh issue create`\n"
            )
            item2 = _write_item(tmp, body_no_marker, name="nomarker.md")
            rc2, out2 = _run(item2)
            self.assertEqual(rc2, 1, "untagged edits DO trigger")
            self.assertEqual(out2["matched"][0]["pattern_name"],
                             "settings-local-edit-without-marker")

    def test_acceptance_1_and_2_default_patterns_all_eight_compile(self) -> None:
        """Acceptance scenario 1 + 2: eight defaults documented and
        all compile to working regexes. Sanity-checks the helper's
        floor; if a pattern source is malformed the helper would
        crash at import."""
        patterns = ccb.default_patterns()
        self.assertEqual(len(patterns), 8)
        names = {p["name"] for p in patterns}
        expected = {
            "git-push-to-protected-branch",
            "gh-pr-merge-into-protected",
            "skill-md-self-edit",
            "git-hooks-or-ci-workflows-edit",
            "rm-rf-against-sensitive-tree",
            "settings-local-edit-without-marker",
            "package-resolved-dep-pin-edit",
            "sudo-invocation",
        }
        self.assertEqual(names, expected)
        for p in patterns:
            self.assertIsNotNone(p["regex"].pattern)

    def test_schneier_output_shape_carries_audit_detail(self) -> None:
        """Schneier clash: the override path is a security pressure-
        relief valve. Helper output MUST carry enough match detail
        (pattern_name, regex, matched_excerpt, line, section) for
        SKILL.md's override body section to render a complete audit
        record. Silent-allow-by-override is the failure mode this
        test guards against."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            body = (
                "## Scope\n"
                "Set up the new CI job.\n\n"
                "## Acceptance\n"
                "- [ ] Edit `.github/workflows/release.yml` to add the "
                "publish step\n"
            )
            item = _write_item(tmp, body)
            rc, out = _run(item)
            self.assertEqual(rc, 1)
            self.assertEqual(len(out["matched"]), 1)
            m = out["matched"][0]
            for field in ("pattern_id", "pattern_name", "regex",
                          "matched_excerpt", "line", "section"):
                self.assertIn(field, m,
                              f"audit-detail field '{field}' missing")
            self.assertEqual(m["pattern_name"],
                             "git-hooks-or-ci-workflows-edit")
            self.assertEqual(m["section"], "## Acceptance")
            self.assertGreater(m["line"], 0)
            self.assertIn(".github/workflows/", m["matched_excerpt"])
            self.assertEqual(out["marker_constant"], ccb.SCOPE_GROOM_MARKER,
                             "marker constant exported for sibling import")


if __name__ == "__main__":
    unittest.main(verbosity=2)
