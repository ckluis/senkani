#!/usr/bin/env python3
"""
Tests for `scope_groom_rule_manager.py` — the helper that scope-groom
mode invokes (between phase "Synthesis from answers" and "Re-audit") to
write a narrow, single-use Bash permission rule into
`.claude/settings.local.json` when an operator authorizes the
autonomous build round to run an external-write action, and that
close-mode invokes to auto-revoke that rule.

Originating item:
`process-gap-harness-vs-item-authorization-mismatch`.

Tests 1-6 cover EXACTLY the acceptance-bullet-6 list:
  1. rule-writing happy path,
  2. idempotency,
  3. no-op when not autonomous-authorized,
  4. auto-revoke on close,
  5. comment-marker detection across MULTIPLE managed rules,
  6. graceful behavior when `.claude/settings.local.json` is missing
     OR malformed.
Test 7 is a hardening regression flagged by the 2026-06-13 re-audit
panel: revoke must not corrupt a surviving entry whose string value
literally contains `,]`/`,}` (JSON-string-aware trailing-comma fix).

Kleppmann lens: idempotent + deterministic (re-run = byte-identical
file). Schneier lens: auto-revoke is the security-critical control — a
stale allowlist rule is a regression, so revoke must be reliable.

Stdlib-only (`unittest`, `tempfile`, `json`); no operator setup needed.

Usage:
    python3 tools/autonomous/test_scope_groom_rule_manager.py
"""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import sys

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))
import scope_groom_rule_manager as sgrm  # type: ignore  # noqa: E402
from check_categorical_block import SCOPE_GROOM_MARKER  # noqa: E402


_BASE_SETTINGS = {
    "permissions": {
        "allow": [
            "Bash(swift test:*)",
            "Bash(ls -la:*)",
        ]
    },
    "enabledMcpjsonServers": ["senkani"],
}


def _write_settings(tmp: Path, data: dict | str,
                    name: str = "settings.local.json") -> Path:
    path = tmp / name
    if isinstance(data, str):
        path.write_text(data, encoding="utf-8")
    else:
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return path


def _managed_marker_count(text: str, item_id: str) -> int:
    needle = f"{SCOPE_GROOM_MARKER} {item_id}"
    return sum(1 for ln in text.splitlines() if ln.strip() == needle)


