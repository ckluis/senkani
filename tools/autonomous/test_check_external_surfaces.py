#!/usr/bin/env python3
"""
Tests for `check_external_surfaces.py` — the helper that scope-groom
mode (phase 5→6) and build mode (Step 2 pre-audit) invoke to catch
two failure classes:

  (a) Vocabulary-without-declaration: `## Acceptance` uses framing
      vocabulary but no `## Pre-audit external surfaces` block.
  (b) CLI protocol mismatch: declared `kind: cli` surface's
      `expected_capabilities[]` do not appear in `<target> --help`.

Originating item:
`process-gap-pre-audit-cli-protocol-match-check-2026-05-22`. Parent
finding: `phase-t3a-2-subprocess-runtime-wrapper` 2026-05-22 build
abort — `wasmtime run` is one-shot, not streaming-stdin.

Test plan covers the Acceptance bullet 1 cases (≥6):
  1. no declaration AND no vocabulary  → clean.
  2. cli with matching capabilities    → matched, no fire.
  3. cli mismatch (the wasmtime case)  → fire with
                                          cli_protocol_mismatch.
  4. lsp surface                       → requires_runtime_probe.
  5. http surface                      → requires_runtime_probe.
  6. db surface                        → requires_runtime_probe.
  7. vocabulary-only no surface        → fire with
                                          vocabulary_without_surface.
  8. cli not on PATH                   → fire with
                                          cli_invocation_error.
  9. JSON shape contract               → suggested_questions[] +
                                          singular alias.

Stdlib-only (`unittest`). Uses small Python-shim CLIs written to a
tempdir for the matching/mismatch cases — no dependency on
wasmtime / pyright / curl being installed on the test machine.

Usage:
    python3 tools/autonomous/test_check_external_surfaces.py
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))
import check_external_surfaces as ces  # type: ignore  # noqa: E402

HELPER = THIS_DIR / "check_external_surfaces.py"


def _write_item(tmpdir: Path, *, body: str,
                name: str = "test-item.md") -> Path:
    path = tmpdir / name
    path.write_text(
        "---\n"
        "id: test-item\n"
        "title: 'Test item'\n"
        "status: in_progress\n"
        "size: standard\n"
        "---\n\n"
        + body,
        encoding="utf-8",
    )
    return path


def _write_shim(dirpath: Path, name: str, help_body: str,
                exit_code: int = 0) -> Path:
    """Write a tiny `name` shim script that prints `help_body` on
    `--help` and returns `exit_code`. Made executable, returned as
    absolute path."""
    shim = dirpath / name
    body = help_body.replace("'", "'\\''")
    shim.write_text(
        "#!/usr/bin/env bash\n"
        f"if [ \"$1\" = \"--help\" ]; then\n"
        f"  cat <<'END_OF_HELP'\n{help_body}\nEND_OF_HELP\n"
        f"  exit {exit_code}\n"
        f"fi\n"
        f"exit 99\n"
    )
    shim.chmod(shim.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP
               | stat.S_IXOTH)
    return shim


def _run(item: Path, *, path_prepend: Path | None = None) -> tuple[int, dict]:
    env = os.environ.copy()
    if path_prepend is not None:
        env["PATH"] = f"{path_prepend}{os.pathsep}{env.get('PATH', '')}"
    proc = subprocess.run(
        [sys.executable, str(HELPER), str(item)],
        capture_output=True, text=True, env=env,
    )
    if proc.returncode == 2:
        raise RuntimeError(f"helper error: {proc.stderr}")
    return proc.returncode, json.loads(proc.stdout)


class TestExternalSurfacesHelper(unittest.TestCase):

    def test_clean_no_vocabulary_no_declaration(self) -> None:
        """Case 1: an item with neither framing vocabulary nor a
        declared surfaces block is clean — exit 0, should_fire
        false, empty reasons."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            item = _write_item(tmp, body=(
                "## Scope\n"
                "Refactor the foo helper into bar.\n\n"
                "## Acceptance\n"
                "- [ ] foo() is renamed to bar() across Sources/\n"
                "- [ ] tests still green\n"
            ))
            rc, out = _run(item)
            self.assertEqual(rc, 0)
            self.assertFalse(out["should_fire"])
            self.assertEqual(out["reasons"], [])
            self.assertEqual(out["vocabulary_hits"], [])
            self.assertEqual(out["surfaces"], [])
            self.assertEqual(out["suggested_questions"], [])
            self.assertIsNone(out["suggested_question"])

    def test_cli_match_with_declared_capabilities(self) -> None:
        """Case 2: declared `kind: cli` whose `--help` output
        contains all `expected_capabilities[]` keywords — matched,
        no fire."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            shim_dir = tmp / "bin"
            shim_dir.mkdir()
            _write_shim(shim_dir, "fakebinary", (
                "fakebinary - a useful CLI\n"
                "USAGE: fakebinary [OPTIONS]\n"
                "OPTIONS:\n"
                "  --stdin             read input from stdin\n"
                "  --frame             enable length-prefix framing\n"
                "  --length-prefix     emit length-prefixed records\n"
            ))
            item = _write_item(tmp, body=(
                "## Scope\nSpawn the fakebinary subprocess.\n\n"
                "## Acceptance\n"
                "- [ ] Spawn `fakebinary` with stdin framing\n\n"
                "## Pre-audit external surfaces\n\n"
                "```yaml\n"
                "surfaces:\n"
                "  - kind: cli\n"
                "    target: fakebinary\n"
                "    expected_capabilities: [stdin, frame, length-prefix]\n"
                "```\n"
            ))
            rc, out = _run(item, path_prepend=shim_dir)
            self.assertEqual(rc, 0,
                             f"expected clean, got reasons={out['reasons']}")
            self.assertFalse(out["should_fire"])
            self.assertEqual(len(out["surfaces"]), 1)
            sr = out["surfaces"][0]
            self.assertEqual(sr["kind"], "cli")
            self.assertEqual(sr["target"], "fakebinary")
            self.assertEqual(sr["probe_result"]["status"], "matched")

    def test_cli_mismatch_wasmtime_case(self) -> None:
        """Case 3: the originating t3a-2 wasmtime trajectory.
        Declared `kind: cli` whose `--help` lacks every declared
        capability — fire with cli_protocol_mismatch."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            shim_dir = tmp / "bin"
            shim_dir.mkdir()
            # Stand-in `wasmtime --help` body — deliberately
            # contains NONE of {stdin, frame, length-prefix}.
            _write_shim(shim_dir, "wasmtime", (
                "wasmtime - Wasm runtime\n"
                "USAGE: wasmtime [SUBCOMMAND] [OPTIONS]\n"
                "SUBCOMMANDS:\n"
                "  run   Run a WebAssembly module\n"
                "  compile  Compile a module\n"
                "OPTIONS:\n"
                "  --invoke <NAME>   Invoke an exported function\n"
                "  --dir <PATH>      Preopen directory\n"
            ))
            item = _write_item(tmp, body=(
                "## Scope\nSpawn long-running wasmtime subprocess.\n\n"
                "## Acceptance\n"
                "- [ ] Spawn `wasmtime` with length-prefix stdin framing\n\n"
                "## Pre-audit external surfaces\n\n"
                "```yaml\n"
                "surfaces:\n"
                "  - kind: cli\n"
                "    target: wasmtime\n"
                "    expected_capabilities: [stdin, frame, length-prefix]\n"
                "```\n"
            ))
            rc, out = _run(item, path_prepend=shim_dir)
            self.assertEqual(rc, 1)
            self.assertTrue(out["should_fire"])
            kinds = {r["kind"] for r in out["reasons"]}
            self.assertIn("cli_protocol_mismatch", kinds)
            sr = out["surfaces"][0]
            self.assertEqual(sr["probe_result"]["status"], "mismatch")
            self.assertEqual(
                sorted(sr["probe_result"]["missing_capabilities"]),
                ["frame", "length-prefix", "stdin"],
            )
            # Mismatch question appears in suggested_questions.
            self.assertGreaterEqual(len(out["suggested_questions"]), 1)
            headers = [q["header"] for q in out["suggested_questions"]]
            self.assertIn(ces.QUESTION_HEADER_MISMATCH, headers)

    def test_lsp_surface_requires_runtime_probe(self) -> None:
        """Case 4: `kind: lsp` emits requires_runtime_probe; the
        helper does NOT fire on lsp/http/db surfaces alone — only
        cli kinds gate the round."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            item = _write_item(tmp, body=(
                "## Scope\nWrap pyright LSP for code intel.\n\n"
                "## Acceptance\n"
                "- [ ] Send initialize JSON-RPC and assert response\n\n"
                "## Pre-audit external surfaces\n\n"
                "```yaml\n"
                "surfaces:\n"
                "  - kind: lsp\n"
                "    target: pyright\n"
                "    expected_capabilities: [hover, references]\n"
                "    probe: spin up pyright in stdio mode and "
                "send initialize\n"
                "```\n"
            ))
            rc, out = _run(item)
            # vocabulary 'json-rpc' present BUT a surface IS declared,
            # so vocabulary-without-surface does NOT fire. LSP is
            # not auto-probed → no fire.
            self.assertEqual(rc, 0,
                             f"lsp alone should not fire; reasons="
                             f"{out['reasons']}")
            sr = out["surfaces"][0]
            self.assertEqual(sr["kind"], "lsp")
            self.assertEqual(sr["probe_result"]["status"],
                             "requires_runtime_probe")
            self.assertIn("pyright", sr["probe_result"]["probe"])

    def test_http_surface_requires_runtime_probe(self) -> None:
        """Case 5: `kind: http` mirrors lsp — runtime probe echo,
        no fire on the surface alone."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            item = _write_item(tmp, body=(
                "## Scope\nCall the foo API.\n\n"
                "## Acceptance\n"
                "- [ ] POST /v1/items returns 200\n\n"
                "## Pre-audit external surfaces\n\n"
                "```yaml\n"
                "surfaces:\n"
                "  - kind: http\n"
                "    target: https://api.example.com\n"
                "    expected_capabilities: [POST, streaming]\n"
                "    probe: curl --include the health endpoint\n"
                "```\n"
            ))
            rc, out = _run(item)
            self.assertEqual(rc, 0)
            sr = out["surfaces"][0]
            self.assertEqual(sr["kind"], "http")
            self.assertEqual(sr["probe_result"]["status"],
                             "requires_runtime_probe")

    def test_db_surface_requires_runtime_probe(self) -> None:
        """Case 6: `kind: db` mirrors lsp/http — runtime probe echo."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            item = _write_item(tmp, body=(
                "## Scope\nQuery the events table.\n\n"
                "## Acceptance\n"
                "- [ ] Select count(*) returns N\n\n"
                "## Pre-audit external surfaces\n\n"
                "```yaml\n"
                "surfaces:\n"
                "  - kind: db\n"
                "    target: postgres://localhost/foo\n"
                "    expected_capabilities: [select, transactional]\n"
                "    probe: psql -c 'select 1'\n"
                "```\n"
            ))
            rc, out = _run(item)
            self.assertEqual(rc, 0)
            sr = out["surfaces"][0]
            self.assertEqual(sr["kind"], "db")
            self.assertEqual(sr["probe_result"]["status"],
                             "requires_runtime_probe")

    def test_vocabulary_only_without_surface_fires(self) -> None:
        """Case 7: framing vocabulary in `## Acceptance` but NO
        surfaces block — fire with vocabulary_without_surface."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            item = _write_item(tmp, body=(
                "## Scope\nSpawn a long-running subprocess.\n\n"
                "## Acceptance\n"
                "- [ ] Subprocess reads length-prefix framed input "
                "on stdin and emits framed long-running output\n"
            ))
            rc, out = _run(item)
            self.assertEqual(rc, 1)
            self.assertTrue(out["should_fire"])
            kinds = {r["kind"] for r in out["reasons"]}
            self.assertIn("vocabulary_without_surface", kinds)
            for tok in ("stdin", "length-prefix", "framed",
                        "long-running"):
                self.assertIn(tok, out["vocabulary_hits"])
            headers = [q["header"] for q in out["suggested_questions"]]
            self.assertIn(ces.QUESTION_HEADER_VOCAB, headers)

    def test_cli_invocation_error_when_binary_missing(self) -> None:
        """Case 8: declared `kind: cli` target not on PATH — fire
        with cli_invocation_error."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            # Empty PATH-prepend dir → the made-up name is missing.
            shim_dir = tmp / "bin"
            shim_dir.mkdir()
            item = _write_item(tmp, body=(
                "## Scope\nUse a non-existent CLI.\n\n"
                "## Acceptance\n"
                "- [ ] Spawn `definitely-not-a-real-binary-9k2`\n\n"
                "## Pre-audit external surfaces\n\n"
                "```yaml\n"
                "surfaces:\n"
                "  - kind: cli\n"
                "    target: definitely-not-a-real-binary-9k2\n"
                "    expected_capabilities: [anything]\n"
                "```\n"
            ))
            rc, out = _run(item, path_prepend=shim_dir)
            self.assertEqual(rc, 1)
            kinds = {r["kind"] for r in out["reasons"]}
            self.assertIn("cli_invocation_error", kinds)
            sr = out["surfaces"][0]
            self.assertEqual(sr["probe_result"]["status"],
                             "invocation_error")
            self.assertIn("not found", sr["probe_result"]["detail"])

    def test_json_shape_contract(self) -> None:
        """Kleppmann audit-shape: pin the JSON shape contract.
        SKILL.md (scope-groom + build-mode) consumes:
          - `should_fire: bool`
          - `reasons: [{kind, ...}]`
          - `surfaces: [{kind, target, expected_capabilities,
                         probe_result, ...}]`
          - `vocabulary_hits: [<token>]`
          - `vocabulary_set: [<all 11 tokens>]`
          - `kinds: [<4 supported kinds>]`
          - `suggested_questions: [{header, text, options}]`
          - `suggested_question: <first or null>` (sibling alias)
        """
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            shim_dir = tmp / "bin"
            shim_dir.mkdir()
            _write_shim(shim_dir, "wasmtime", "wasmtime - run wasm")
            item = _write_item(tmp, body=(
                "## Acceptance\n"
                "- [ ] Spawn wasmtime with stdin framing\n\n"
                "## Pre-audit external surfaces\n\n"
                "```yaml\n"
                "surfaces:\n"
                "  - kind: cli\n"
                "    target: wasmtime\n"
                "    expected_capabilities: [stdin, frame]\n"
                "```\n"
            ))
            rc, out = _run(item, path_prepend=shim_dir)
            self.assertEqual(rc, 1)

            for key in ("item", "should_fire", "reasons", "surfaces",
                        "vocabulary_hits", "vocabulary_set", "kinds",
                        "suggested_questions", "suggested_question"):
                self.assertIn(key, out, f"missing top-level key {key!r}")

            self.assertEqual(out["vocabulary_set"], list(ces.VOCABULARY_SET))
            self.assertEqual(out["kinds"], list(ces.KINDS))
            self.assertEqual(len(out["suggested_questions"]), 1)
            q = out["suggested_questions"][0]
            self.assertEqual(q["header"], ces.QUESTION_HEADER_MISMATCH)
            self.assertLessEqual(len(q["header"]), 12,
                                 "AskUserQuestion header max 12 chars")
            self.assertIn("options", q)
            self.assertEqual(len(q["options"]), 3)
            for opt in q["options"]:
                self.assertIn("label", opt)
                self.assertIn("description", opt)
            # singular alias points at the first question
            self.assertEqual(out["suggested_question"]["header"],
                             ces.QUESTION_HEADER_MISMATCH)

    def test_vocab_question_header_short(self) -> None:
        """AskUserQuestion `header` field max 12 chars — pin both
        canonical headers (`Surfaces?` + `Protocol?`)."""
        self.assertLessEqual(len(ces.QUESTION_HEADER_VOCAB), 12)
        self.assertLessEqual(len(ces.QUESTION_HEADER_MISMATCH), 12)


if __name__ == "__main__":
    unittest.main(verbosity=2)
