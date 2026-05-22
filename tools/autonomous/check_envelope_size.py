#!/usr/bin/env python3
"""
check_envelope_size — scan a scope-groom item's frontmatter + body
for signals that the resulting `status: open` item exceeds the
60-min autonomous-round envelope, so scope-groom can ask the
operator a closing envelope-size question BEFORE flipping the
item.

Scope-groom mode (in `~/.claude/skills/senkani-autonomous/SKILL.md`)
calls this helper between phase 5 ("Audit the questions") and
phase 6 ("Run the interview"). When the helper exits non-zero, the
canonical question (header, text, three options a/b/c) returned
in the JSON record is appended to the AskUserQuestion battery.

Originating item:
`process-gap-scope-groom-meaty-size-envelope-check-2026-05-19`.
Parent finding: `phase-t3-wasm-sandbox` build round 2026-05-19
aborted because the scope-groomed item (size: meaty, 8 acceptance
bullets, 5-9 hour total scope) overflowed the 60-min envelope.

The trigger conditions (any fires the question):
  1. Frontmatter `size: meaty` (or any future `size: large`).
  2. `## Acceptance` section contains > BULLET_THRESHOLD top-level
     unchecked checklist items (`- [ ]` at line start, NOT
     nested sub-bullets).

Sibling helper to `check_categorical_block.py` — same JSON shape,
same stdlib-only constraint, same SKILL.md-invocation contract.

Stdlib-only (no PyYAML). Frontmatter parse is line-based.

Usage:
    python3 tools/autonomous/check_envelope_size.py <item.md>

Output (stdout): JSON record with:
    {
      "item": "<path>",
      "should_fire": <bool>,
      "reasons": [
        {"kind": "size", "value": "meaty"},
        {"kind": "bullet_count", "value": <int>, "threshold": 5}
      ],
      "size": "<value from frontmatter or null>",
      "bullet_count": <int>,
      "bullet_threshold": 5,
      "meaty_size_tokens": ["meaty", "large"],
      "suggested_question": {
        "header": "Envelope",
        "text": "<canonical text from the originating item>",
        "options": [
          {"label": "(a) keep `status: open`",  "description": "..."},
          {"label": "(b) flip to `status: manual` + groomable",
           "description": "..."},
          {"label": "(c) split into N child scope-groom items now",
           "description": "..."}
        ]
      }
    }

Exit codes:
    0 — no fire (item fits the envelope; flip to `open` as planned)
    1 — fire (SKILL.md appends the suggested_question to the battery)
    2 — usage / IO error
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

BULLET_THRESHOLD = 5
"""Top-level `## Acceptance` checkboxes above this count trigger the
envelope-size question. The threshold matches the originating item's
text: 'count acceptance bullets in the item's body ## Scope section;
if >5 OR the item declares size: meaty, auto-add the envelope-size
question to the battery.' Operator can override via the `(a) keep
status: open` option."""

MEATY_SIZE_TOKENS = ("meaty", "large")
"""Sizes that auto-fire the envelope-size question regardless of
bullet count. `meaty` is the live convention (per
spec/autonomous/PROCESS.md `## Status vocabulary`); `large` is
reserved for future use per the originating item's acceptance text."""

CANONICAL_QUESTION_HEADER = "Envelope"
"""AskUserQuestion `header` field — max 12 chars."""


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


def _acceptance_bullet_count(text: str) -> int:
    """Count top-level `- [ ]` checklist items inside `## Acceptance`.

    Only zero-indent bullets count — nested sub-bullets (any leading
    whitespace) are NOT counted, per Torvalds's audit note that
    parameterized sub-bullets shouldn't inflate the trigger count."""
    lines = text.splitlines()
    in_acceptance = False
    count = 0
    for line in lines:
        if line.startswith("## "):
            in_acceptance = (line.rstrip() == "## Acceptance")
            continue
        if not in_acceptance:
            continue
        if re.match(r"^- \[[ xX]\]", line):
            count += 1
    return count


def _build_question() -> dict[str, Any]:
    """The canonical envelope-size question from the originating
    item, rendered for AskUserQuestion. Returned as a mapping
    SKILL.md hands directly to the tool call."""
    return {
        "header": CANONICAL_QUESTION_HEADER,
        "text": ("This item's acceptance scope likely exceeds the "
                 "60-min autonomous round envelope (size: meaty, OR "
                 ">5 top-level acceptance bullets). How should "
                 "scope-groom finalize it?"),
        "options": [
            {
                "label": "(a) keep `status: open` and try the build",
                "description": ("Operator accepts that the build "
                                "round will likely abort and "
                                "reclassify to `manual` + "
                                "`decomposable: true` for a future "
                                "decompose-round split. Use when "
                                "the operator wants to confirm "
                                "the abort is the right next "
                                "step (e.g. learning where the "
                                "build round runs out of envelope "
                                "is itself useful information).")
            },
            {
                "label": "(b) flip directly to `manual + decomposable: true`",
                "description": ("Skip the wasted build round; let "
                                "a decompose round split into "
                                "≤60-min sub-items first. Default "
                                "for meaty items. The decompose "
                                "round interviews the operator on "
                                "the split shape and files N "
                                "children via "
                                "`tools/autonomous/file_sub_item.py`.")
            },
            {
                "label": "(c) split into N child scope-groom items now",
                "description": ("Operator names the N children; "
                                "each becomes a new scope-groomable "
                                "backlog item. Use when the operator "
                                "already knows the natural split "
                                "axis AND each child still needs a "
                                "go/no-go decision interview (not "
                                "just a code-decomposition).")
            },
        ],
    }


def scan(item_path: Path) -> dict[str, Any]:
    text = item_path.read_text(encoding="utf-8")
    front = _frontmatter(text)
    size = front.get("size")
    bullet_count = _acceptance_bullet_count(text)

    reasons: list[dict[str, Any]] = []
    if size and size.lower() in MEATY_SIZE_TOKENS:
        reasons.append({"kind": "size", "value": size})
    if bullet_count > BULLET_THRESHOLD:
        reasons.append({
            "kind": "bullet_count",
            "value": bullet_count,
            "threshold": BULLET_THRESHOLD,
        })

    should_fire = bool(reasons)
    return {
        "item": str(item_path),
        "should_fire": should_fire,
        "reasons": reasons,
        "size": size,
        "bullet_count": bullet_count,
        "bullet_threshold": BULLET_THRESHOLD,
        "meaty_size_tokens": list(MEATY_SIZE_TOKENS),
        "suggested_question": _build_question() if should_fire else None,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=("Scan a scope-groom item for envelope-size "
                     "signals (size: meaty OR >5 acceptance bullets) "
                     "and emit the canonical envelope-size question "
                     "for SKILL.md to append to the AskUserQuestion "
                     "battery."))
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
