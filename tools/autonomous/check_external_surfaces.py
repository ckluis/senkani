#!/usr/bin/env python3
"""
check_external_surfaces — scan a scope-groom item (or, at build-mode
Step 2, an `open` item the round is about to claim) for two failure
classes that pre-audit's "is this already shipped" grep cannot
catch:

  (a) **Vocabulary-without-declaration** — the `## Acceptance`
      section uses framing/protocol vocabulary (`stdin`, `frame`,
      `length-prefix`, `JSON-RPC`, `streaming`, `long-running`,
      `persistent`, `multiplexed`, `framed`) BUT the item does not
      declare a `## Pre-audit external surfaces` block. The item
      may be implicitly assuming an external CLI / service has
      shape capabilities the round never verifies — a warning, not
      a hard block.

  (b) **CLI protocol mismatch** — the item declares a `kind: cli`
      surface with `expected_capabilities: [...]` but
      `<target> --help` runs successfully without any
      `expected_capabilities[]` keyword appearing in the help
      output. The 2026-05-22 t3a-2 wasmtime build round is the
      originating example: acceptance specified a
      `[u32 module_len][module_bytes]...` streaming-stdin protocol
      on `wasmtime`, but `wasmtime run` is one-shot (takes a
      module path arg, executes once, exits) — `wasmtime --help`
      contains no streaming/stdin framing vocabulary.

  (c) **CLI invocation error** — declared `kind: cli` target is
      missing on PATH, OR `<target> --help` exits non-zero, OR the
      invocation hits the helper's 5-second timeout.

Non-cli surfaces (`kind: lsp|http|db`) cannot be auto-probed by a
fresh-context autonomous round (live services demand trust the
round shouldn't grant by default). For those kinds the helper
emits `requires_runtime_probe: true` per surface alongside the
declared `probe:` text, and the operator validates manually at
scope-groom-interview time.

Scope-groom mode (in `~/.claude/skills/senkani-autonomous/SKILL.md`)
calls this helper between phase 5 ("Audit the questions") and
phase 6 ("Run the interview"); when the JSON record's
`suggested_questions: [...]` list is non-empty, SKILL.md appends
each question to the AskUserQuestion battery.

Build mode Step 2 ("Pre-audit inventory") calls the helper too;
when `should_fire: true` AND any reason has
`kind: "cli_protocol_mismatch"` OR `kind: "cli_invocation_error"`,
build mode reclassifies the item per Step 3 pre-pick fail-safe
semantics (status → manual + scope_groomable: true, with a
`## Reclassified by Step 2 pre-audit fail-safe <date>` body
section + prepended `blocked_reason:`). Vocabulary-without-
declaration (`kind: "vocabulary_without_surface"`) alone is a
warning — it does NOT reclassify, because the item may legitimately
not depend on the named CLI.

Sibling helpers: `check_envelope_size.py`,
`check_categorical_block.py`, `check_same_day_abort.py`. Same JSON
shape conventions, same stdlib-only constraint, same
SKILL.md-invocation contract.

Stdlib-only. The `## Pre-audit external surfaces` block parser is
hand-rolled (no PyYAML) and accepts a narrow shape — see
`_parse_surfaces_block` for the schema.

Usage:
    python3 tools/autonomous/check_external_surfaces.py <item.md>

Output (stdout): see the module docstring above + the test file
`test_check_external_surfaces.py` for the pinned shape.

Exit codes:
    0 — no fire (clean: no vocabulary hits without declaration, all
        declared cli surfaces match, all non-cli surfaces echoed
        back as `requires_runtime_probe`)
    1 — fire (SKILL.md appends `suggested_questions[]` to the
        battery, OR build-mode reclassifies on cli mismatch / error)
    2 — usage / IO error
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

VOCABULARY_SET: tuple[str, ...] = (
    "stdin",
    "frame",
    "length-prefix",
    "length-prefixed",
    "json-rpc",
    "jsonrpc",
    "streaming",
    "long-running",
    "persistent",
    "multiplexed",
    "framed",
)
"""Frozen vocabulary that signals an item's acceptance is assuming
a framing/protocol shape on an external surface. Case-insensitive
substring match against `## Acceptance` top-level bullets. The
set is intentionally narrow — adding tokens widens the false-fire
surface; tighten by raising the bar on operator intent (e.g.
`framed` should match `framed protocol` but never `framed
question`)."""

KINDS = ("cli", "lsp", "http", "db")
"""Surface kinds the schema accepts. Only `cli` is auto-probable
by the helper; the rest emit `requires_runtime_probe: true`."""

HELP_TIMEOUT_SECONDS = 5
"""Wall-clock timeout for `<target> --help` invocations. Long
enough for slow shells, short enough that a hung binary doesn't
stall the autonomous round."""

QUESTION_HEADER_VOCAB = "Surfaces?"
"""AskUserQuestion `header` for the vocabulary-without-declaration
case. Max 12 chars."""

QUESTION_HEADER_MISMATCH = "Protocol?"
"""AskUserQuestion `header` for the cli-protocol-mismatch case.
Max 12 chars."""


def _frontmatter(text: str) -> dict[str, str]:
    """Parse top-level `key: value` lines from the frontmatter block.

    Returns raw string values; YAML lists / nested mappings are
    returned as their raw textual form (caller parses if needed)."""
    out: dict[str, str] = {}
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return out
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2).strip().strip("'\"")
    return out


def _acceptance_bullets(text: str) -> list[str]:
    """Return the text of top-level `- [ ]` / `- [x]` checklist
    items inside `## Acceptance`. Nested sub-bullets are not
    returned — they ride on the parent's intent and would inflate
    vocabulary-hit false positives."""
    lines = text.splitlines()
    in_acceptance = False
    out: list[str] = []
    for line in lines:
        if line.startswith("## "):
            in_acceptance = (line.rstrip() == "## Acceptance")
            continue
        if not in_acceptance:
            continue
        if re.match(r"^- \[[ xX]\]\s*", line):
            out.append(line)
    return out


def _scan_vocabulary(bullets: list[str]) -> list[str]:
    """Return the subset of VOCABULARY_SET whose tokens appear
    (case-insensitive substring match) in any acceptance bullet.
    Deduplicated, order-preserving against VOCABULARY_SET."""
    blob = "\n".join(bullets).lower()
    return [tok for tok in VOCABULARY_SET if tok in blob]


def _parse_surfaces_block(text: str) -> list[dict[str, Any]]:
    """Find a `## Pre-audit external surfaces` section that
    contains a fenced ```yaml block listing surfaces.

    Accepted schema (narrow):

        ## Pre-audit external surfaces

        ```yaml
        surfaces:
          - kind: cli
            target: wasmtime
            expected_capabilities: [stdin, frame, length-prefix]
          - kind: lsp
            target: pyright
            expected_capabilities: [hover, references]
            probe: "spin up pyright in stdio mode and send initialize"
        ```

    Returns a list of `{kind, target, expected_capabilities, probe}`
    dicts (probe defaults to ""). Malformed entries are skipped
    silently — the helper is best-effort and the test suite pins
    the happy paths.
    """
    lines = text.splitlines()
    in_section = False
    in_fence = False
    yaml_lines: list[str] = []
    for line in lines:
        if line.startswith("## "):
            in_section = (line.rstrip() == "## Pre-audit external surfaces")
            in_fence = False
            continue
        if not in_section:
            continue
        if line.strip().startswith("```yaml"):
            in_fence = True
            continue
        if in_fence and line.strip().startswith("```"):
            in_fence = False
            break
        if in_fence:
            yaml_lines.append(line)

    return _parse_surfaces_yaml(yaml_lines)


