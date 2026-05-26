#!/usr/bin/env python3
"""
Tests for `check_observation_only.py` — the matcher behind the
`/senkani-autonomous` Step 3 observation-only pre-pick fail-safe.

Originating finding:
`process-gap-prepick-failsafe-sentinel-false-positive-on-self-reference-2026-05-26`
— the crude "any sentinel substring = hit" rule false-positived on an
acceptance bullet that referenced the fail-safe by name. These tests
lock the three mandated contracts plus edge cases:

  (a) A genuine observation-only acceptance bullet STILL fires (exit 1).
  (b) A bullet that only NAMES the fail-safe does NOT fire (exit 0).
  (c) The phase-v13-dangling bullet-4 text specifically does NOT fire.

Both subprocess (exit-code contract) and in-process (function-level
precision) tests are present. Stdlib-only (`unittest`).

Usage:
    python3 tools/autonomous/test_check_observation_only.py
"""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
HELPER = THIS_DIR / "check_observation_only.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("check_observation_only", HELPER)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


coo = _load_module()


def run(path: Path) -> tuple[str, str, int]:
    """Invoke the helper; return (stdout, stderr, exit_code)."""
    proc = subprocess.run(
        [sys.executable, str(HELPER), str(path)],
        capture_output=True,
        text=True,
    )
    return proc.stdout, proc.stderr, proc.returncode


def _item(acceptance_body: str, status: str = "open") -> str:
    return (
        "---\n"
        "id: fixture\n"
        f"status: {status}\n"
        "type: process\n"
        "---\n\n"
        "# Fixture\n\n"
        "## Acceptance\n\n"
        f"{acceptance_body}\n\n"
        "## Notes\n\nUnrelated trailing section.\n"
    )


def _write(text: str) -> Path:
    f = tempfile.NamedTemporaryFile(
        mode="w", suffix=".md", delete=False, encoding="utf-8"
    )
    f.write(text)
    f.close()
    return Path(f.name)


# The literal phase-v13-dangling bullet 4 (contract (c)).
PHASE_V13_BULLET_4 = (
    "- [ ] `backlog/index.md` regenerated; if the phase-v13 fix makes it "
    "build-pickable (all blockers now `done`), confirm it appears correctly "
    "and note that build mode will pick it on a future round (subject to the "
    "**observation-only pre-pick fail-safe**)."
)

# This item's own bullet 1 — all `observation-only` occurrences are
# mechanism-name self-references.
THIS_ITEM_BULLET_1 = (
    '- [ ] SKILL.md Step 3\'s "Observation-only pre-pick fail-safe (build '
    'mode only)" match rule no longer fires on acceptance bullets whose '
    "sentinel-phrase occurrence is a self-reference to the fail-safe / hook "
    'mechanism itself (e.g. the literal phrases "observation-only pre-pick '
    'fail-safe", "Step 2.5 ... hook", "observation-only ... fail-safe").'
)


class GenuineFiresTests(unittest.TestCase):
    """Contract (a): real observation-over-time acceptance still fires."""

    def test_observation_only_genuine_fires(self) -> None:
        body = (
            "- [ ] Merge, then confirm the fix holds via observation-only "
            "monitoring across the next release window."
        )
        path = _write(_item(body))
        try:
            out, _, rc = run(path)
            self.assertEqual(rc, 1, out)
            self.assertIn('"is_observation_only": true', out)
        finally:
            path.unlink(missing_ok=True)

    def test_observation_over_time_genuine_fires(self) -> None:
        body = "- [ ] Stability confirmed by observation-over-time, not a unit test."
        path = _write(_item(body))
        try:
            _, _, rc = run(path)
            self.assertEqual(rc, 1)
        finally:
            path.unlink(missing_ok=True)

    def test_watch_over_n_runs_fires(self) -> None:
        body = "- [ ] Watch over 5 CI runs; zero SIGTRAP retries observed."
        path = _write(_item(body))
        try:
            _, _, rc = run(path)
            self.assertEqual(rc, 1)
        finally:
            path.unlink(missing_ok=True)

    def test_n_consecutive_green_fires(self) -> None:
        body = "- [ ] 5 consecutive CI green runs after the chunking change."
        path = _write(_item(body))
        try:
            _, _, rc = run(path)
            self.assertEqual(rc, 1)
        finally:
            path.unlink(missing_ok=True)

    def test_genuine_fires_even_when_hook_is_far_away(self) -> None:
        """The `hook` guard token is a common word; it must NOT swallow a
        genuine observation bullet where the nearest `hook` is 3+ words
        from the sentinel."""
        body = (
            "- [ ] Watch over 5 CI runs; if the PreToolUse hook ever blocks, "
            "treat the run as a failure."
        )
        path = _write(_item(body))
        try:
            out, _, rc = run(path)
            self.assertEqual(rc, 1, out)
        finally:
            path.unlink(missing_ok=True)


