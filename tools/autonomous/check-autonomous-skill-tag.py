#!/usr/bin/env python3
"""
check-autonomous-skill-tag — flag suspected `skills`/`autonomous_skill`
subsystem-tag mistags in the autonomous-loop backlog.

Walks `spec/autonomous/backlog/*.md`. For each item whose frontmatter
`affects:` list contains `skills`, scans the body for surface markers
that suggest the change is actually an autonomous-loop change (not a
senkani HandManifest change). Markers searched:

    SKILL.md
    spec/autonomous/
    ~/.claude/skills/
    tools/autonomous/

A match means the item probably wants `autonomous_skill` instead of
`skills` (see spec/autonomous/PROCESS.md `## Tag selection: skills vs
autonomous_skill`). Exits non-zero with one line per flagged item.

This is an informational pre-audit step, NOT a CI gate. False
positives are acceptable (a HandManifest item that mentions
`tools/autonomous/` in passing); false negatives on a true mistag
are a regression.

Background: `process-gap-skills-subsystem-tag-collision-2026-05-13`.

Usage:
    python3 tools/autonomous/check-autonomous-skill-tag.py [SPEC_DIR]

Exit codes:
    0 — no suspected mistags found
    1 — one or more flagged items (each printed to stdout)
    2 — usage / IO error
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

SURFACE_MARKERS = (
    "SKILL.md",
    "spec/autonomous/",
    "~/.claude/skills/",
    "tools/autonomous/",
)


def parse_frontmatter(text: str) -> dict[str, str]:
    """Return raw string values for top-level frontmatter keys.

    Only single-line `key: value` form is needed for `affects:`."""
    out: dict[str, str] = {}
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return out
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def affects_has_skills(value: str) -> bool:
    """`affects:` is rendered as a single-line YAML flow list.

    Match the bare token `skills` (not `autonomous_skill`)."""
    if not value:
        return False
    tokens = re.split(r"[\s,\[\]]+", value)
    return "skills" in [t.strip() for t in tokens]


def body_after_frontmatter(text: str) -> str:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return text
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            return "\n".join(lines[i + 1 :])
    return text


def find_markers(body: str) -> list[str]:
    return [m for m in SURFACE_MARKERS if m in body]


def main(argv: list[str]) -> int:
    spec_dir = Path(argv[1]) if len(argv) > 1 else Path("spec")
    backlog_dir = spec_dir / "autonomous" / "backlog"
    if not backlog_dir.is_dir():
        print(f"error: {backlog_dir} is not a directory", file=sys.stderr)
        return 2

    flagged: list[tuple[str, list[str]]] = []
    for path in sorted(backlog_dir.glob("*.md")):
        if path.name == "index.md":
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as e:
            print(f"error: cannot read {path}: {e}", file=sys.stderr)
            return 2
        fm = parse_frontmatter(text)
        if not affects_has_skills(fm.get("affects", "")):
            continue
        markers = find_markers(body_after_frontmatter(text))
        if markers:
            flagged.append((path.name, markers))

    if not flagged:
        print("check-autonomous-skill-tag: no suspected mistags.")
        return 0

    print("check-autonomous-skill-tag: suspected mistags (`skills` tag, autonomous-loop surface):")
    for name, markers in flagged:
        marker_list = ", ".join(markers)
        print(f"  {name} — surface markers: {marker_list}")
    print(
        "\nReview: if the item is actually an autonomous-loop change, swap "
        "`skills` → `autonomous_skill` in its `affects:` frontmatter list. "
        "See spec/autonomous/PROCESS.md `## Tag selection: skills vs "
        "autonomous_skill`."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
