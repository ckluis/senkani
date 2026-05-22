#!/usr/bin/env python3
"""
Single-write helper for per-item frontmatter keys.

The /senkani-autonomous close phases (build, groom, scope-groom) and the
abort+split flow all need to set `tests_delta:` / `docs_synced:` /
`shipped:` / `groomed:` / etc. on a per-item file's frontmatter.
The skill prose previously instructed "Add <key>: ..." which, when a
prior round already wrote the key (e.g. scope-groom defaults left at
the bottom of the frontmatter block), produced a DUPLICATE entry.
PyYAML and most loaders silently apply last-key-wins on duplicates,
which masks the load-bearing declaration written by the latest round.

This helper writes the key with **single-write semantic**:
- If the key is absent → append it before the closing `---`.
- If the key is present exactly once → replace its value in-place.
- If the key appears multiple times → keep the FIRST occurrence,
  replace its value with the new value, and DELETE any additional
  occurrences. This dedupes existing dupes at write time.

The value argument is written verbatim AFTER `<key>: `. The caller is
responsible for quoting/escaping (e.g. JSON-style list literals,
quoted strings). For a list-of-strings convenience helper, see
`--list` below.

Usage:
    python3 tools/autonomous/set_frontmatter_key.py <file> <key> <value>
    python3 tools/autonomous/set_frontmatter_key.py <file> <key> --list a b c
    python3 tools/autonomous/set_frontmatter_key.py <file> <key> --empty-list
    python3 tools/autonomous/set_frontmatter_key.py <file> <key> --delete

Exit codes:
    0 — file written (or unchanged if --check finds key already at desired value)
    1 — file has no frontmatter block (bare `---\\n` not at start, no closing `---`)
    2 — argument error
"""
from __future__ import annotations
import argparse
import re
import sys
from pathlib import Path

# `[a-z_]+` matches every key the autonomous loop writes today
# (tests_delta, docs_synced, status, shipped, groomed, groomed_by,
# scope_groomed, scope_groomed_by, decomposed, decomposed_by,
# decomposable, last_touched, blocked_by, blocked_reason,
# parent_finding, findings_filed, split_into, tests_target, type,
# size, priority, phase, etc.). The validator in roundtrip.py uses
# the same regex.
_KEY_RE = re.compile(r"^([a-z_]+):\s*(.*)$")


def _split_frontmatter(text: str) -> tuple[str, list[str], str] | None:
    """Split `text` into (prefix, frontmatter_lines, suffix).

    `prefix` is everything up to and including the opening `---\\n`.
    `frontmatter_lines` is the list of lines between the opening and
    closing `---` (no trailing newline on each line).
    `suffix` is everything from the closing `---\\n` onward.

    Returns None if the text lacks a well-formed frontmatter block.
    """
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 4)
    if end < 0:
        return None
    fm_text = text[4:end]
    suffix = text[end + 1:]  # starts at "---\n..."
    return ("---\n", fm_text.split("\n"), suffix)


def set_key(text: str, key: str, value: str) -> str:
    """Return `text` with `key: value` written under the single-write
    semantic (see module docstring)."""
    parts = _split_frontmatter(text)
    if parts is None:
        raise ValueError("file has no well-formed frontmatter block")
    prefix, fm_lines, suffix = parts

    new_line = f"{key}: {value}"
    first_idx = -1
    keep_lines: list[str] = []
    for line in fm_lines:
        m = _KEY_RE.match(line)
        if m and m.group(1) == key:
            if first_idx < 0:
                first_idx = len(keep_lines)
                keep_lines.append(new_line)
            # else: drop the duplicate
            continue
        keep_lines.append(line)
    if first_idx < 0:
        # Key absent — append before suffix.
        keep_lines.append(new_line)
    return prefix + "\n".join(keep_lines) + "\n" + suffix


def delete_key(text: str, key: str) -> str:
    """Return `text` with every occurrence of `key:` removed from
    frontmatter."""
    parts = _split_frontmatter(text)
    if parts is None:
        raise ValueError("file has no well-formed frontmatter block")
    prefix, fm_lines, suffix = parts
    keep_lines = []
    for line in fm_lines:
        m = _KEY_RE.match(line)
        if m and m.group(1) == key:
            continue
        keep_lines.append(line)
    return prefix + "\n".join(keep_lines) + "\n" + suffix


def _format_list(values: list[str]) -> str:
    """Format a list of plain identifiers as a YAML inline list. The
    autonomous loop uses inline-list form for short string lists
    (docs_synced, blocked_by, affects, etc.)."""
    return "[" + ", ".join(values) + "]"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("file", type=Path)
    ap.add_argument("key")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("value", nargs="?", help="raw YAML value to write")
    g.add_argument("--list", dest="list_values", nargs="+", help="format args as inline YAML list")
    g.add_argument("--empty-list", action="store_true", help="write `[]`")
    g.add_argument("--delete", action="store_true", help="remove every occurrence of the key")
    args = ap.parse_args(argv)

    if not re.fullmatch(r"[a-z_]+", args.key):
        print(f"error: key must match [a-z_]+: {args.key!r}", file=sys.stderr)
        return 2

    text = args.file.read_text()

    try:
        if args.delete:
            new_text = delete_key(text, args.key)
        else:
            if args.empty_list:
                value = "[]"
            elif args.list_values is not None:
                value = _format_list(args.list_values)
            else:
                value = args.value
            new_text = set_key(text, args.key, value)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if new_text != text:
        args.file.write_text(new_text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
