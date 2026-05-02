#!/usr/bin/env python3
"""
Regenerate spec/autonomous/backlog/index.md and
spec/autonomous/completed/index.md from the per-item frontmatter
in the v2 tree. Used by /senkani-autonomous round-close.

Usage: python3 tools/autonomous/regen_indexes.py [SPEC_DIR]
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))
import migrate  # type: ignore  # noqa: E402
from roundtrip import parse_frontmatter_block  # type: ignore  # noqa: E402


def main() -> int:
    spec_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("spec")
    auto_dir = spec_dir / "autonomous"
    backlog_dir = auto_dir / "backlog"
    completed_dir = auto_dir / "completed"

    items_by_status: dict[str, list[dict]] = {
        "open": [], "blocked": [], "manual": [],
        "manual_ready": [], "in_progress": [],
    }
    completed_records: list[dict] = []

    for f in sorted(backlog_dir.glob("*.md")):
        if f.name == "index.md":
            continue
        fm, _ = parse_frontmatter_block(f.read_text())
        status = fm.get("status", "open")
        # blocked_by is a YAML inline list — split if not parsed
        bb = fm.get("blocked_by", [])
        if isinstance(bb, str):
            bb_str = bb.strip()
            if bb_str.startswith("[") and bb_str.endswith("]"):
                inside = bb_str[1:-1].strip()
                bb = [s.strip().strip('"').strip("'") for s in inside.split(",") if s.strip()]
            elif bb_str:
                bb = [bb_str]
            else:
                bb = []
        rec = {
            "id": fm.get("id", f.stem),
            "type": fm.get("type", "?"),
            "title": fm.get("title", "").strip('"'),
            "filename": f.name,
            "blocked_by": bb,
            "blocked_reason": fm.get("blocked_reason", ""),
            "groomed": fm.get("groomed", ""),
        }
        items_by_status.setdefault(status, []).append(rec)

    for f in sorted(completed_dir.rglob("*.md")):
        if f.name == "index.md":
            continue
        fm, _ = parse_frontmatter_block(f.read_text())
        rel = f.relative_to(completed_dir).as_posix()
        completed_records.append({
            "id": fm.get("id", f.stem),
            "type": fm.get("type", "?"),
            "title": fm.get("title", "").strip('"'),
            "shipped": fm.get("shipped", ""),
            "rel_path": rel,
        })

    for k in items_by_status:
        items_by_status[k].sort(key=lambda r: r["id"])

    migrate.emit_backlog_index(items_by_status, backlog_dir / "index.md")
    migrate.emit_completed_index(completed_records, completed_dir / "index.md")
    print(f"[regen] backlog: {sum(len(v) for v in items_by_status.values())} items "
          f"({', '.join(f'{k}={len(v)}' for k,v in items_by_status.items() if v)})")
    print(f"[regen] completed: {len(completed_records)} items")
    return 0


if __name__ == "__main__":
    sys.exit(main())
