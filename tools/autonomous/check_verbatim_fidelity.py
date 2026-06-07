#!/usr/bin/env python3
"""
check_verbatim_fidelity — assert that a block hand-pasted into a
target file is byte-for-byte the text that was staged for it.

Hand-edit walks (the partial-ship pattern — see
`[[feedback_skill_md_partial_ship_pattern]]`) stage verbatim text
(e.g. a `## Build abort note`'s SKILL.md edit) and ask the operator
to paste it into a target file. Today's groom-template execution
steps verify, for the inserted block:

  - count       — `grep -c <marker>` equals the expected number;
  - placement   — block-scoped `awk` ranges confirm the right section;
  - additivity  — `diff -u` vs a backup shows N hunks, 0 deletions;
  - fingerprint — pre/post sha differ, line delta >= threshold.

NONE of those check that the inserted bytes *match the intended
text*. A paste that drops a list bullet, reflows a long line, or
paraphrases a sentence satisfies all four (count unchanged, still in
the right section, still purely additive vs. backup, sha still
differs) yet ships the wrong content. This was demonstrated live on
`process-gap-pre-audit-cli-protocol-match-check-2026-05-22`: the
first application of build-mode Edit 2 dropped a `status:` flip
bullet and reflowed one line, and PASSED steps 5/6/10/11. The
deviation was caught only because the walker manually ran an
out-of-band byte-exact `diff` of the landed block against the staged
text.

This helper is that out-of-band check, mechanized. Given a staged
verbatim file and an edited target plus start/end markers, it
extracts the landed block (same start-inclusive / end-exclusive rule
as the canonical awk idiom

    awk '/^<start>/{f=1} /^<end>/{f=0} f' <target>

) and compares it line-for-line against the staged text. A walk's
`## Acceptance` adds one row: `helper exits 0` (identical).

Originating item:
`process-gap-operator-hand-edit-verbatim-fidelity-unverified-2026-05-26`.
Parent finding:
`process-gap-pre-audit-cli-protocol-match-check-2026-05-22` operator
hand-edit walk 2026-05-26.

Sibling helper to `check_envelope_size.py` / `check_external_surfaces.py`
— same stdlib-only constraint, JSON-to-stdout, exit-code contract.

Comparison semantics (a deliberate, documented decision):

  Comparison is LINE-EXACT, not raw-byte. Both sides are read and
  split with `str.splitlines()`, which drops line terminators and the
  single trailing newline. This normalizes the one difference the
  extraction mechanism cannot faithfully preserve — whether the block
  ends with a newline — because that is an editor artifact, not a
  content infidelity. EVERY defect class the originating finding names
  is still caught:
    - dropped line   -> line-count mismatch;
    - reflowed line  -> line boundaries move -> count and/or content
                        mismatch;
    - paraphrase     -> same count, differing line content;
    - whitespace-within-line / CRLF-vs-LF inside a line -> content
                        mismatch (splitlines splits on \\r\\n too, but a
                        line whose interior whitespace changed still
                        differs).
  An *internal* blank line (a content-bearing empty line) is preserved
  as an empty element and therefore still compared; only the single
  final terminator is normalized. If a walk needs raw-byte equality
  (rare), the shell fallback `diff <staged> <(awk ... <target>)`
  remains available.

Usage:
    python3 tools/autonomous/check_verbatim_fidelity.py \\
        --staged /tmp/edit-verbatim.txt \\
        --target ~/.claude/skills/senkani-autonomous/SKILL.md \\
        --start-marker '^5\\.7\\. \\*\\*External-surfaces check\\.\\*\\*' \\
        --end-marker '^6\\. \\*\\*Run the interview\\*\\*'

Markers are Python regular expressions, matched with `re.search`
(anchor them yourself with `^`/`$` as the awk idiom does). The
start-marker line is INCLUDED in the extracted block; the end-marker
line is EXCLUDED (pass --include-end-marker to include it). If no
--end-marker is given, the block runs from the start marker to EOF.

Output (stdout): JSON record with:
    {
      "staged": "<path>",
      "target": "<path>",
      "start_marker": "<re>",
      "end_marker": "<re or null>",
      "include_end_marker": false,
      "block_found": <bool>,
      "start_match_count": <int>,
      "end_marker_found": <bool or null>,
      "identical": <bool>,
      "should_fire": <bool>,          # alias: == not identical
      "staged_line_count": <int>,
      "landed_line_count": <int or null>,
      "first_diff_line": <int or null>,   # 1-based, null when identical
      "reasons": [{"kind": "...", "detail": "..."}],
      "diff": "<unified diff string, empty when identical>"
    }

`should_fire` is the sibling-shape alias (true == a problem was
found). `identical` is the primary, plain-language field.

Exit codes:
    0 — identical (the landed block matches the staged text verbatim)
    1 — mismatch / block-not-found / ambiguous-start / end-not-found
    2 — usage / IO error
"""
from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
from pathlib import Path
from typing import Any