class SelfReferenceDoesNotFireTests(unittest.TestCase):
    """Contract (b)/(c): mechanism-name self-references do NOT fire."""

    def test_phase_v13_bullet_4_does_not_fire(self) -> None:
        """Contract (c), verbatim."""
        path = _write(_item(PHASE_V13_BULLET_4))
        try:
            out, _, rc = run(path)
            self.assertEqual(rc, 0, out)
            self.assertIn('"is_observation_only": false', out)
            # It IS recorded as a self-reference (audit visibility).
            self.assertIn('"self_references"', out)
        finally:
            path.unlink(missing_ok=True)

    def test_this_item_bullet_1_does_not_fire(self) -> None:
        """The fixing item's own bullet 1 must not reclassify itself."""
        path = _write(_item(THIS_ITEM_BULLET_1))
        try:
            _, _, rc = run(path)
            self.assertEqual(rc, 0)
        finally:
            path.unlink(missing_ok=True)

    def test_pre_pick_failsafe_phrase_self_ref(self) -> None:
        body = "- [ ] Subject to the observation-only pre-pick fail-safe."
        result = coo.classify(f"{body}")
        self.assertFalse(result["is_observation_only"])
        self.assertEqual(len(result["self_references"]), 1)
        self.assertEqual(len(result["genuine_hits"]), 0)

    def test_ellipsis_failsafe_self_ref(self) -> None:
        body = "- [ ] the observation-only ... fail-safe is named here."
        result = coo.classify(body)
        self.assertFalse(result["is_observation_only"])

    def test_leading_mechanism_token_self_ref(self) -> None:
        body = "- [ ] The fail-safe's observation-only check is the subject."
        result = coo.classify(body)
        self.assertFalse(result["is_observation_only"])

    def test_sentence_boundary_breaks_self_reference(self) -> None:
        """A period between the sentinel and the mechanism token means the
        two are in different sentences — the sentinel is genuine."""
        body = (
            "- [ ] Confirm stability by observation-only monitoring. The "
            "fail-safe is unrelated context two sentences later."
        )
        result = coo.classify(body)
        self.assertTrue(result["is_observation_only"])

    def test_observation_only_bullet_meta_is_self_ref(self) -> None:
        """A sentinel labelling the matcher's own input unit ('bullet')
        is meta-discussion, not real observation work."""
        body = "- [ ] A genuine observation-only acceptance bullet still fires."
        result = coo.classify(body)
        self.assertFalse(result["is_observation_only"])

    def test_full_fixing_item_acceptance_classifies_buildable(self) -> None:
        """The fail-safe must NOT flag its own defining item. Every
        sentinel occurrence in this item's four acceptance bullets is a
        mechanism-name or matcher-input ('bullet') self-reference, so the
        item is buildable (exit 0)."""
        acceptance = "\n".join(
            [
                THIS_ITEM_BULLET_1,
                "- [ ] The fix is consistent with the Step 2.5 close-mode "
                "hook's existing \"genuinely code-buildable -> leave it "
                "alone\" carve-out, so the backstop and the primary "
                "mechanism agree.",
                "- [ ] `spec/autonomous/PROCESS.md` (durable spec) records "
                "the false-positive class and the disambiguation rule "
                "wherever the pre-pick fail-safe is described.",
                "- [ ] If a repo-side helper is introduced to make the "
                "matcher testable, it ships with unit tests covering: "
                "(a) a genuine observation-only acceptance bullet still "
                "fires; (b) a bullet that only names the fail-safe does NOT "
                "fire; (c) the phase-v13-dangling bullet-4 text specifically "
                "does NOT fire. Full `tools/autonomous` suite stays green.",
            ]
        )
        path = _write(_item(acceptance))
        try:
            out, _, rc = run(path)
            self.assertEqual(rc, 0, out)
            self.assertIn('"is_observation_only": false', out)
        finally:
            path.unlink(missing_ok=True)


class MixedAndCleanTests(unittest.TestCase):
    def test_clean_acceptance_no_sentinels(self) -> None:
        body = (
            "- [ ] Helper ships with unit tests.\n"
            "- [ ] Full suite stays green."
        )
        path = _write(_item(body))
        try:
            out, _, rc = run(path)
            self.assertEqual(rc, 0, out)
            self.assertIn('"genuine_hits": []', out)
        finally:
            path.unlink(missing_ok=True)

    def test_mixed_one_genuine_one_selfref_fires(self) -> None:
        """A bullet with a genuine sentinel AND a separate self-reference
        bullet still classifies the item observation-only."""
        body = (
            "- [ ] Subject to the observation-only pre-pick fail-safe.\n"
            "- [ ] Also requires observation-over-time across 3 releases."
        )
        result = coo.classify(body)
        self.assertTrue(result["is_observation_only"])
        self.assertEqual(len(result["genuine_hits"]), 1)
        self.assertEqual(len(result["self_references"]), 1)

    def test_no_acceptance_section_is_clean(self) -> None:
        text = (
            "---\nid: x\nstatus: open\n---\n\n# X\n\n## Scope\n\nNo acceptance.\n"
        )
        path = _write(text)
        try:
            out, _, rc = run(path)
            self.assertEqual(rc, 0)
            self.assertIn('"has_acceptance_section": false', out)
        finally:
            path.unlink(missing_ok=True)

    def test_n_below_3_does_not_fire(self) -> None:
        """`N consecutive` requires N >= 3 per the canonical phrase."""
        result = coo.classify("- [ ] 2 consecutive runs is fine, ship it.")
        self.assertFalse(result["is_observation_only"])

    def test_missing_file_exit_2(self) -> None:
        _, stderr, rc = run(Path("/tmp/does-not-exist-coo-xyz.md"))
        self.assertEqual(rc, 2)
        self.assertIn("check_observation_only", stderr)


if __name__ == "__main__":
    unittest.main()
