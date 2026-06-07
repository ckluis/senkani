#!/usr/bin/env python3
"""
Scan a per-item backlog file's body for `## (Groom|Build|Scope-groom|
Decompose) abort .* <YYYY-MM-DD>` section headers and print the
latest matching ISO date string on stdout (empty string + exit 0 on
no match).

Used by `/senkani-autonomous` Step 3 (Pick the round) "Same-day-abort
skip" sub-rule: if today's date matches the latest abort date AND
the item's `last_touched:` frontmatter is NOT today, the pick
precedence skips the item to the next candidate.

Originating finding:
`process-gap-aborted-item-same-day-repick-2026-05-21`. Operator
scope-groom 2026-05-23 chose mechanism (A) — time-based skip with
re-eligibility = next ISO date OR last_touched bump.

Section forms recognized:

- `## Groom abort note 2026-05-21`
- `## Groom abort retry note 2026-05-21 (round 2)`
- `## Build abort note 2026-05-22`
- `## Build abort note 2026-05-22 — <slug>`
- `## Scope-groom abort note 2026-05-23`
- `## Decompose abort note 2026-05-22`

The regex matches `^## (Groom|Build|Scope-groom|Decompose) abort\b`
followed by any text containing an ISO `YYYY-MM-DD` substring. If a
section header carries multiple ISO dates (unlikely but harmless),
the first one wins.

Exit codes:
- 0: success (stdout = latest ISO date string OR empty line on no match).
- 2: file not found, unreadable, or non-UTF-8.

The helper is best-effort: parse errors NEVER crash the round; the
pick precedence treats exit 2 as "no abort, eligible."

Usage:
    python3 tools/autonomous/check_same_day_abort.py <path>

Example:
    $ python3 tools/autonomous/check_same_day_abort.py \\
        spec/autonomous/backlog/phase-t3-wasm-sandbox.md
    2026-05-21
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ABORT_HEADER_RE = re.compile(
    r"^##\s+(?:Groom|Build|Scope-groom|Decompose)\s+abort\b.*?(\d{4}-\d{2}-\d{2})",
    re.IGNORECASE | re.MULTILINE,
)


def latest_abort_date(text: str) -> str:
    """Return the latest ISO date string from all abort-note section
    headers in `text`. Empty string when no header matches.

    Order: lexicographic sort on ISO date strings — works because
    `YYYY-MM-DD` sorts chronologically.
    """
    dates = ABORT_HEADER_RE.findall(text)
    if not dates:
        return ""
    return max(dates)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Print the latest ISO date from any "
            "`## (Groom|Build|Scope-groom|Decompose) abort` "
            "section header in the given per-item backlog file. "
            "Empty stdout + exit 0 on no match."
        )
    )
    parser.add_argument("path", help="Per-item backlog file path")
    args = parser.parse_args()

    p = Path(args.path)
    try:
        text = p.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        sys.stderr.write(f"check_same_day_abort: {p}: {e}\n")
        return 2

    print(latest_abort_date(text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