def _parse_surfaces_yaml(yaml_lines: list[str]) -> list[dict[str, Any]]:
    """Hand-roll a tiny YAML subset for the `surfaces:` block.

    Accepts:
      surfaces:
        - kind: cli
          target: wasmtime
          expected_capabilities: [a, b, c]
          probe: "free text"

    Tolerates blank lines and `#` comment lines. Anything outside
    the `surfaces:` list is ignored.
    """
    out: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    in_surfaces = False

    for raw in yaml_lines:
        line = raw.rstrip()
        stripped = line.lstrip(" ")
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(stripped)

        if indent == 0:
            in_surfaces = stripped.startswith("surfaces:")
            if current is not None:
                out.append(current)
                current = None
            continue
        if not in_surfaces:
            continue

        if stripped.startswith("- "):
            if current is not None:
                out.append(current)
            current = {"expected_capabilities": [], "probe": ""}
            rest = stripped[2:].strip()
            if ":" in rest:
                k, _, v = rest.partition(":")
                _assign(current, k.strip(), v.strip())
        elif current is not None and ":" in stripped:
            k, _, v = stripped.partition(":")
            _assign(current, k.strip(), v.strip())

    if current is not None:
        out.append(current)
    return out


def _assign(d: dict[str, Any], key: str, raw: str) -> None:
    """Best-effort YAML-scalar coercion for the narrow schema."""
    val: Any = raw.strip().strip("'\"")
    if key == "expected_capabilities":
        if val.startswith("[") and val.endswith("]"):
            inside = val[1:-1].strip()
            items = [s.strip().strip("'\"") for s in inside.split(",")
                     if s.strip()]
            d[key] = items
        else:
            d[key] = []
    elif key in ("kind", "target", "probe"):
        d[key] = val
    else:
        d[key] = val


