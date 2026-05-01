#!/usr/bin/env python3
"""
One-shot migrator: spec/autonomous-backlog.yaml + spec/roadmap.md + spec/cleanup.md
                   → spec/autonomous/ tiered tree.

Idempotent. Reversible until verifier passes (legacy files renamed only by the
caller after roundtrip.py exits 0). Multiline blocks preserved byte-for-byte.

Usage:
    python3 tools/autonomous/migrate.py [SPEC_DIR]

If SPEC_DIR is given (e.g. spec.migrated/), reads from that and writes there.
Default: /Users/clank/Desktop/projects/senkani/spec
"""
from __future__ import annotations
import argparse
import os
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Hand-rolled backlog YAML parser
# ---------------------------------------------------------------------------

class Item:
    """One backlog item — direct mapping of fields seen across the YAML."""
    SCALAR_FIELDS = {
        "id", "title", "status", "size", "priority",
        "tests_target", "tests_delta", "shipped",
        "created", "last_touched",
    }
    LIST_FIELDS = {
        "roster", "affects", "blocked_by", "docs_synced",
        "source_inspirations",
    }
    BLOCK_FIELDS = {
        "scope", "acceptance", "notes", "summary",
        "accepted_risks", "blocked_reason",
    }
    # acceptance can also be a list-style block
    LIST_OR_BLOCK_FIELDS = {"acceptance", "docs_synced"}

    def __init__(self):
        self.fields: dict[str, object] = {}
        self.section: Optional[str] = None  # "items" or "completed"
        self.preceding_comment: list[str] = []  # nearest comment lines

    def __getitem__(self, k):
        return self.fields.get(k)

    def get(self, k, default=None):
        return self.fields.get(k, default)

    @property
    def id(self) -> str:
        return self.fields.get("id") or ""


def parse_backlog(path: Path) -> tuple[Optional[str], list[Item], list[Item]]:
    """Parse the legacy backlog YAML.

    Returns (in_flight, items_section, completed_section).
    """
    text = path.read_text()
    lines = text.split("\n")
    n = len(lines)

    in_flight: Optional[str] = None
    items: list[Item] = []
    completed: list[Item] = []

    section = None  # "items" | "completed"
    current: Optional[Item] = None

    def flush_current():
        nonlocal current
        if current is not None:
            if section == "items":
                items.append(current)
            elif section == "completed":
                completed.append(current)
            current = None

    i = 0
    while i < n:
        line = lines[i]

        # Top-level keys (column 0)
        if line.startswith("in_flight:"):
            value = line[len("in_flight:"):].strip()
            in_flight = None if value in ("null", "~", "") else value
            i += 1
            continue
        if line.rstrip() == "items:":
            flush_current()
            section = "items"
            i += 1
            continue
        if line.rstrip() == "completed:":
            flush_current()
            section = "completed"
            i += 1
            continue
        if (re.match(r"^[a-zA-Z_][\w-]*\s*:", line)
                and not line.startswith(" ")
                and not line.startswith("#")):
            # Other top-level keys (e.g., version:); ignored, not item-level
            i += 1
            continue

        # Item start: `^  - id: <value>`
        m = re.match(r"^  - id:\s*(.*?)\s*$", line)
        if m and section is not None:
            flush_current()
            current = Item()
            current.section = section
            current.fields["id"] = _strip_quotes(m.group(1))
            i += 1
            continue

        # Field line inside an item: `    <key>: <rest>`
        m = re.match(r"^    ([a-z_]+):\s*(.*?)\s*$", line)
        if m and current is not None:
            key = m.group(1)
            rest = m.group(2)
            value, consumed = _parse_field_value(lines, i, key, rest)
            current.fields[key] = value
            i = consumed
            continue

        i += 1

    flush_current()
    return in_flight, items, completed