def extract_block(
    lines: list[str],
    start_re: re.Pattern[str],
    end_re: re.Pattern[str] | None,
    include_end: bool,
) -> tuple[list[str] | None, int, bool | None]:
    """Extract the landed block from `lines`.

    Returns `(block, start_match_count, end_found)`:
      - `block` is the list of block lines, or None when the start
        marker matched zero times.
      - `start_match_count` is how many lines matched the start marker
        (>1 signals ambiguity; the FIRST match is used for extraction).
      - `end_found` is True/False when `end_re` was given (whether the
        end marker matched after the start), or None when no `end_re`.

    Extraction matches the canonical awk idiom: the start-marker line is
    included; the end-marker line is excluded (unless `include_end`)."""
    start_idxs = [i for i, ln in enumerate(lines) if start_re.search(ln)]
    if not start_idxs:
        return None, 0, (None if end_re is None else False)

    start = start_idxs[0]
    block = [lines[start]]
    end_found: bool | None = None if end_re is None else False
    i = start + 1
    while i < len(lines):
        if end_re is not None and end_re.search(lines[i]):
            end_found = True
            if include_end:
                block.append(lines[i])
            break
        block.append(lines[i])
        i += 1
    return block, len(start_idxs), end_found


def _first_diff_line(staged: list[str], landed: list[str]) -> int | None:
    """1-based index of the first differing line, or the position just
    past the common prefix when one side is a prefix of the other.
    None when the two line lists are identical."""
    for idx, (a, b) in enumerate(zip(staged, landed)):
        if a != b:
            return idx + 1
    if len(staged) != len(landed):
        return min(len(staged), len(landed)) + 1
    return None


def scan(
    staged_path: Path,
    target_path: Path,
    start_marker: str,
    end_marker: str | None,
    include_end: bool,
) -> dict[str, Any]:
    staged_text = staged_path.read_text(encoding="utf-8")
    target_text = target_path.read_text(encoding="utf-8")

    staged_lines = staged_text.splitlines()
    target_lines = target_text.splitlines()

    start_re = re.compile(start_marker)
    end_re = re.compile(end_marker) if end_marker else None

    block, start_count, end_found = extract_block(
        target_lines, start_re, end_re, include_end)

    reasons: list[dict[str, Any]] = []
    landed_line_count: int | None = None
    first_diff: int | None = None
    diff_text = ""

    if block is None:
        reasons.append({
            "kind": "block_not_found",
            "detail": (f"start marker {start_marker!r} matched no line in "
                       f"{target_path}"),
        })
    else:
        landed_line_count = len(block)
        if start_count > 1:
            reasons.append({
                "kind": "ambiguous_start_marker",
                "detail": (f"start marker {start_marker!r} matched "
                           f"{start_count} lines; the first was used. "
                           f"Tighten the marker so it matches exactly one."),
            })
        if end_re is not None and not end_found:
            reasons.append({
                "kind": "end_marker_not_found",
                "detail": (f"end marker {end_marker!r} never matched after the "
                           f"start; the block ran to EOF — extraction may be "
                           f"unbounded."),
            })
        if block != staged_lines:
            first_diff = _first_diff_line(staged_lines, block)
            if len(block) != len(staged_lines):
                reasons.append({
                    "kind": "line_count_mismatch",
                    "detail": (f"staged has {len(staged_lines)} lines; landed "
                               f"block has {len(block)} (first divergence at "
                               f"line {first_diff})"),
                })
            else:
                reasons.append({
                    "kind": "content_mismatch",
                    "detail": (f"line counts match ({len(block)}) but content "
                               f"differs at line {first_diff}"),
                })
            diff_text = "\n".join(difflib.unified_diff(
                staged_lines, block,
                fromfile="staged", tofile="landed", lineterm=""))

    identical = not reasons
    return {
        "staged": str(staged_path),
        "target": str(target_path),
        "start_marker": start_marker,
        "end_marker": end_marker,
        "include_end_marker": include_end,
        "block_found": block is not None,
        "start_match_count": start_count,
        "end_marker_found": end_found,
        "identical": identical,
        "should_fire": not identical,
        "staged_line_count": len(staged_lines),
        "landed_line_count": landed_line_count,
        "first_diff_line": first_diff,
        "reasons": reasons,
        "diff": diff_text,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=("Assert a hand-pasted block in a target file is "
                     "byte-for-byte the staged verbatim text. Extracts the "
                     "landed block via start/end markers (awk idiom) and "
                     "compares it line-exact against the staged source."))
    parser.add_argument("--staged", type=Path, required=True,
                        help="Path to the staged verbatim text file.")
    parser.add_argument("--target", type=Path, required=True,
                        help="Path to the edited file the block was pasted "
                             "into.")
    parser.add_argument("--start-marker", required=True,
                        help="Python regex; the matching line begins the "
                             "block (included).")
    parser.add_argument("--end-marker", default=None,
                        help="Python regex; the matching line ends the block "
                             "(excluded by default). Omit to run to EOF.")
    parser.add_argument("--include-end-marker", action="store_true",
                        help="Include the end-marker line in the block "
                             "(default: exclude, matching the awk idiom).")
    args = parser.parse_args(argv)

    for label, p in (("staged", args.staged), ("target", args.target)):
        if not p.exists():
            print(f"error: {label} file not found: {p}", file=sys.stderr)
            return 2

    try:
        result = scan(args.staged, args.target, args.start_marker,
                      args.end_marker, args.include_end_marker)
    except Exception as exc:  # noqa: BLE001 — surface any IO/parse error as exit 2
        print(f"error: scan failed: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(result, indent=2))
    return 0 if result["identical"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