class TestScopeGroomRuleManager(unittest.TestCase):

    def test_1_rule_writing_happy_path(self) -> None:
        """Acceptance: a narrow managed Bash rule is written into the
        allowlist, tagged with `SCOPE_GROOM_MARKER <item-id>` on the
        line adjacent to the `"Bash(...)"` entry, and the file still
        parses (comment-tolerant) as JSON with the new allow entry."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            settings = _write_settings(tmp, _BASE_SETTINGS)
            cmd = "gh issue create --repo swiftlang/swift-testing *"
            changed = sgrm.write_rule(settings, "item-alpha", cmd)
            self.assertTrue(changed, "first write reports a change")

            raw = settings.read_text(encoding="utf-8")
            self.assertEqual(_managed_marker_count(raw, "item-alpha"), 1)
            self.assertIn(f"Bash({cmd})", raw)

            # Marker line sits immediately above the Bash entry.
            lines = raw.splitlines()
            marker_idx = next(
                i for i, ln in enumerate(lines)
                if ln.strip() == f"{SCOPE_GROOM_MARKER} item-alpha")
            self.assertRegex(lines[marker_idx + 1].strip(),
                             r'^"Bash\(gh issue create')

            # Comment-tolerant load round-trips and the entry is present.
            data = sgrm.load_settings(settings)
            self.assertIn(f"Bash({cmd})", data["permissions"]["allow"])
            # Pre-existing entries preserved.
            self.assertIn("Bash(swift test:*)", data["permissions"]["allow"])

    def test_2_idempotency_no_duplicate_entry(self) -> None:
        """Acceptance: rerunning the write on the same item produces the
        identical file, never a duplicate entry (Kleppmann: byte-stable
        re-run)."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            settings = _write_settings(tmp, _BASE_SETTINGS)
            cmd = "gh issue create --repo swiftlang/swift-testing *"

            self.assertTrue(sgrm.write_rule(settings, "item-alpha", cmd))
            after_first = settings.read_text(encoding="utf-8")

            changed_again = sgrm.write_rule(settings, "item-alpha", cmd)
            after_second = settings.read_text(encoding="utf-8")

            self.assertFalse(changed_again, "second write is a no-op")
            self.assertEqual(after_first, after_second,
                             "re-run is byte-identical")
            self.assertEqual(_managed_marker_count(after_second, "item-alpha"),
                             1, "exactly one marker, no duplicate")
            self.assertEqual(after_second.count(f"Bash({cmd})"), 1,
                             "exactly one Bash entry, no duplicate")

    def test_3_noop_when_not_autonomous_authorized(self) -> None:
        """Acceptance: the no-op decision helper distinguishes "operator
        authorized the loop" from "operator will run it themselves." A
        Manual/Cowork answer → no rule written; an explicit-auth answer
        → authorized."""
        # Decision helper: manual/cowork/blank → not authorized.
        self.assertFalse(sgrm.is_autonomous_authorization(
            "Manual — I'll run it myself"))
        self.assertFalse(sgrm.is_autonomous_authorization(
            "Cowork in Claude Desktop"))
        self.assertFalse(sgrm.is_autonomous_authorization(""))
        self.assertFalse(sgrm.is_autonomous_authorization(None))  # type: ignore
        # Affirmative autonomous authorization → True.
        self.assertTrue(sgrm.is_autonomous_authorization(
            "Autonomous build round (with explicit auth)"))

        # End-to-end via CLI semantics: a non-autonomous answer must not
        # mutate the file.
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            settings = _write_settings(tmp, _BASE_SETTINGS)
            before = settings.read_text(encoding="utf-8")
            rc = sgrm.main([
                "write", "--settings", str(settings),
                "--item-id", "item-beta",
                "--command", "gh issue create --repo x/y *",
                "--answer", "Manual — operator runs it",
            ])
            self.assertEqual(rc, 0)
            self.assertEqual(settings.read_text(encoding="utf-8"), before,
                             "non-autonomous answer leaves file untouched")
            self.assertEqual(_managed_marker_count(
                settings.read_text(encoding="utf-8"), "item-beta"), 0)

    def test_4_auto_revoke_on_close(self) -> None:
        """Acceptance: close-mode revoke removes the managed rule (marker
        + adjacent Bash entry) for an item-id, leaving the rest of the
        allowlist intact and the file valid JSON. The security-critical
        control: a stale rule is a regression, so revoke must be
        reliable."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            settings = _write_settings(tmp, _BASE_SETTINGS)
            cmd = "gh issue create --repo swiftlang/swift-testing *"
            sgrm.write_rule(settings, "item-alpha", cmd)
            self.assertEqual(_managed_marker_count(
                settings.read_text(encoding="utf-8"), "item-alpha"), 1)

            removed = sgrm.revoke_rules(settings, "item-alpha")
            self.assertEqual(removed, 1, "one managed rule removed")

            raw = settings.read_text(encoding="utf-8")
            self.assertEqual(_managed_marker_count(raw, "item-alpha"), 0,
                             "marker gone")
            self.assertNotIn(f"Bash({cmd})", raw, "managed entry gone")

            # Surviving allowlist is intact + valid.
            data = sgrm.load_settings(settings)
            self.assertIn("Bash(swift test:*)", data["permissions"]["allow"])
            self.assertIn("Bash(ls -la:*)", data["permissions"]["allow"])
            self.assertEqual(data["enabledMcpjsonServers"], ["senkani"])

            # Revoking again is a clean no-op (0 removed).
            self.assertEqual(sgrm.revoke_rules(settings, "item-alpha"), 0)

    def test_5_marker_detection_across_multiple_managed_rules(self) -> None:
        """Acceptance: comment-marker detection across MULTIPLE managed
        rules. Two items each write a rule; revoking one removes ONLY
        its marker+entry and leaves the other's intact. Writing a second
        rule for the same item adds a distinct managed entry, both
        revoked together."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            settings = _write_settings(tmp, _BASE_SETTINGS)
            cmd_a = "gh issue create --repo swiftlang/swift-testing *"
            cmd_b = "slack-post --channel releases *"
            cmd_a2 = "gh issue comment --repo swiftlang/swift-testing *"

            sgrm.write_rule(settings, "item-alpha", cmd_a)
            sgrm.write_rule(settings, "item-beta", cmd_b)
            sgrm.write_rule(settings, "item-alpha", cmd_a2)  # 2nd for alpha

            raw = settings.read_text(encoding="utf-8")
            self.assertEqual(_managed_marker_count(raw, "item-alpha"), 2)
            self.assertEqual(_managed_marker_count(raw, "item-beta"), 1)
            # File still loads (multiple managed `//` comment lines).
            data = sgrm.load_settings(settings)
            allow = data["permissions"]["allow"]
            self.assertIn(f"Bash({cmd_a})", allow)
            self.assertIn(f"Bash({cmd_b})", allow)
            self.assertIn(f"Bash({cmd_a2})", allow)

            # Revoke alpha → both alpha rules gone, beta untouched.
            removed = sgrm.revoke_rules(settings, "item-alpha")
            self.assertEqual(removed, 2, "both alpha managed rules removed")
            raw2 = settings.read_text(encoding="utf-8")
            self.assertEqual(_managed_marker_count(raw2, "item-alpha"), 0)
            self.assertEqual(_managed_marker_count(raw2, "item-beta"), 1)
            data2 = sgrm.load_settings(settings)
            allow2 = data2["permissions"]["allow"]
            self.assertNotIn(f"Bash({cmd_a})", allow2)
            self.assertNotIn(f"Bash({cmd_a2})", allow2)
            self.assertIn(f"Bash({cmd_b})", allow2,
                          "beta's managed rule survives alpha's revoke")

    def test_6_graceful_on_missing_or_malformed_settings(self) -> None:
        """Acceptance: graceful behavior when settings.local.json is
        missing OR malformed.

        Missing: write seeds a fresh file (no crash). Malformed
        (genuinely-corrupt JSON, NOT merely managed markers): write and
        revoke fail-safe — raise SettingsError, never crash, never write
        a duplicate, never silently corrupt. The managed-marker-tolerant
        file (valid JSON once markers stripped) is NOT treated as
        malformed."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)

            # (a) Missing file → write seeds it, no crash.
            missing = tmp / "settings.local.json"
            self.assertFalse(missing.exists())
            changed = sgrm.write_rule(
                missing, "item-gamma", "gh issue create --repo x/y *")
            self.assertTrue(changed)
            self.assertTrue(missing.exists())
            data = sgrm.load_settings(missing)
            self.assertIn("Bash(gh issue create --repo x/y *)",
                          data["permissions"]["allow"])
            # Revoke on a never-written item-id → clean 0.
            self.assertEqual(sgrm.revoke_rules(missing, "no-such-item"), 0)

            # (b) Genuinely-malformed JSON → fail-safe, no mutation.
            corrupt = _write_settings(
                tmp, '{ "permissions": { "allow": [ "Bash(x)"  ',  # unbalanced
                name="corrupt.json")
            before = corrupt.read_text(encoding="utf-8")
            with self.assertRaises(sgrm.SettingsError):
                sgrm.write_rule(corrupt, "item-delta", "gh issue create *")
            self.assertEqual(corrupt.read_text(encoding="utf-8"), before,
                             "corrupt file left untouched on write")
            with self.assertRaises(sgrm.SettingsError):
                sgrm.revoke_rules(corrupt, "item-delta")
            self.assertEqual(corrupt.read_text(encoding="utf-8"), before,
                             "corrupt file left untouched on revoke")

            # (c) Managed-marker file is NOT malformed (comment-tolerant).
            settings = _write_settings(tmp, _BASE_SETTINGS, name="ok.json")
            sgrm.write_rule(settings, "item-eps", "gh issue create *")
            raw = settings.read_text(encoding="utf-8")
            self.assertIn(SCOPE_GROOM_MARKER, raw)
            # load_settings tolerates the `//` marker line.
            self.assertIsInstance(sgrm.load_settings(settings), dict)
            # CLI malformed path returns exit 2 (fail-safe), not a crash.
            rc = sgrm.main(["write", "--settings", str(corrupt),
                            "--item-id", "z", "--command", "gh x *"])
            self.assertEqual(rc, 2)

    def test_7_revoke_preserves_comma_bracket_in_surviving_string(self) -> None:
        """Hardening regression (beyond the 6 acceptance scenarios) flagged
        by the re-audit panel 2026-06-13 (Kleppmann/Carmack): revoking a
        managed rule must NOT corrupt a SURVIVING allow entry whose string
        value literally contains `,]` or `,}`. The earlier
        `re.sub(r",(\\s*[\\]}])", ...)` trailing-comma fixer was not
        JSON-string-aware and would have rewritten `Bash(echo "[a,]")` to
        `Bash(echo "[a]")` during any revoke. The dangling structural comma
        (left when the removed managed entry was last) must still be
        collapsed so the file re-parses."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            # A surviving, UNMANAGED entry whose command literally ends in
            # ",]" inside the string value — the corruption trap.
            tricky = 'Bash(echo "[a,]")'
            base = {
                "permissions": {"allow": [tricky, "Bash(ls -la:*)"]},
                "enabledMcpjsonServers": ["senkani"],
            }
            settings = _write_settings(tmp, base)

            # Write a managed rule for item-alpha (appended last), then
            # revoke it — leaving a dangling comma on the now-last entry.
            cmd = "gh issue create --repo swiftlang/swift-testing *"
            sgrm.write_rule(settings, "item-alpha", cmd)
            removed = sgrm.revoke_rules(settings, "item-alpha")
            self.assertEqual(removed, 1)

            # The tricky surviving entry keeps its ",]" verbatim, and the
            # file re-parses as valid JSON.
            data = sgrm.load_settings(settings)
            allow = data["permissions"]["allow"]
            self.assertIn(tricky, allow,
                          'surviving "[a,]" entry preserved byte-for-byte')
            self.assertIn("Bash(ls -la:*)", allow)
            self.assertNotIn(f"Bash({cmd})", allow, "managed entry gone")
            self.assertEqual(data["enabledMcpjsonServers"], ["senkani"])

            # A genuinely-malformed file is still rejected by the same
            # path (the JSON-aware fixer cannot mask unbalanced braces).
            corrupt = _write_settings(
                tmp, '{ "permissions": { "allow": [ "Bash(a)", , ] }',
                name="bad.json")
            with self.assertRaises(sgrm.SettingsError):
                sgrm.revoke_rules(corrupt, "item-alpha")


if __name__ == "__main__":
    unittest.main(verbosity=2)