def _probe_cli(surface: dict[str, Any]) -> dict[str, Any]:
    """Run `<target> --help` (timeout HELP_TIMEOUT_SECONDS) and
    substring-match each `expected_capabilities[]` keyword against
    the combined stdout+stderr.

    Returns a per-surface `probe_result` dict:
        status:               "matched" | "mismatch" | "invocation_error"
        help_excerpt:         first 400 chars of help output (mismatch)
        matched_capabilities: [tokens that appeared in help]
        missing_capabilities: [tokens that did NOT appear]
        detail:               (invocation_error only) one-line cause
    """
    target = surface.get("target", "")
    expected = surface.get("expected_capabilities", []) or []

    if not target:
        return {
            "status": "invocation_error",
            "detail": "empty target",
            "matched_capabilities": [],
            "missing_capabilities": list(expected),
        }

    resolved = shutil.which(target)
    if resolved is None:
        return {
            "status": "invocation_error",
            "detail": f"binary not found on PATH: {target}",
            "matched_capabilities": [],
            "missing_capabilities": list(expected),
        }

    try:
        proc = subprocess.run(
            [resolved, "--help"],
            capture_output=True, text=True,
            timeout=HELP_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return {
            "status": "invocation_error",
            "detail": f"--help timed out after {HELP_TIMEOUT_SECONDS}s",
            "matched_capabilities": [],
            "missing_capabilities": list(expected),
        }
    except OSError as exc:
        return {
            "status": "invocation_error",
            "detail": f"OS error invoking --help: {exc}",
            "matched_capabilities": [],
            "missing_capabilities": list(expected),
        }

    if proc.returncode != 0:
        return {
            "status": "invocation_error",
            "detail": (f"--help exited {proc.returncode}: "
                       f"{(proc.stderr or '').strip()[:200]}"),
            "matched_capabilities": [],
            "missing_capabilities": list(expected),
        }

    help_text = (proc.stdout or "") + "\n" + (proc.stderr or "")
    lower = help_text.lower()
    matched = [tok for tok in expected if tok.lower() in lower]
    missing = [tok for tok in expected if tok.lower() not in lower]

    if not expected:
        # No capabilities declared — degenerate match (operator
        # only wants the surface declared for audit trail).
        return {
            "status": "matched",
            "matched_capabilities": [],
            "missing_capabilities": [],
        }

    if missing and not matched:
        excerpt = help_text.strip()
        if len(excerpt) > 400:
            excerpt = excerpt[:397] + "..."
        return {
            "status": "mismatch",
            "help_excerpt": excerpt,
            "matched_capabilities": matched,
            "missing_capabilities": missing,
        }

    # Partial match counts as match — at least one declared
    # capability appeared in --help, so the framing assumption
    # has SOME basis. Operators can tighten by listing only the
    # capabilities that MUST appear.
    return {
        "status": "matched",
        "matched_capabilities": matched,
        "missing_capabilities": missing,
    }


def _probe_non_cli(surface: dict[str, Any]) -> dict[str, Any]:
    """Non-cli kinds (`lsp`, `http`, `db`): emit
    `requires_runtime_probe: true` with the operator's `probe:`
    text echoed back. Autonomous round cannot trust live services.
    """
    return {
        "status": "requires_runtime_probe",
        "probe": surface.get("probe", ""),
    }


def _build_vocab_question(hits: list[str]) -> dict[str, Any]:
    quoted = ", ".join(f"`{h}`" for h in hits) or "(none)"
    return {
        "header": QUESTION_HEADER_VOCAB,
        "text": (
            "This item's `## Acceptance` mentions framing/protocol "
            f"vocabulary ({quoted}) but does not declare a "
            "`## Pre-audit external surfaces` block. Without a "
            "declaration the autonomous round cannot verify the "
            "underlying CLI / service implements the assumed "
            "protocol shape. Add a declaration, or confirm the "
            "vocabulary use is incidental."
        ),
        "options": [
            {
                "label": "Add a `## Pre-audit external surfaces` declaration",
                "description": (
                    "Operator edits the item to add the missing "
                    "block listing each external surface "
                    "(kind/target/expected_capabilities/probe). "
                    "Scope-groom re-runs the helper after the edit."
                ),
            },
            {
                "label": "Vocabulary is incidental — flip anyway",
                "description": (
                    "Operator confirms the framing words appear "
                    "in acceptance but the item does NOT depend "
                    "on an external CLI / service with that "
                    "protocol shape. Helper writes a "
                    "`## Pre-audit external surfaces` block with "
                    "an explicit `none: incidental_vocabulary` "
                    "marker for the audit trail."
                ),
            },
            {
                "label": "Reclassify to `manual` for operator drive",
                "description": (
                    "Operator picks this when the missing "
                    "declaration is a symptom of larger "
                    "ambiguity — the item flips to `manual` "
                    "instead of `open` and a future scope-groom "
                    "(or human edit) resolves the surface "
                    "definition."
                ),
            },
        ],
    }


def _build_mismatch_question(reasons: list[dict[str, Any]]) -> dict[str, Any]:
    targets = [r.get("target", "") for r in reasons
               if r.get("kind") in ("cli_protocol_mismatch",
                                    "cli_invocation_error")]
    target_quoted = ", ".join(f"`{t}`" for t in targets if t) or "(unknown)"
    return {
        "header": QUESTION_HEADER_MISMATCH,
        "text": (
            "One or more declared `kind: cli` surfaces "
            f"({target_quoted}) failed protocol verification: "
            "`--help` either lacks the declared "
            "`expected_capabilities[]` keywords, or the binary "
            "could not be invoked. Continuing as-is will likely "
            "abort the build round at the actor-implementation "
            "step. How should scope-groom finalize?"
        ),
        "options": [
            {
                "label": "Tighten the acceptance to match the CLI",
                "description": (
                    "Operator rewrites the item's `## Scope` / "
                    "`## Acceptance` so the framing assumption "
                    "matches what `<target> --help` actually "
                    "advertises. Scope-groom re-runs the helper "
                    "after the edit."
                ),
            },
            {
                "label": "Add a shim layer to the acceptance",
                "description": (
                    "Operator confirms the item must wrap the "
                    "CLI with a senkani-owned shim (e.g. a "
                    "Python / TypeScript subprocess runner) that "
                    "implements the missing protocol. Acceptance "
                    "gains a sub-bullet for shipping the shim."
                ),
            },
            {
                "label": "Flip to `manual + decomposable: true`",
                "description": (
                    "Operator picks this when the protocol "
                    "mismatch points at a larger design "
                    "question. The item parks at `manual` and "
                    "a future decompose round splits it."
                ),
            },
        ],
    }


def scan(item_path: Path) -> dict[str, Any]:
    text = item_path.read_text(encoding="utf-8")
    bullets = _acceptance_bullets(text)
    vocab_hits = _scan_vocabulary(bullets)

    declared = _parse_surfaces_block(text)
    surfaces_out: list[dict[str, Any]] = []
    reasons: list[dict[str, Any]] = []

    for s in declared:
        kind = s.get("kind", "").lower()
        target = s.get("target", "")
        expected = s.get("expected_capabilities", []) or []
        probe = s.get("probe", "")

        if kind == "cli":
            result = _probe_cli(s)
            surface_record = {
                "kind": "cli",
                "target": target,
                "expected_capabilities": list(expected),
                "probe_result": result,
            }
            if result["status"] == "mismatch":
                reasons.append({
                    "kind": "cli_protocol_mismatch",
                    "target": target,
                    "missing_capabilities": result.get(
                        "missing_capabilities", []),
                    "matched_capabilities": result.get(
                        "matched_capabilities", []),
                    "help_excerpt": result.get("help_excerpt", ""),
                })
            elif result["status"] == "invocation_error":
                reasons.append({
                    "kind": "cli_invocation_error",
                    "target": target,
                    "detail": result.get("detail", ""),
                    "missing_capabilities": result.get(
                        "missing_capabilities", []),
                })
        elif kind in ("lsp", "http", "db"):
            result = _probe_non_cli(s)
            surface_record = {
                "kind": kind,
                "target": target,
                "expected_capabilities": list(expected),
                "probe": probe,
                "probe_result": result,
            }
        else:
            # Unknown kind — record verbatim, do NOT fire.
            surface_record = {
                "kind": kind or "(missing)",
                "target": target,
                "expected_capabilities": list(expected),
                "probe": probe,
                "probe_result": {
                    "status": "unknown_kind",
                    "detail": (f"kind '{kind}' not in supported "
                               f"set {list(KINDS)}"),
                },
            }
        surfaces_out.append(surface_record)

    if vocab_hits and not declared:
        reasons.append({
            "kind": "vocabulary_without_surface",
            "vocabulary_hits": vocab_hits,
        })

    suggested_questions: list[dict[str, Any]] = []
    has_mismatch_or_error = any(
        r["kind"] in ("cli_protocol_mismatch", "cli_invocation_error")
        for r in reasons
    )
    has_vocab_only = any(
        r["kind"] == "vocabulary_without_surface" for r in reasons
    )

    if has_mismatch_or_error:
        suggested_questions.append(_build_mismatch_question(reasons))
    if has_vocab_only:
        suggested_questions.append(_build_vocab_question(vocab_hits))

    should_fire = bool(reasons)
    return {
        "item": str(item_path),
        "should_fire": should_fire,
        "reasons": reasons,
        "surfaces": surfaces_out,
        "vocabulary_hits": vocab_hits,
        "vocabulary_set": list(VOCABULARY_SET),
        "kinds": list(KINDS),
        "suggested_questions": suggested_questions,
        "suggested_question": (suggested_questions[0]
                               if suggested_questions else None),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=("Scan an item for framing-vocabulary use without "
                     "a `## Pre-audit external surfaces` declaration, "
                     "and validate declared `kind: cli` surfaces by "
                     "running `<target> --help`. Emits suggested "
                     "AskUserQuestion payloads for SKILL.md to "
                     "append to the scope-groom battery, or for "
                     "build-mode Step 2 to consume as a "
                     "reclassification signal."))
    parser.add_argument("item", type=Path,
                        help="Path to backlog/<id>-<slug>.md")
    args = parser.parse_args(argv)

    if not args.item.exists():
        print(f"error: item not found: {args.item}", file=sys.stderr)
        return 2

    try:
        result = scan(args.item)
    except Exception as exc:
        print(f"error: scan failed: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(result, indent=2))
    return 1 if result["should_fire"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
