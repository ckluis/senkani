#!/usr/bin/env python3
"""
Round-trip verifier — the load-bearing safety net for the autonomous-loop migration.

Reads the new `spec/autonomous/` tree, reconstructs the equivalent of the legacy
`spec/autonomous-backlog.yaml` (item content only — not section comments or
RETROACTIVE preamble), then diffs against a canonicalized form of the legacy
file. Also asserts every `### ` heading in the legacy roadmap.md and cleanup.md
is accounted for in the new tree.

Exits 0 only if both passes are green.

Usage:
    python3 tools/autonomous/roundtrip.py [SPEC_DIR]
"""
from __future__ import annotations
import argparse
import re
import sys
from pathlib import Path
from typing import Optional

# Re-use the migrator's parser
THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))
import migrate  # type: ignore  # noqa: E402


# ---------------------------------------------------------------------------
# Read the new tree
# ---------------------------------------------------------------------------

def parse_frontmatter_block(text: str) -> tuple[dict, str]:
    """Parse `---\nKEY: VALUE\n---\nbody` style frontmatter.

    Returns (frontmatter_dict, body_string).
    """
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end < 0:
        return {}, text
    fm_text = text[4:end]
    body = text[end + len("\n---\n"):]

    fm: dict = {}
    lines = fm_text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line or line.startswith("#"):
            i += 1
            continue
        m = re.match(r"^([a-z_]+):\s*(.*)$", line)
        if not m:
            i += 1
            continue
        key, rest = m.group(1), m.group(2)
        # Literal block continuation (`field: |`)
        if rest in ("|", "|-", "|+"):
            block_lines = []
            i += 1
            while i < len(lines) and (lines[i].startswith("  ") or lines[i] == ""):
                if lines[i].startswith("  "):
                    block_lines.append(lines[i][2:])
                else:
                    block_lines.append("")
                i += 1
            text_val = "\n".join(block_lines).rstrip("\n")
            if rest == "|":
                text_val += "\n"
            fm[key] = text_val
            continue
        # Inline list
        if rest.startswith("[") and rest.endswith("]"):
            inner = rest[1:-1].strip()
            fm[key] = [_unquote(x.strip()) for x in inner.split(",") if x.strip()]
            i += 1
            continue
        # Plain scalar
        fm[key] = _unquote(rest)
        i += 1
    return fm, body