def _strip_quotes(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ('"', "'"):
        return s[1:-1]
    return s


def _parse_field_value(lines: list[str], start: int, key: str, rest: str) -> tuple[object, int]:
    """Parse a field value beginning at lines[start].

    rest is the post-colon text from line `    key: rest`.

    Returns (value, next_line_index).

    Possible value shapes:
      - scalar:  rest is non-empty, no special leading char => string
      - inline list: `[a, b, c]` => python list
      - block list: empty rest, next lines `      - item` => python list
      - literal block: `|` or `|-` rest, next lines `      content` => string
      - multi-line continuation: scalar that wraps lines
      - empty (just `key:` with no rest, no continuation) => empty string
    """
    n = len(lines)
    i = start + 1

    # Inline list: `[ ... ]`
    if rest.startswith("[") and rest.endswith("]"):
        inner = rest[1:-1].strip()
        if not inner:
            return [], i
        return [_strip_quotes(x.strip()) for x in inner.split(",") if x.strip()], i

    # Inline list that wraps onto the next line(s) — opens with `[`, doesn't close
    if rest.startswith("[") and not rest.endswith("]"):
        buf = rest
        while i < n and not buf.rstrip().endswith("]"):
            buf += " " + lines[i].strip()
            i += 1
        # Strip surrounding brackets
        inner = buf.strip()[1:-1].strip()
        return [_strip_quotes(x.strip()) for x in inner.split(",") if x.strip()], i

    # Literal block: `|` or `|-` or `|+`
    if rest in ("|", "|-", "|+"):
        # Capture indented continuation
        block_lines = []
        # The block is indented relative to the key. The key itself is at 4 spaces;
        # the block content must be at >= 6 spaces.
        block_indent = None
        while i < n:
            nxt = lines[i]
            if nxt == "":
                block_lines.append("")
                i += 1
                continue
            # Stop at any line that's not blank and not deeper-indented than the key.
            if not nxt.startswith("      "):
                break
            if block_indent is None:
                # Determine indent from the first non-empty content line
                stripped_lead = len(nxt) - len(nxt.lstrip(" "))
                block_indent = stripped_lead
            block_lines.append(nxt[block_indent:] if len(nxt) >= block_indent else "")
            i += 1
        # Trim trailing empty lines (literal-block default = clip)
        if rest == "|" or rest == "|-":
            while block_lines and block_lines[-1] == "":
                block_lines.pop()
        text = "\n".join(block_lines)
        if rest != "|-":
            text += "\n"
        return text, i

    # Folded block (rare): `>` — treat like literal for our purposes
    if rest in (">", ">-", ">+"):
        # Same handling as literal — we don't actually fold whitespace
        return _parse_field_value(lines, start, key, "|")

    # Block list (no inline value, next lines `      - ...`)
    if rest == "":
        # Peek at next non-blank line
        peek = i
        while peek < n and lines[peek].strip() == "":
            peek += 1
        if peek < n and re.match(r"^      - ", lines[peek]):
            # Block-style list
            items_out: list[str] = []
            buf: list[str] = []
            while i < n:
                nxt = lines[i]
                m_li = re.match(r"^      - (.*)$", nxt)
                if m_li:
                    if buf:
                        items_out.append(" ".join(buf))
                        buf = []
                    buf.append(m_li.group(1))
                    i += 1
                    continue
                if nxt.startswith("        "):
                    # Continuation of the previous list item
                    buf.append(nxt.strip())
                    i += 1
                    continue
                if nxt.strip() == "":
                    i += 1
                    continue
                # Anything else ends the list
                break
            if buf:
                items_out.append(" ".join(buf))
            return items_out, i
        # Empty value
        return "", i

    # Plain scalar — possibly with continuations indented `^      `
    buf = [rest]
    while i < n:
        nxt = lines[i]
        if nxt.startswith("      ") and not re.match(r"^      - ", nxt):
            buf.append(nxt.strip())
            i += 1
            continue
        break
    return _strip_quotes(" ".join(buf)), i


# ---------------------------------------------------------------------------
# Type classification
# ---------------------------------------------------------------------------

def classify_type(item: Item) -> str:
    iid = item.id.lower()
    title = (item.get("title") or "").lower()
    affects = item.get("affects") or []
    if not isinstance(affects, list):
        affects = []
    affects_set = {str(a).lower() for a in affects}

    # Phase T → security (highest priority; covers everything in security floor)
    if iid.startswith("phase-t"):
        return "security"

    # Cleanup signal — take priority over phase
    if iid.startswith("cleanup-"):
        return "cleanup"
    if any(w in title for w in ["cleanup", "refactor", "dead code", "debug-print", "stale "]):
        return "cleanup"

    # Website-rebuild items: tooling/harness → infra; everything else → docs
    if "website-rebuild" in iid or "website-" in iid:
        if any(w in iid for w in ["a11y-tooling", "perf-tooling", "build-harness", "tooling", "harness"]):
            return "infra"
        return "docs"

    # Bug signal — test infra / runtime crashes
    bug_words = ["sigtrap", "deadlock", "deinit", "regression", "race",
                 "uaf", "use-after-free", "fsevents-uaf"]
    if any(w in iid for w in bug_words) or any(w in title for w in bug_words):
        return "bug"
    if iid.startswith("bisect-"):
        return "bug"
    if iid.startswith("harness-") or iid.startswith("test-harness-"):
        return "bug"

    # Performance
    if any(w in title for w in ["perf gate", "perf check", "memory pressure", "throttle"]):
        return "performance"
    if any(w in iid for w in ["perf-tooling", "perf-gate"]):
        return "performance"

    # Security signals beyond Phase T
    if any(w in title for w in ["secret detect", "audit-chain", "sandbox", "vault", "egress proxy"]):
        return "security"
    if "security" in affects_set or "doctor" in affects_set:
        # only when the item is genuinely security-flavored, not generic doctor work
        if any(w in title for w in ["secret", "audit", "sandbox", "credential"]):
            return "security"

    # Infra
    infra_signals = ["build", "distribution", "release", "ci-workflow", "uninstall", "sbom",
                     "grammar-pinning", "packaging", "soak"]
    if any(w in iid for w in infra_signals):
        return "infra"
    if any(w in affects_set for w in ["build", "distribution", "release", "ci"]):
        return "infra"

    # Docs
    if any(w in title for w in ["readme", "changelog", "spec sync", "doc-split", "diataxis",
                                  "glossary", "authorship-cli-backfill"]):
        return "docs"
    if iid.startswith("doctor-grammar-staleness-warning"):
        return "docs"

    # Research
    if any(w in title for w in ["luminary", "review", "evaluation"]):
        if not iid.startswith("phase-"):
            return "research"
    if iid.startswith("luminary-") and "tier-quality" in iid:
        return "research"

    # Phase U/V/W default → feature
    if iid.startswith("phase-"):
        return "feature"

    return "feature"


# ---------------------------------------------------------------------------
# Status normalization
# ---------------------------------------------------------------------------

def extract_shipped_from_notes(item: Item) -> Optional[str]:
    """Best-effort: pull a YYYY-MM-DD from notes when an items: section item
    has status: done but no shipped: field."""
    notes = item.get("notes")
    if not notes:
        return None
    text = str(notes)
    # Prefer markers like "ROUND COMPLETE 2026-04-X" or "✅ shipped 2026-04-X"
    for pat in [
        r"ROUND COMPLETE\s+(\d{4}-\d{2}-\d{2})",
        r"✅\s+shipped\s+(\d{4}-\d{2}-\d{2})",
        r"shipped[:\s]+(\d{4}-\d{2}-\d{2})",
        r"DELIVERED\s+(\d{4}-\d{2}-\d{2})",
        r"LANDED\s+(\d{4}-\d{2}-\d{2})",
        r"Shipped\s+(\d{4}-\d{2}-\d{2})",
    ]:
        m = re.search(pat, text)
        if m:
            return m.group(1)
    return None


def normalize_status(item: Item, all_items_by_id: dict[str, Item]) -> str:
    raw = (item.get("status") or "").strip().lower()
    if raw == "done":
        return "done"
    if raw == "in_progress":
        return "in_progress"
    if raw == "skipped":
        # We collapse all skipped → manual unless the skip note says hardware/external
        return "manual"
    # raw == "" or "pending"
    blockers = item.get("blocked_by") or []
    if not isinstance(blockers, list):
        blockers = []
    if not blockers:
        return "open"
    # Check if all blockers are done
    for blocker_id in blockers:
        blocker = all_items_by_id.get(str(blocker_id).strip())
        if blocker is None:
            # Unknown blocker — treat as blocked
            return "blocked"
        bs = (blocker.get("status") or "").strip().lower()
        if bs != "done":
            return "blocked"
    return "open"


# ---------------------------------------------------------------------------
# Slug + filename
# ---------------------------------------------------------------------------

def slugify(text: str, maxlen: int = 60) -> str:
    s = text.lower()
    s = re.sub(r"[——]", "-", s)  # em dash
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = s.strip("-")
    if len(s) > maxlen:
        s = s[:maxlen].rstrip("-")
    return s or "item"


def _title_slug(item: Item) -> str:
    title = item.get("title") or item.id
    slug_base = re.sub(r"^[A-Z]\.\d+\s*[—\-]\s*", "", title)
    slug_base = re.sub(r"^[Ww]ebsite\s+\d+[a-z]*\s*[—\-]\s*", "website-", slug_base)
    slug_base = re.sub(r"^Cleanup\s+#\d+:\s*", "", slug_base)
    return slugify(slug_base)


def item_filename(item: Item) -> str:
    iid = item.id
    slug = _title_slug(item)
    # Avoid duplication when the id is already a fully-formed slug (e.g. cleanup-1-X)
    # by checking if slug starts with a strong prefix of iid.
    if slug.startswith(iid[:30]) or iid.startswith(slug[:30]):
        return f"{iid}.md"
    return f"{iid}-{slug}.md"


def completed_filename(item: Item) -> str:
    shipped = item.get("shipped")
    shipped = str(shipped).strip() if shipped else None
    iid = item.id
    slug = _title_slug(item)
    base = iid if (slug.startswith(iid[:30]) or iid.startswith(slug[:30])) else f"{iid}-{slug}"
    if shipped and shipped != "0000-00-00":
        return f"{shipped}-{base}.md"
    return f"{base}.md"


# ---------------------------------------------------------------------------
# Per-item file emission
# ---------------------------------------------------------------------------

YAML_RESERVED = re.compile(r"^[\s\-{}\[\]:,\?!&\*\|>'\"%@`]")


def _yaml_scalar(v) -> str:
    """Emit a scalar safely. Quote if it could be misparsed."""
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    s = str(v)
    if s == "":
        return '""'
    # Quote anything dicey
    if (s.lower() in {"yes", "no", "true", "false", "null", "~"}
            or YAML_RESERVED.match(s)
            or ":" in s
            or "#" in s
            or s != s.strip()):
        # Use double-quotes; escape internal " and \
        escaped = s.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return s


def _yaml_inline_list(items) -> str:
    if not items:
        return "[]"
    parts = [_yaml_scalar(x) for x in items]
    return "[" + ", ".join(parts) + "]"


def _yaml_block(field: str, content: str) -> str:
    """Emit a literal-block field: `field: |` plus indented content."""
    if not content:
        return f"{field}: \"\""
    # Split, indent every line by 2 spaces (inside frontmatter, normal block)
    lines = content.rstrip("\n").split("\n")
    indented = "\n".join(("  " + ln if ln else "") for ln in lines)
    return f"{field}: |\n{indented}"


def render_item_markdown(item: Item, normalized_status: str, classified_type: str,
                         phase: Optional[str]) -> str:
    """Render the per-item markdown file body."""
    f = item.fields

    # Frontmatter — required + optional fields
    fm_lines: list[str] = ["---"]
    fm_lines.append(f"id: {_yaml_scalar(item.id)}")
    fm_lines.append(f"title: {_yaml_scalar(f.get('title') or item.id)}")
    fm_lines.append(f"status: {normalized_status}")
    fm_lines.append(f"type: {classified_type}")
    if phase:
        fm_lines.append(f"phase: {phase}")
    if f.get("size"):
        fm_lines.append(f"size: {_yaml_scalar(f['size'])}")
    if f.get("priority"):
        fm_lines.append(f"priority: {_yaml_scalar(f['priority'])}")
    if f.get("roster"):
        fm_lines.append(f"roster: {_yaml_inline_list(f['roster'])}")
    if f.get("affects"):
        fm_lines.append(f"affects: {_yaml_inline_list(f['affects'])}")
    if f.get("blocked_by"):
        fm_lines.append(f"blocked_by: {_yaml_inline_list(f['blocked_by'])}")
    if f.get("blocked_reason") and normalized_status in ("blocked", "manual"):
        fm_lines.append(_yaml_block("blocked_reason", str(f["blocked_reason"])))
    if f.get("tests_target") not in (None, ""):
        fm_lines.append(f"tests_target: {_yaml_scalar(f['tests_target'])}")
    if f.get("created"):
        fm_lines.append(f"created: {_yaml_scalar(f['created'])}")
    if f.get("last_touched"):
        fm_lines.append(f"last_touched: {_yaml_scalar(f['last_touched'])}")
    if f.get("source_inspirations"):
        fm_lines.append(f"source_inspirations: {_yaml_inline_list(f['source_inspirations'])}")

    # Closed-only fields
    if f.get("shipped"):
        fm_lines.append(f"shipped: {_yaml_scalar(f['shipped'])}")
    if f.get("tests_delta") not in (None, ""):
        fm_lines.append(_yaml_block("tests_delta", str(f["tests_delta"])))
    if f.get("docs_synced"):
        fm_lines.append(f"docs_synced: {_yaml_inline_list(f['docs_synced'])}")
    fm_lines.append("---")

    body_lines: list[str] = []
    title = f.get("title") or item.id
    body_lines.append("")
    body_lines.append(f"# {title}")
    body_lines.append("")
    body_lines.append("[Backlog index](../index.md) · [Router](../../autonomous.md) · [Process](../PROCESS.md)")
    body_lines.append("")

    if f.get("scope"):
        body_lines.append("## Scope")
        body_lines.append("")
        body_lines.append(_render_block_value(f["scope"]))
        body_lines.append("")

    if f.get("acceptance"):
        body_lines.append("## Acceptance")
        body_lines.append("")
        body_lines.append(_render_block_value(f["acceptance"], force_list=True))
        body_lines.append("")

    if f.get("notes"):
        body_lines.append("## Notes")
        body_lines.append("")
        body_lines.append(_render_block_value(f["notes"]))
        body_lines.append("")

    if f.get("summary"):
        body_lines.append("## Summary")
        body_lines.append("")
        body_lines.append(_render_block_value(f["summary"]))
        body_lines.append("")

    if f.get("accepted_risks"):
        body_lines.append("## Accepted Risks")
        body_lines.append("")
        body_lines.append(_render_block_value(f["accepted_risks"]))
        body_lines.append("")

    return "\n".join(fm_lines) + "\n" + "\n".join(body_lines).rstrip("\n") + "\n"


def _render_block_value(v, force_list: bool = False) -> str:
    if isinstance(v, list):
        return "\n".join(f"- {x}" for x in v)
    s = str(v)
    return s.rstrip("\n")


# ---------------------------------------------------------------------------
# Index emission
# ---------------------------------------------------------------------------

def emit_backlog_index(items_by_status: dict[str, list], out_path: Path) -> None:
    lines: list[str] = []
    lines.append("# Backlog")
    lines.append("")
    lines.append("> Generated from per-item frontmatter. Do not hand-edit — regenerated on every round close.")
    lines.append("")
    lines.append(f"_Last regenerated: {datetime.utcnow().strftime('%Y-%m-%d')}_")
    lines.append("")

    def render_section(label: str, key: str, with_blocked: bool = False, with_reason: bool = False):
        bucket = items_by_status.get(key, [])
        lines.append(f"## {label}")
        lines.append("")
        if not bucket:
            lines.append(f"_No {label.lower()}._")
            lines.append("")
            return
        for entry in bucket:
            iid = entry["id"]
            typ = entry["type"]
            title = entry["title"]
            fname = entry["filename"]
            row = f"- `[{iid}]` `[{typ}]` [{title}]({fname})"
            if with_blocked:
                bb = entry.get("blocked_by") or []
                if bb:
                    row += f" — blocked-by `{', '.join(bb)}`"
            if with_reason:
                br = entry.get("blocked_reason") or ""
                br = br.strip().split("\n")[0] if br else ""
                if br:
                    row += f" — {br}"
            lines.append(row)
        lines.append("")

    render_section("Open Items", "open")
    render_section("Blocked Items", "blocked", with_blocked=True, with_reason=True)
    render_section("Manual Items", "manual", with_reason=True)
    render_section("In-Progress", "in_progress")

    out_path.write_text("\n".join(lines))


def emit_completed_index(completed_records: list[dict], out_path: Path) -> None:
    lines: list[str] = []
    lines.append("# Completed")
    lines.append("")
    lines.append("> Generated from per-item frontmatter. Sorted by `shipped` date, newest first.")
    lines.append("")
    lines.append(f"_Last regenerated: {datetime.utcnow().strftime('%Y-%m-%d')}_")
    lines.append(f"_Total items: {len(completed_records)}_")
    lines.append("")

    by_year: dict[str, list[dict]] = defaultdict(list)
    for rec in completed_records:
        shipped = rec.get("shipped")
        year = str(shipped)[:4] if shipped else "undated"
        by_year[year].append(rec)

    # Render dated years first (newest first), then "undated" at the bottom.
    dated_years = sorted([y for y in by_year if y != "undated"], reverse=True)
    ordered_years = dated_years + (["undated"] if "undated" in by_year else [])
    for year in ordered_years:
        heading = year if year != "undated" else "Undated (pre-shipped-date convention)"
        lines.append(f"## {heading}")
        lines.append("")
        rows = sorted(by_year[year], key=lambda r: r.get("shipped") or r["id"], reverse=True)
        for entry in rows:
            shipped = entry.get("shipped") or "—"
            iid = entry["id"]
            typ = entry["type"]
            title = entry["title"]
            fname = entry["rel_path"]
            row = f"- `{shipped}` `[{iid}]` `[{typ}]` [{title}]({fname})"
            lines.append(row)
        lines.append("")

    out_path.write_text("\n".join(lines))


# ---------------------------------------------------------------------------
# Roadmap + cleanup parsers
# ---------------------------------------------------------------------------

def parse_roadmap(path: Path) -> dict:
    """Parse roadmap.md into:
      - phases:   {phase_letter: {intro_lines, legs: [{label, lines}]}}
      - strategy: {section_heading: lines}
      - global_intro: lines before first ## heading
    """
    if not path.exists():
        return {"phases": {}, "strategy": {}, "global_intro": []}
    lines = path.read_text().split("\n")
    out = {"phases": {}, "strategy": {}, "global_intro": []}
    section_kind = None  # "phase" | "strategy" | None
    cur_phase: Optional[str] = None
    cur_phase_intro: list[str] = []
    cur_legs: list[dict] = []
    cur_leg_label: Optional[str] = None
    cur_leg_lines: list[str] = []
    cur_strategy_heading: Optional[str] = None
    cur_strategy_lines: list[str] = []

    def close_leg():
        nonlocal cur_leg_label, cur_leg_lines
        if cur_leg_label is not None:
            cur_legs.append({"label": cur_leg_label, "lines": cur_leg_lines[:]})
            cur_leg_label = None
            cur_leg_lines = []

    def close_phase():
        nonlocal cur_phase, cur_phase_intro, cur_legs
        close_leg()
        if cur_phase is not None:
            out["phases"][cur_phase] = {
                "intro_lines": cur_phase_intro[:],
                "legs": cur_legs[:],
            }
        cur_phase = None
        cur_phase_intro = []
        cur_legs = []

    def close_strategy():
        nonlocal cur_strategy_heading, cur_strategy_lines
        if cur_strategy_heading is not None:
            out["strategy"][cur_strategy_heading] = cur_strategy_lines[:]
        cur_strategy_heading = None
        cur_strategy_lines = []

    for ln in lines:
        # Phase header: "## Phase T — Security Floor" (or similar)
        mph = re.match(r"^##\s+Phase\s+([TUVW])\s*[—–-]\s*(.+)$", ln)
        if mph:
            close_phase()
            close_strategy()
            cur_phase = mph.group(1)
            section_kind = "phase"
            continue
        # Phase leg: "### T.1 — EgressProxy daemon"
        mleg = re.match(r"^###\s+([TUVW]\.\d+[a-z]?)\s*[—–-]\s*(.+)$", ln)
        if mleg and section_kind == "phase":
            close_leg()
            cur_leg_label = mleg.group(1)
            cur_leg_lines = [ln]
            continue
        # Other ## section heading (strategy / status / why etc.)
        mh2 = re.match(r"^##\s+(.+)$", ln)
        if mh2 and not mph:
            close_phase()
            close_strategy()
            cur_strategy_heading = mh2.group(1).strip()
            cur_strategy_lines = [ln]
            section_kind = "strategy"
            continue
        # Buffer the line
        if section_kind == "phase":
            if cur_leg_label is not None:
                cur_leg_lines.append(ln)
            elif cur_phase is not None:
                cur_phase_intro.append(ln)
        elif section_kind == "strategy":
            cur_strategy_lines.append(ln)
        else:
            out["global_intro"].append(ln)

    close_phase()
    close_strategy()
    return out


def parse_cleanup(path: Path) -> dict:
    """Parse cleanup.md into a dict {entry_number: {title, lines, status, shipped}}.

    Each `### N. Title` is one entry. Status is `open|done|partial`.
    """
    if not path.exists():
        return {"entries": {}, "intro": [], "extra_sections": {}}
    lines = path.read_text().split("\n")
    intro: list[str] = []
    entries: dict[str, dict] = {}
    extra_sections: dict[str, list[str]] = {}

    cur_id: Optional[str] = None
    cur_lines: list[str] = []
    cur_extra: Optional[str] = None
    cur_extra_lines: list[str] = []

    def close_entry():
        nonlocal cur_id, cur_lines
        if cur_id is not None:
            text_blob = "\n".join(cur_lines)
            status, shipped = _detect_cleanup_status(text_blob)
            title_line = cur_lines[0] if cur_lines else f"### {cur_id}."
            mt = re.match(r"^###\s+(\d+)\.\s+(.+?)\s*$", title_line)
            title = mt.group(2) if mt else cur_id
            entries[cur_id] = {
                "title": title,
                "lines": cur_lines[:],
                "status": status,
                "shipped": shipped,
            }
        cur_id = None
        cur_lines = []

    def close_extra():
        nonlocal cur_extra, cur_extra_lines
        if cur_extra is not None:
            extra_sections[cur_extra] = cur_extra_lines[:]
        cur_extra = None
        cur_extra_lines = []

    for ln in lines:
        m = re.match(r"^###\s+(\d+)\.\s+(.+?)\s*$", ln)
        if m:
            close_entry()
            close_extra()
            cur_id = m.group(1)
            cur_lines = [ln]
            continue
        # Extra (non-numbered) ### section — keep
        m_extra = re.match(r"^###\s+(?!\d)(.+?)\s*$", ln)
        if m_extra:
            close_entry()
            close_extra()
            cur_extra = m_extra.group(1).strip()
            cur_extra_lines = [ln]
            continue
        # ## section change (e.g., "## Fix Now")
        m_h2 = re.match(r"^##\s+(.+)$", ln)
        if m_h2:
            close_entry()
            close_extra()
        if cur_id is not None:
            cur_lines.append(ln)
        elif cur_extra is not None:
            cur_extra_lines.append(ln)
        else:
            intro.append(ln)
    close_entry()
    close_extra()
    return {"entries": entries, "intro": intro, "extra_sections": extra_sections}


_MONTHS = {
    "january": "01", "february": "02", "march": "03", "april": "04",
    "may": "05", "june": "06", "july": "07", "august": "08",
    "september": "09", "october": "10", "november": "11", "december": "12",
}


def _detect_cleanup_status(text: str) -> tuple[str, Optional[str]]:
    # PARTIALLY first (its substring is "RESOLVED" which would match the next regex)
    m = re.search(r"PARTIALLY\s+RESOLVED\s+(\d{4}-\d{2}-\d{2})", text)
    if m:
        return "partial", m.group(1)
    # ISO-dated RESOLVED in heading or body
    m = re.search(r"\*\*RESOLVED\s+(\d{4}-\d{2}-\d{2})\*\*", text)
    if m:
        return "done", m.group(1)
    m = re.search(r"RESOLVED\s+(\d{4}-\d{2}-\d{2})", text)
    if m:
        return "done", m.group(1)
    # Body-level "Resolved <Month> <Day>" — infer 2026 (project year)
    m = re.search(r"Resolved\s+(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2})", text)
    if m:
        month = _MONTHS[m.group(1).lower()]
        day = m.group(2).zfill(2)
        return "done", f"2026-{month}-{day}"
    return "open", None


# ---------------------------------------------------------------------------
# Main migration
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("spec_dir", nargs="?", default="/Users/clank/Desktop/projects/senkani/spec",
                    help="Path to the spec/ directory to migrate.")
    ap.add_argument("--force", action="store_true", help="Allow overwriting existing spec/autonomous/.")
    args = ap.parse_args()

    spec_dir = Path(args.spec_dir).resolve()
    backlog_path = spec_dir / "autonomous-backlog.yaml"
    roadmap_path = spec_dir / "roadmap.md"
    cleanup_path = spec_dir / "cleanup.md"
    out_dir = spec_dir / "autonomous"

    if not backlog_path.exists():
        print(f"FATAL: {backlog_path} does not exist", file=sys.stderr)
        return 2

    print(f"[migrate] reading {backlog_path}")
    in_flight, items, completed = parse_backlog(backlog_path)
    print(f"[migrate] parsed: in_flight={in_flight} items={len(items)} completed={len(completed)}")

    if in_flight:
        print(f"FATAL: in_flight is non-null ({in_flight!r}). Land or skip the round before migrating.",
              file=sys.stderr)
        return 3

    # Build all-items map for blocker resolution
    all_items_by_id: dict[str, Item] = {}
    for it in items + completed:
        if it.id:
            all_items_by_id[it.id] = it

    # Read roadmap + cleanup
    roadmap = parse_roadmap(roadmap_path)
    cleanup = parse_cleanup(cleanup_path)
    print(f"[migrate] roadmap phases: {sorted(roadmap['phases'].keys())} | "
          f"strategy sections: {len(roadmap['strategy'])} | "
          f"cleanup entries: {len(cleanup['entries'])}")

    # Output dirs
    if out_dir.exists() and not args.force:
        # Check if it's empty-ish (only PROCESS.md/_template.md/autonomous.md)
        existing = [p.name for p in out_dir.iterdir() if not p.name.startswith(".")]
        unexpected = [p for p in existing if p not in {"PROCESS.md", "_template.md"}]
        if unexpected:
            print(f"FATAL: {out_dir} already contains: {unexpected}. Use --force to overwrite.",
                  file=sys.stderr)
            return 4

    backlog_dir = out_dir / "backlog"
    completed_dir = out_dir / "completed"
    phases_dir = out_dir / "phases"
    backlog_dir.mkdir(parents=True, exist_ok=True)
    completed_dir.mkdir(parents=True, exist_ok=True)
    phases_dir.mkdir(parents=True, exist_ok=True)

    # Emit per-item files
    open_records: list[dict] = []
    blocked_records: list[dict] = []
    manual_records: list[dict] = []
    in_progress_records: list[dict] = []
    completed_records: list[dict] = []
    type_counts: dict[str, int] = defaultdict(int)
    cleanup_merged_into: dict[str, str] = {}  # cleanup_N -> backlog item id

    # Pre-pass: figure out which cleanup entries are referenced by backlog items
    for it in items + completed:
        title = (it.get("title") or "")
        notes = (it.get("notes") or "")
        for m in re.finditer(r"cleanup\.md\s*#(\d+)", title + " " + str(notes), flags=re.IGNORECASE):
            cleanup_merged_into.setdefault(m.group(1), it.id)

    # Pass 1: emit items: section
    for it in items:
        norm_status = normalize_status(it, all_items_by_id)
        ctype = classify_type(it)
        type_counts[ctype] += 1

        # Phase derivation from id
        phase = None
        m = re.match(r"^phase-([tuvw])\d", it.id, re.IGNORECASE)
        if m:
            phase = m.group(1).upper()

        # Merge cleanup body if referenced
        merged_cleanup = []
        for n, bid in cleanup_merged_into.items():
            if bid == it.id and n in cleanup["entries"]:
                merged_cleanup.append((n, cleanup["entries"][n]))
        if merged_cleanup:
            extra_notes = []
            for n, ce in merged_cleanup:
                # Preserve original heading verbatim (after the line that
                # explicitly flags this as migrated content) so the
                # round-trip heading-coverage check finds it.
                extra_notes.append(f"\n\n### Migrated from cleanup.md #{n}\n\n")
                extra_notes.append("\n".join(ce["lines"]))
            existing_notes = it.get("notes") or ""
            it.fields["notes"] = existing_notes + "".join(extra_notes)
            existing_legacy = it.get("legacy_ref")
            ref_str = ", ".join(f"cleanup.md#{n}" for n, _ in merged_cleanup)
            it.fields["legacy_ref"] = ref_str if not existing_legacy else f"{existing_legacy}, {ref_str}"

        rec_target = None
        if norm_status == "done":
            # Item with status: done in items: section — moves to completed/
            rec_target = "completed"
        elif norm_status == "in_progress":
            rec_target = "in_progress"
        elif norm_status == "open":
            rec_target = "open"
        elif norm_status == "blocked":
            rec_target = "blocked"
        elif norm_status == "manual":
            rec_target = "manual"

        if rec_target == "completed":
            # Backfill shipped date from notes if missing
            if not it.get("shipped"):
                inferred = extract_shipped_from_notes(it)
                if inferred:
                    it.fields["shipped"] = inferred
            shipped = it.get("shipped")
            md = render_item_markdown(it, "done", ctype, phase)
            if shipped:
                year = str(shipped)[:4]
            else:
                year = "undated"
            (completed_dir / year).mkdir(exist_ok=True)
            fname = completed_filename(it)
            out_path = completed_dir / year / fname
            out_path.write_text(md)
            completed_records.append({
                "id": it.id, "type": ctype, "title": it.get("title") or it.id,
                "shipped": shipped,
                "rel_path": f"{year}/{fname}",
            })
            continue

        md = render_item_markdown(it, norm_status, ctype, phase)
        fname = item_filename(it)
        (backlog_dir / fname).write_text(md)
        rec = {
            "id": it.id, "type": ctype, "title": it.get("title") or it.id,
            "filename": fname,
            "blocked_by": it.get("blocked_by") or [],
            "blocked_reason": it.get("blocked_reason") or "",
        }
        if norm_status == "open":
            open_records.append(rec)
        elif norm_status == "blocked":
            blocked_records.append(rec)
        elif norm_status == "manual":
            manual_records.append(rec)
        elif norm_status == "in_progress":
            in_progress_records.append(rec)

    # Pass 2: emit completed: section
    for it in completed:
        ctype = classify_type(it)
        type_counts[ctype] += 1
        phase = None
        m = re.match(r"^phase-([tuvw])\d", it.id, re.IGNORECASE)
        if m:
            phase = m.group(1).upper()
        # Merge cleanup body if referenced (same as items: pass)
        merged_cleanup = []
        for n, bid in cleanup_merged_into.items():
            if bid == it.id and n in cleanup["entries"]:
                merged_cleanup.append((n, cleanup["entries"][n]))
        if merged_cleanup:
            extra_notes = []
            for n, ce in merged_cleanup:
                extra_notes.append(f"\n\n### Migrated from cleanup.md #{n}\n\n")
                extra_notes.append("\n".join(ce["lines"]))
            existing_notes = it.get("notes") or ""
            it.fields["notes"] = existing_notes + "".join(extra_notes)
            existing_legacy = it.get("legacy_ref")
            ref_str = ", ".join(f"cleanup.md#{n}" for n, _ in merged_cleanup)
            it.fields["legacy_ref"] = ref_str if not existing_legacy else f"{existing_legacy}, {ref_str}"

        if not it.get("shipped"):
            inferred = extract_shipped_from_notes(it)
            if inferred:
                it.fields["shipped"] = inferred
        shipped = it.get("shipped")
        md = render_item_markdown(it, "done", ctype, phase)
        year = str(shipped)[:4] if shipped else "undated"
        (completed_dir / year).mkdir(exist_ok=True)
        fname = completed_filename(it)
        out_path = completed_dir / year / fname
        out_path.write_text(md)
        completed_records.append({
            "id": it.id, "type": ctype, "title": it.get("title") or it.id,
            "shipped": shipped,
            "rel_path": f"{year}/{fname}",
        })

    # Pass 3: emit cleanup-only entries (those NOT merged into a backlog item)
    cleanup_emitted = 0
    for n, ce in cleanup["entries"].items():
        if n in cleanup_merged_into:
            continue
        # Synthesize an Item shape
        c_item = Item()
        c_item.fields["id"] = f"cleanup-{n}-{slugify(ce['title'])[:40]}"
        c_item.fields["title"] = f"Cleanup #{n}: {ce['title']}"
        c_item.fields["status"] = "done" if ce["status"] == "done" else "skipped" if ce["status"] == "partial" else ""
        c_item.fields["affects"] = ["cleanup"]
        c_item.fields["legacy_ref"] = f"cleanup.md#{n}"
        if ce["shipped"]:
            c_item.fields["shipped"] = ce["shipped"]
        # Body becomes notes
        notes_body = "\n".join(ce["lines"][1:])
        c_item.fields["notes"] = notes_body

        if ce["status"] == "done":
            norm = "done"
        elif ce["status"] == "partial":
            norm = "open"
            c_item.fields["notes"] = (
                "**Status: partially resolved as of "
                f"{ce['shipped']}** — see migrated body below.\n\n" + notes_body
            )
        else:
            norm = "open"

        ctype = "cleanup"
        type_counts[ctype] += 1
        md = render_item_markdown(c_item, norm, ctype, None)
        if norm == "done":
            year = (ce["shipped"] or "0000")[:4]
            (completed_dir / year).mkdir(exist_ok=True)
            fname = completed_filename(c_item)
            (completed_dir / year / fname).write_text(md)
            completed_records.append({
                "id": c_item.id, "type": ctype, "title": c_item.get("title"),
                "shipped": c_item.get("shipped"),
                "rel_path": f"{year}/{fname}",
            })
        else:
            fname = item_filename(c_item)
            (backlog_dir / fname).write_text(md)
            rec = {"id": c_item.id, "type": ctype, "title": c_item.get("title"),
                   "filename": fname, "blocked_by": [], "blocked_reason": ""}
            open_records.append(rec)
        cleanup_emitted += 1

    # Pass 4: emit phase files
    for phase_letter, phase_data in roadmap["phases"].items():
        emit_phase_file(phase_letter, phase_data, phases_dir)

    # Pass 5: emit strategy.md
    emit_strategy_file(roadmap["strategy"], roadmap.get("global_intro", []),
                       cleanup["intro"], cleanup["extra_sections"], out_dir / "strategy.md")

    # Pass 6: indexes
    items_by_status = {
        "open": sorted(open_records, key=lambda r: r["id"]),
        "blocked": sorted(blocked_records, key=lambda r: r["id"]),
        "manual": sorted(manual_records, key=lambda r: r["id"]),
        "in_progress": sorted(in_progress_records, key=lambda r: r["id"]),
    }
    emit_backlog_index(items_by_status, backlog_dir / "index.md")
    emit_completed_index(completed_records, completed_dir / "index.md")

    # Pass 7: _state.yaml
    state_text = (
        "# Live state for /senkani-autonomous. Hand-edit ONLY when no round is running.\n"
        "schema_version: 2\n"
        "in_flight: null\n"
    )
    (out_dir / "_state.yaml").write_text(state_text)

    # Summary
    print()
    print(f"[migrate] DONE — output at {out_dir}")
    print(f"  open:         {len(open_records)}")
    print(f"  blocked:      {len(blocked_records)}")
    print(f"  manual:       {len(manual_records)}")
    print(f"  in_progress:  {len(in_progress_records)}")
    print(f"  completed:    {len(completed_records)}")
    print(f"  cleanup-only items emitted: {cleanup_emitted}")
    print(f"  cleanup merged into backlog items: {len(cleanup_merged_into)}")
    print(f"  type breakdown: {dict(type_counts)}")
    print(f"  phases written: {sorted(roadmap['phases'].keys())}")
    return 0


def emit_phase_file(letter: str, phase_data: dict, phases_dir: Path) -> None:
    """Emit spec/autonomous/phases/<letter>-<name>.md."""
    intro_lines = phase_data["intro_lines"]
    legs = phase_data["legs"]
    # Try to find a phase name from the first non-blank intro line or default
    name_map = {
        "T": "security-floor",
        "U": "routing-validation",
        "V": "operator-surface",
        "W": "web-extraction",
    }
    fname = f"{letter}-{name_map.get(letter, 'phase')}.md"
    out: list[str] = []
    out.append(f"# Phase {letter}")
    out.append("")
    out.append("[Router](../../autonomous.md) · [Process](../PROCESS.md) · [Backlog](../backlog/index.md)")
    out.append("")
    out.append("## Phase narrative")
    out.append("")
    out.extend(intro_lines)
    out.append("")
    out.append("## Legs")
    out.append("")
    for leg in legs:
        out.extend(leg["lines"])
        out.append("")
    (phases_dir / fname).write_text("\n".join(out))


def emit_strategy_file(strategy_sections: dict, global_intro: list[str],
                       cleanup_intro: list[str], cleanup_extra: dict, out_path: Path) -> None:
    out: list[str] = []
    out.append("# Strategy")
    out.append("")
    out.append("Migrated from the legacy `spec/roadmap.md` and `spec/cleanup.md`. Per-leg "
               "phase narrative lives under `spec/autonomous/phases/`. Per-item work lives "
               "under `spec/autonomous/backlog/` and `spec/autonomous/completed/`.")
    out.append("")
    if global_intro:
        out.append("## Roadmap intro (legacy)")
        out.append("")
        out.extend([ln for ln in global_intro if ln.strip()])
        out.append("")
    for heading, lines in strategy_sections.items():
        out.extend(lines)
        out.append("")
    if cleanup_intro and any(ln.strip() for ln in cleanup_intro):
        out.append("## Cleanup intro (legacy)")
        out.append("")
        out.extend([ln for ln in cleanup_intro if ln.strip()])
        out.append("")
    for heading, lines in cleanup_extra.items():
        out.append(f"## Cleanup: {heading}")
        out.append("")
        out.extend(lines[1:])  # drop the heading itself, we re-emit
        out.append("")
    out_path.write_text("\n".join(out))


if __name__ == "__main__":
    sys.exit(main())
