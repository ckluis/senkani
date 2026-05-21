#!/usr/bin/env python3
"""
check_categorical_block — scan a scope-groom item's body for action
patterns that are categorically non-autonomous regardless of
operator authorization.

Scope-groom mode (in `~/.claude/skills/senkani-autonomous/SKILL.md`)
calls this helper between phase 7 ("Synthesis from answers") and
phase 8 ("Re-audit"). When at least one pattern matches AND the
operator's interview answers did NOT pick a Manual/Cowork path,
SKILL.md issues an extra `AskUserQuestion` override prompt:
"Categorical pattern(s) [list] matched in Acceptance — these never
run autonomously by default. Override and flip to `open` anyway?"

Default behavior: flip to `manual` (recommended). Operator may
override and flip to `open` under an `override_categorical: true`
audit flag.

Originating item:
`process-gap-build-round-categorical-action-vetting-2026-05-07`.
Parent finding:
`integrity-completed-items-vs-fix-branch-divergence-2026-05-07`
(2026-05-07 build round abort — three categorical actions exceeded
the autonomous envelope under auto-mode's "shared/production state
needs explicit user confirmation" rule).

Stdlib-only (no PyYAML). Manifest parse is line-based for the small
`scope_groom.categorical_block:` list we read.

Usage:
    python3 tools/autonomous/check_categorical_block.py \\
        <item.md> [--manifest spec/autonomous-manifest.yaml]

Output (stdout): JSON record with:
    {
      "item": "<path>",
      "matched": [
        {
          "pattern_id": <int 1-8 for defaults, "manifest:<index>" for manifest entries>,
          "pattern_name": "<short name>",
          "regex": "<source regex>",
          "matched_excerpt": "<≤120 chars from the body>",
          "line": <1-indexed line in the body>,
          "section": "<heading the match fell under, e.g. '## Acceptance'>"
        },
        ...
      ],
      "default_patterns_total": 8,
      "manifest_patterns_total": <int>,
      "marker_constant": "// scope-groom-managed:",
      "scanned_sections": ["## Scope", "## Acceptance", ...]
    }

Exit codes:
    0 — no matches (scope-groom flips to `open` without override prompt)
    1 — at least one match (SKILL.md issues override prompt)
    2 — usage / IO error
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Iterable

SCOPE_GROOM_MARKER = "// scope-groom-managed:"
"""Comment marker tagged on lines that scope-groom's own narrow-rule
writes (from `process-gap-harness-vs-item-authorization-mismatch`)
add to `.claude/settings.local.json`. Pattern #6 (.claude/settings.local.json
edits) ignores any matched span whose surrounding context is entirely
marker-tagged — the sibling's writer pulls this same constant by
import so a rename here surfaces as a test failure there."""

SECTIONS_SCANNED = ("## Scope", "## Acceptance", "## Notes", "## Setup",
                    "## Teardown", "## Execution steps")
"""Body sections scope-groom inspects. The Acceptance section is the
load-bearing case (per Acceptance bullet 2: 'scope-groom scans the body
it's about to write'); the others are scanned defensively so a pattern
buried in Scope or Notes still surfaces."""


def default_patterns() -> list[dict]:
    """The 8-pattern seed from the originating item's Acceptance #1.

    Each pattern is `(id, name, regex, exception_check_or_none)`.
    The `exception_check` callable, if present, takes the matched
    text span + the full body and returns True if the match should
    be filtered out (i.e. the exception applies)."""
    return [
        {
            "id": 1,
            "name": "git-push-to-protected-branch",
            "regex": re.compile(
                r"\bgit\s+push\s+(?:--\S+\s+)*\S+\s+"
                r"(?:main|master|release|production|prod|stable)\b",
                re.IGNORECASE,
            ),
            "exception": None,
        },
        {
            "id": 2,
            "name": "gh-pr-merge-into-protected",
            "regex": re.compile(
                r"\bgh\s+pr\s+merge\b",
                re.IGNORECASE,
            ),
            "exception": None,
        },
        {
            "id": 3,
            "name": "skill-md-self-edit",
            "regex": re.compile(
                r"~/\.claude/skills/senkani-autonomous/SKILL\.md",
            ),
            "exception": None,
        },
        {
            "id": 4,
            "name": "git-hooks-or-ci-workflows-edit",
            "regex": re.compile(
                r"(?:\.git/hooks/|\.github/workflows/)",
            ),
            "exception": None,
        },
        {
            "id": 5,
            "name": "rm-rf-against-sensitive-tree",
            "regex": re.compile(
                r"\brm\s+(?:-[a-zA-Z]*[rRf]+[a-zA-Z]*\s+)+"
                r"(?:tools/soak/|spec/autonomous/|~/|\$HOME)",
            ),
            "exception": None,
        },
        {
            "id": 6,
            "name": "settings-local-edit-without-marker",
            "regex": re.compile(
                r"\.claude/settings\.local\.json",
            ),
            "exception": "marker_only",
        },
        {
            "id": 7,
            "name": "package-resolved-dep-pin-edit",
            "regex": re.compile(
                r"\bPackage\.resolved\b",
            ),
            "exception": None,
        },
        {
            "id": 8,
            "name": "sudo-invocation",
            "regex": re.compile(
                r"\bsudo\s+",
            ),
            "exception": None,
        },
    ]


def parse_manifest_categorical_block(manifest_path: Path) -> list[dict]:
    """Read `scope_groom.categorical_block: [...]` from the manifest.

    Returns a list of `{id, name, regex, exception}` dicts merged
    with defaults via set-union (per Acceptance bullet 4 — 'Merge
    defaults + manifest patterns. Set union. Default patterns are
    the floor; manifest extends').

    No PyYAML dep — we line-scan for the block. Each line under
    `scope_groom:` → `categorical_block:` is parsed as
    `- name: <name>` followed by `regex: <pattern>`. The shape:

        scope_groom:
          categorical_block:
            - name: my-extra-pattern
              regex: 'somepattern'

    Missing block, empty list, or malformed entries → empty list
    (skill defaults still apply; the manifest entry is purely
    additive)."""
    if not manifest_path.exists():
        return []
    text = manifest_path.read_text(encoding="utf-8")
    lines = text.splitlines()

    in_scope_groom = False
    in_categorical_block = False
    base_indent = -1
    out: list[dict] = []
    current: dict | None = None
    manifest_index = 0

    for raw in lines:
        stripped = raw.rstrip()
        if not stripped or stripped.lstrip().startswith("#"):
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        token = stripped.lstrip(" ")

        if indent == 0:
            in_scope_groom = (token.startswith("scope_groom:"))
            in_categorical_block = False
            base_indent = -1
            if current:
                _finalize_manifest_pattern(current, manifest_index, out)
                manifest_index += 1
                current = None
            continue

        if in_scope_groom and not in_categorical_block:
            if token.startswith("categorical_block:"):
                in_categorical_block = True
                base_indent = indent
            continue

        if in_categorical_block:
            if indent <= base_indent:
                in_scope_groom = (token.startswith("scope_groom:")
                                  and indent == 0)
                in_categorical_block = False
                if current:
                    _finalize_manifest_pattern(current, manifest_index, out)
                    manifest_index += 1
                    current = None
                continue
            if token.startswith("- "):
                if current:
                    _finalize_manifest_pattern(current, manifest_index, out)
                    manifest_index += 1
                current = {}
                rest = token[2:].strip()
                if ":" in rest:
                    k, _, v = rest.partition(":")
                    current[k.strip()] = v.strip().strip("'\"")
            elif current is not None and ":" in token:
                k, _, v = token.partition(":")
                current[k.strip()] = v.strip().strip("'\"")

    if current:
        _finalize_manifest_pattern(current, manifest_index, out)

    return out


def _finalize_manifest_pattern(raw: dict, index: int,
                               out: list[dict]) -> None:
    name = raw.get("name", f"manifest-{index}")
    pattern_src = raw.get("regex", "")
    if not pattern_src:
        return
    try:
        compiled = re.compile(pattern_src)
    except re.error:
        return
    out.append({
        "id": f"manifest:{index}",
        "name": name,
        "regex": compiled,
        "exception": raw.get("exception"),
    })


def merge_patterns(defaults: list[dict],
                   manifest: list[dict]) -> list[dict]:
    """Set-union merge: defaults are the floor, manifest extends.

    Names collide → manifest entry wins (operator override of a
    default for the same name is treated as 'I know what I'm doing,
    extend with mine'). Default-only entries always fire."""
    by_name: dict[str, dict] = {p["name"]: p for p in defaults}
    for p in manifest:
        by_name[p["name"]] = p
    return list(by_name.values())


def parse_body_with_sections(text: str) -> list[tuple[str, int, str]]:
    """Split the body into (section_heading, line_no, line_text)
    tuples. Frontmatter is skipped; line_no is 1-indexed from the
    start of the file."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        body_start = 0
    else:
        body_start = None
        for i, line in enumerate(lines[1:], start=1):
            if line.strip() == "---":
                body_start = i + 1
                break
        if body_start is None:
            body_start = 1
    out: list[tuple[str, int, str]] = []
    current_section = ""
    for i in range(body_start, len(lines)):
        line = lines[i]
        if line.startswith("## "):
            current_section = line.rstrip()
        out.append((current_section, i + 1, line))
    return out


def _marker_only_exception(matched_text: str, context_lines: list[str]) -> bool:
    """Pattern #6 exception: a `.claude/settings.local.json` mention
    is allowed if the SURROUNDING context (the matched line + 2
    before + 2 after) is entirely tagged with SCOPE_GROOM_MARKER.

    Conservative: the marker must appear on the SAME line as the
    match OR every non-blank context line must carry the marker."""
    if SCOPE_GROOM_MARKER in matched_text:
        return True
    relevant = [ln for ln in context_lines if ln.strip()]
    if not relevant:
        return False
    return all(SCOPE_GROOM_MARKER in ln for ln in relevant)


def scan(item_path: Path, manifest_path: Path | None) -> dict:
    text = item_path.read_text(encoding="utf-8")
    body_tuples = parse_body_with_sections(text)
    body_lines = [t[2] for t in body_tuples]

    defaults = default_patterns()
    manifest_patterns = (parse_manifest_categorical_block(manifest_path)
                         if manifest_path else [])
    patterns = merge_patterns(defaults, manifest_patterns)

    matches: list[dict] = []
    for section, line_no, line in body_tuples:
        if section not in SECTIONS_SCANNED:
            continue
        for pat in patterns:
            for m in pat["regex"].finditer(line):
                excerpt = line.strip()
                if len(excerpt) > 120:
                    excerpt = excerpt[:117] + "..."
                if pat["exception"] == "marker_only":
                    idx = body_lines.index(line) if line in body_lines else -1
                    if idx >= 0:
                        ctx_start = max(0, idx - 2)
                        ctx_end = min(len(body_lines), idx + 3)
                        ctx = body_lines[ctx_start:ctx_end]
                    else:
                        ctx = [line]
                    if _marker_only_exception(line, ctx):
                        continue
                matches.append({
                    "pattern_id": pat["id"],
                    "pattern_name": pat["name"],
                    "regex": pat["regex"].pattern,
                    "matched_excerpt": excerpt,
                    "line": line_no,
                    "section": section,
                })

    return {
        "item": str(item_path),
        "matched": matches,
        "default_patterns_total": len(defaults),
        "manifest_patterns_total": len(manifest_patterns),
        "marker_constant": SCOPE_GROOM_MARKER,
        "scanned_sections": list(SECTIONS_SCANNED),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=("Scan a scope-groom item body for categorically-"
                     "non-autonomous action patterns."))
    parser.add_argument("item", type=Path,
                        help="Path to backlog/<id>-<slug>.md")
    parser.add_argument("--manifest", type=Path, default=None,
                        help=("Optional manifest path for "
                              "scope_groom.categorical_block extensions"))
    args = parser.parse_args(argv)

    if not args.item.exists():
        print(f"error: item not found: {args.item}", file=sys.stderr)
        return 2

    try:
        result = scan(args.item, args.manifest)
    except Exception as exc:
        print(f"error: scan failed: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(result, indent=2))
    return 1 if result["matched"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