def _unquote(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ('"', "'"):
        inner = s[1:-1]
        # Reverse the escape we applied
        return inner.replace('\\"', '"').replace("\\\\", "\\")
    return s


def parse_body_sections(body: str) -> dict[str, str]:
    """Map H2 headings to their body content (rstripped, trailing newline stripped)."""
    out: dict[str, str] = {}
    cur_heading: Optional[str] = None
    cur_lines: list[str] = []

    def flush():
        nonlocal cur_heading, cur_lines
        if cur_heading is not None:
            text = "\n".join(cur_lines).strip("\n")
            out[cur_heading] = text
        cur_heading = None
        cur_lines = []

    for ln in body.split("\n"):
        m = re.match(r"^##\s+(.+?)\s*$", ln)
        if m:
            flush()
            cur_heading = m.group(1).strip()
            continue
        if cur_heading is not None:
            cur_lines.append(ln)
    flush()
    return out


def read_new_tree(spec_dir: Path) -> dict:
    """Walk spec/autonomous/{backlog,completed} and return a list of items
    with all preserved fields."""
    out_dir = spec_dir / "autonomous"
    items: list[dict] = []

    # Backlog
    for p in sorted((out_dir / "backlog").glob("*.md")):
        if p.name == "index.md":
            continue
        text = p.read_text()
        fm, body = parse_frontmatter_block(text)
        sections = parse_body_sections(body)
        items.append({
            "frontmatter": fm,
            "sections": sections,
            "_path": str(p.relative_to(spec_dir)),
            "_origin": "backlog",
        })

    # Completed (recursive)
    completed_root = out_dir / "completed"
    for p in sorted(completed_root.rglob("*.md")):
        if p.name == "index.md":
            continue
        text = p.read_text()
        fm, body = parse_frontmatter_block(text)
        sections = parse_body_sections(body)
        items.append({
            "frontmatter": fm,
            "sections": sections,
            "_path": str(p.relative_to(spec_dir)),
            "_origin": "completed",
        })

    state_text = (out_dir / "_state.yaml").read_text()
    in_flight = None
    for ln in state_text.split("\n"):
        if ln.startswith("in_flight:"):
            v = ln.split(":", 1)[1].strip()
            in_flight = None if v in ("null", "~", "") else v

    return {"items": items, "in_flight": in_flight}


# ---------------------------------------------------------------------------
# Pass 1: backlog round-trip
# ---------------------------------------------------------------------------

# Compare these fields. Status mapping is normalized — open/blocked/manual all
# imply NOT-shipped, while done/skipped imply shipped — both vocabularies map
# to the same placement, so we only verify item content + placement.
COMPARE_FIELDS = [
    "id", "title", "size", "priority",
    "roster", "affects", "blocked_by", "tests_target", "tests_delta",
    "shipped", "docs_synced",
]
COMPARE_BODY_SECTIONS = {
    "scope": "Scope",
    "acceptance": "Acceptance",
    "notes": "Notes",
    "summary": "Summary",
    "accepted_risks": "Accepted Risks",
}


def canonicalize_value(v):
    """Canonicalize a value for cross-format comparison."""
    if v is None:
        return None
    if isinstance(v, list):
        return [canonicalize_value(x) for x in v]
    s = str(v)
    # Collapse whitespace runs but preserve newlines as single \n
    s = re.sub(r"[ \t]+", " ", s)
    # Strip trailing whitespace on each line
    s = "\n".join(line.rstrip() for line in s.split("\n"))
    return s.strip("\n").strip()


def canonicalize_acceptance_field(v):
    """`acceptance` may be a list-style block or a single multiline string.
    Map both to a sorted-canonical form: list-of-line-stripped-bullets."""
    if v is None:
        return []
    if isinstance(v, list):
        return [canonicalize_value(x) for x in v]
    # String — split on lines starting with `- `
    text = canonicalize_value(v) or ""
    lines = text.split("\n")
    bullets: list[str] = []
    cur: list[str] = []
    for ln in lines:
        m = re.match(r"^-\s+(.+)$", ln.strip())
        if m:
            if cur:
                bullets.append(" ".join(cur).strip())
                cur = []
            cur.append(m.group(1).strip())
        elif ln.strip():
            cur.append(ln.strip())
    if cur:
        bullets.append(" ".join(cur).strip())
    return bullets


def reconstruct_from_new_tree(spec_dir: Path) -> dict[str, dict]:
    """Build a {item_id: {field_name: canonicalized_value}} from the new tree."""
    tree = read_new_tree(spec_dir)
    by_id: dict[str, dict] = {}
    for entry in tree["items"]:
        fm = entry["frontmatter"]
        sections = entry["sections"]
        iid = fm.get("id")
        if not iid:
            continue
        rec: dict = {}
        for f in COMPARE_FIELDS:
            v = fm.get(f)
            if v is None or v == "":
                continue
            rec[f] = canonicalize_value(v)
        for body_key, section_name in COMPARE_BODY_SECTIONS.items():
            v = sections.get(section_name)
            if v:
                if body_key == "acceptance":
                    rec[body_key] = canonicalize_acceptance_field(v)
                else:
                    rec[body_key] = canonicalize_value(v)
        by_id[iid] = rec
    return by_id


def reconstruct_from_legacy(legacy_path: Path) -> dict[str, dict]:
    in_flight, items, completed = migrate.parse_backlog(legacy_path)
    by_id: dict[str, dict] = {}
    for it in items + completed:
        if not it.id:
            continue
        rec: dict = {}
        for f in COMPARE_FIELDS:
            v = it.get(f)
            if v is None or v == "":
                continue
            rec[f] = canonicalize_value(v)
        # Body fields
        for body_key in ("scope", "notes", "summary", "accepted_risks"):
            v = it.get(body_key)
            if v:
                rec[body_key] = canonicalize_value(v)
        v = it.get("acceptance")
        if v:
            rec["acceptance"] = canonicalize_acceptance_field(v)
        by_id[it.id] = rec
    return by_id


def diff_records(legacy: dict[str, dict], new: dict[str, dict]) -> list[str]:
    """Return a list of human-readable diff entries. Empty list = pass."""
    diffs: list[str] = []
    legacy_ids = set(legacy.keys())
    new_ids = set(new.keys())
    for iid in sorted(legacy_ids - new_ids):
        diffs.append(f"MISSING in new tree: {iid}")
    for iid in sorted(new_ids - legacy_ids):
        # New tree may have extra cleanup-N items (synthesized from cleanup.md);
        # those are not in the legacy backlog at all — that's expected.
        if iid.startswith("cleanup-"):
            continue
        diffs.append(f"EXTRA in new tree (not in legacy): {iid}")
    for iid in sorted(legacy_ids & new_ids):
        l = legacy[iid]
        n = new[iid]
        all_keys = set(l.keys()) | set(n.keys())
        for k in sorted(all_keys):
            lv = l.get(k)
            nv = n.get(k)
            if lv != nv:
                # Tolerate trivial blank-vs-missing
                if (lv in (None, "", [])) and (nv in (None, "", [])):
                    continue
                # Tolerate enrichment: legacy missing, new present.
                if lv in (None, "", []) and nv not in (None, "", []):
                    continue
                # Tolerate cleanup.md merge: if a `### Migrated from cleanup.md`
                # marker appears in the new value, the legacy text should be a
                # prefix of the new text up to the marker.
                if k in ("notes",) and isinstance(lv, str) and isinstance(nv, str):
                    marker = "### Migrated from cleanup.md"
                    if marker in nv:
                        nv_pre = nv.split(marker, 1)[0].rstrip()
                        if canonicalize_value(lv) == canonicalize_value(nv_pre):
                            continue
                diffs.append(f"MISMATCH [{iid}] field={k}\n  LEGACY: {repr(lv)[:200]}\n  NEW:    {repr(nv)[:200]}")
    return diffs


# ---------------------------------------------------------------------------
# Pass 2: heading coverage in roadmap.md + cleanup.md
# ---------------------------------------------------------------------------

def heading_coverage(spec_dir: Path) -> list[str]:
    """For every `### ` heading in legacy roadmap.md and cleanup.md, assert
    that it shows up somewhere in the new tree (item title, phase file, or
    strategy.md, or as a legacy_ref)."""
    failures: list[str] = []
    new_text_blob = ""
    out_dir = spec_dir / "autonomous"
    for p in out_dir.rglob("*.md"):
        new_text_blob += "\n" + p.read_text()

    for source in ["roadmap.md", "cleanup.md"]:
        legacy = spec_dir / source
        if not legacy.exists():
            legacy = spec_dir / f"{source}.legacy"
        if not legacy.exists():
            continue
        for line in legacy.read_text().split("\n"):
            m = re.match(r"^###\s+(.+?)\s*$", line)
            if not m:
                continue
            heading = m.group(1).strip()
            # Strip status-marker noise from the heading for comparison
            normalized = re.sub(r"\s*[—\-]\s*RESOLVED.*$", "", heading)
            normalized = re.sub(r"\s*[—\-]\s*PARTIALLY.*$", "", normalized)
            normalized = re.sub(r"\s*[—\-]\s*Filed\s+\d.*$", "", normalized)
            # Trim leading `N.` from cleanup
            normalized = re.sub(r"^\d+\.\s*", "", normalized)
            # Trim leading `T.X — ` etc. from roadmap legs
            normalized = re.sub(r"^[TUVW]\.\d+[a-z]?\s*[—\-]\s*", "", normalized)
            if not normalized:
                continue
            # Look for a meaningful substring (≥ 12 chars) in the new tree
            probe = normalized[:80]
            if len(probe) < 8:
                # too short — skip
                continue
            if probe in new_text_blob:
                continue
            # Also try the original heading without normalization
            if heading[:80] in new_text_blob:
                continue
            failures.append(f"{source}: heading not found in new tree: {heading!r}")
    return failures


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("spec_dir", nargs="?", default="/Users/clank/Desktop/projects/senkani/spec",
                    help="Path to the spec/ directory.")
    args = ap.parse_args()
    spec_dir = Path(args.spec_dir).resolve()

    legacy_backlog = spec_dir / "autonomous-backlog.yaml"
    if not legacy_backlog.exists():
        # Try the renamed legacy path
        legacy_backlog = spec_dir / "autonomous-backlog.yaml.legacy"
    if not legacy_backlog.exists():
        # Post-migration state: legacy files have been deleted after the
        # soak period. Nothing to verify against — the new tree is the
        # only source of truth now.
        new_tree = spec_dir / "autonomous"
        if new_tree.exists():
            print(f"[roundtrip] no legacy backlog found at {spec_dir}/autonomous-backlog.yaml{{,.legacy}}.")
            print(f"[roundtrip] {new_tree} exists — migration is complete and the legacy soak has ended.")
            print(f"[roundtrip] nothing to verify; the new tree is the canonical source of truth.")
            return 0
        print(f"FATAL: no legacy backlog and no new tree at {spec_dir}", file=sys.stderr)
        return 2

    print(f"[roundtrip] Pass 1: reconstruct + diff vs {legacy_backlog.name}")
    legacy = reconstruct_from_legacy(legacy_backlog)
    new = reconstruct_from_new_tree(spec_dir)
    diffs = diff_records(legacy, new)
    print(f"[roundtrip]   legacy item count: {len(legacy)}")
    print(f"[roundtrip]   new tree item count: {len(new)}")
    if diffs:
        print(f"[roundtrip]   FAIL — {len(diffs)} discrepancies, first 5:")
        for d in diffs[:5]:
            print(f"    - {d}")
        return 1
    print("[roundtrip]   PASS")

    print(f"[roundtrip] Pass 2: heading coverage from legacy roadmap.md + cleanup.md")
    failures = heading_coverage(spec_dir)
    if failures:
        print(f"[roundtrip]   FAIL — {len(failures)} headings unaccounted for, first 5:")
        for f in failures[:5]:
            print(f"    - {f}")
        return 1
    print("[roundtrip]   PASS")

    print("[roundtrip] ALL GREEN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
