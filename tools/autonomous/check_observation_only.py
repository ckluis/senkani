#!/usr/bin/env python3
"""
Observation-only pre-pick fail-safe matcher for `/senkani-autonomous`
Step 3 (build mode). Scans a build candidate's `## Acceptance` section
for the canonical observation-over-time sentinel phrases and decides
whether the round should refuse to claim the item (it would abort at
pre-audit) and reclassify it `open → manual + groomable: true`.

The match rule, with the disambiguation that distinguishes a genuine
observation-only acceptance bullet from a bullet that merely NAMES the
fail-safe / hook mechanism:

  Hit = an acceptance bullet contains a sentinel phrase (case-
  insensitive substring) that is NOT a self-reference to the
  fail-safe / hook mechanism itself.

  A sentinel occurrence is a **self-reference** when one of the
  mechanism-naming tokens `pre-pick`, `fail-safe`, or `hook` sits
  within ≤2 words of the occurrence (stopping at a sentence boundary
  — a period ends the window). Such an occurrence names the mechanism;
  it does not describe observation-over-time work, so it does NOT
  count as a hit.

  A bullet is observation-only iff it contains at least one
  NON-self-referential sentinel occurrence.

Why the guard exists. The crude "any sentinel substring = hit" rule
false-positives on acceptance bullets that reference the fail-safe by
name. Worked example (2026-05-26, `process-gap-phase-v13-dangling-
blocked-by-phase-u1-tier-scorer`): acceptance bullet 4 read

  "... build mode will pick it on a future round (subject to the
   observation-only pre-pick fail-safe)."

The substring `observation-only` is present, but only as the
mechanism's name — `pre-pick fail-safe` immediately follows. A literal
substring match would refuse the perfectly buildable backlog-integrity
data fix, reclassify it `manual + groomable: true`, and hand it to
groom mode, which finds no Cowork-runnable shape and aborts — a thrash
loop strictly worse than the wasted round the fail-safe exists to
prevent. This guard mirrors the Step 2.5 close-mode hook's existing
"genuinely code-buildable → leave it alone" carve-out so the backstop
and the primary mechanism agree.

The canonical sentinel list is the SAME one SKILL.md Step 2.5 and
`spec/autonomous/PROCESS.md` `## Canonical sentinel phrases` carry —
that text is the single source of truth. A new phrase joins ONLY by a
round that edits all three in the same commit.

Exit codes (mirroring `check_external_surfaces.py`):
- 1: the item IS observation-only (>=1 genuine sentinel hit) — the
     round should reclassify and abort the build.
- 0: clean — no sentinel hits, OR every sentinel occurrence is a
     mechanism-name self-reference. The round builds normally.
- 2: file not found, unreadable, or non-UTF-8. Best-effort: the round
     treats exit 2 as "proceed" (do NOT crash the round on IO error).

Usage:
    python3 tools/autonomous/check_observation_only.py <item-path>

Example:
    $ python3 tools/autonomous/check_observation_only.py \\
        spec/autonomous/backlog/some-item.md
    {"item": "...", "is_observation_only": false, ...}
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# --- Canonical sentinel phrases -----------------------------------
# Mirror of SKILL.md Step 2.5 / PROCESS.md `## Canonical sentinel
# phrases`. Each entry is a (label, compiled-regex) pair. Labels are
# the human-readable phrase reported in the JSON output; the regex is
# the actual matcher (case-insensitive). The `N consecutive` / `watch
# over N` patterns encode the "N >= 3, unit = CI runs / pushes /
# merges" qualifier from the source list.
SENTINEL_SPECS: list[tuple[str, str]] = [
    ("observation-over-time", r"observation-over-time"),
    ("observation-only", r"observation-only"),
    ("multi-CI observation", r"multi-CI(?:-run)?\s+observation"),
    # "5 consecutive (CI) green" and similar: N >= 3, unit in
    # {green, runs, pushes, merges}. \b before the digit avoids
    # matching "15" as ">= 3" only by its leading "1"; we accept any
    # integer >= 3 (single digit 3-9 or any multi-digit number).
    (
        "N consecutive CI green/runs/pushes/merges",
        r"\b(?:[3-9]|\d{2,})\s+consecutive\s+(?:CI\s+)?"
        r"(?:green|runs?|pushes?|merges?)\b",
    ),
    ("watch over N CI runs", r"watch over\s+\d+\s+(?:CI\s+)?runs?"),
    ("post-merge CI observation", r"post-merge\s+CI\s+observation"),
    ("telemetry accumulation", r"telemetry\s+accumulation"),
    ("needs real CI runs", r"needs\s+real\s+CI\s+runs"),
    ("needs real-machine observation", r"needs\s+real-machine\s+observation"),
]
SENTINELS: list[tuple[str, re.Pattern[str]]] = [
    (label, re.compile(pat, re.IGNORECASE)) for label, pat in SENTINEL_SPECS
]

# Self-reference context tokens. A sentinel occurrence adjacent
# (<=2 words, same sentence) to any of these names or labels the
# matching machinery rather than describing observation-over-time
# work, so it is a self-reference, not a hit:
#   - `pre-pick`, `fail-safe`, `hook` — the mechanism's own names
#     (mandated carve-out; the phase-v13 false positive said
#     "observation-only pre-pick fail-safe").
#   - `bullet(s)` — the matcher's INPUT unit. A bullet that talks
#     about an "observation-only acceptance bullet" is describing the
#     matcher's behaviour (e.g. a test-case spec), not stating real
#     CI-observation work. Genuine observation criteria describe the
#     activity ("observation-only monitoring", "watch over 5 CI
#     runs"), never "observation-only bullet" — so this token has
#     near-zero false-negative risk while making the fail-safe correct
#     on items (like its own defining item) whose acceptance criteria
#     are ABOUT sentinel matching.
MECHANISM_RE = re.compile(r"(?i)\b(?:pre-?pick|fail-?safe|hook|bullets?)\b")

# How many words on each side of a sentinel occurrence count as
# "immediately adjacent". 2 reaches "fail-safe" across one connective
# (e.g. "observation-only ... fail-safe" or "observation-only pre-pick
# fail-safe") while leaving a genuine bullet whose nearest mechanism
# word is 3+ words away (e.g. "watch over 5 CI runs; ... the hook")
# firing correctly.
ADJACENCY_WORDS = 2

ACCEPTANCE_HEADING_RE = re.compile(r"^##\s+Acceptance\b", re.MULTILINE)
NEXT_HEADING_RE = re.compile(r"^##\s+", re.MULTILINE)
# Sentence boundary: a SINGLE period followed by whitespace/end-of-text.
# Used to stop the adjacency window from crossing into a new sentence.
# The negative look-around for adjacent periods means an ellipsis
# (`...`) is NOT treated as a boundary — `observation-only ... fail-safe`
# must keep `fail-safe` inside the window so the occurrence reads as a
# mechanism-name self-reference. (Versions like `2.5` / `SKILL.md` are
# also excluded since their period is not followed by whitespace.)
SENTENCE_BREAK_RE = re.compile(r"(?<!\.)\.(?!\.)(?:\s|$)")


def extract_acceptance(text: str) -> str:
    """Return the body of the first `## Acceptance` section (text from
    the heading line to the next `## ` heading, exclusive). Empty
    string if no Acceptance section exists."""
    m = ACCEPTANCE_HEADING_RE.search(text)
    if not m:
        return ""
    rest = text[m.end():]
    nxt = NEXT_HEADING_RE.search(rest)
    return rest[: nxt.start()] if nxt else rest


def split_bullets(acceptance: str) -> list[str]:
    """Split an acceptance section into list-item bullets. Each bullet
    is the joined text of a `- ...` line plus its indented
    continuation lines. Lines before the first bullet are ignored."""
    bullets: list[str] = []
    current: list[str] | None = None
    for line in acceptance.splitlines():
        if re.match(r"^\s*[-*]\s+", line):
            if current is not None:
                bullets.append(" ".join(current).strip())
            current = [re.sub(r"^\s*[-*]\s+(?:\[[ xX]\]\s*)?", "", line)]
        elif current is not None and line.strip():
            current.append(line.strip())
        elif current is not None:
            # blank line ends the current bullet's continuation
            bullets.append(" ".join(current).strip())
            current = None
    if current is not None:
        bullets.append(" ".join(current).strip())
    return [b for b in bullets if b]


def _trailing_context(bullet: str, end: int) -> str:
    """Up to ADJACENCY_WORDS words after `end`, stopping at the first
    sentence boundary."""
    after = bullet[end:]
    brk = SENTENCE_BREAK_RE.search(after)
    if brk:
        after = after[: brk.start()]
    return " ".join(after.split()[:ADJACENCY_WORDS])


def _leading_context(bullet: str, start: int) -> str:
    """Up to ADJACENCY_WORDS words before `start`, stopping at the
    previous sentence boundary."""
    before = bullet[:start]
    breaks = list(SENTENCE_BREAK_RE.finditer(before))
    if breaks:
        before = before[breaks[-1].end():]
    return " ".join(before.split()[-ADJACENCY_WORDS:])


def is_self_reference(bullet: str, start: int, end: int) -> str | None:
    """Return the mechanism token that makes this sentinel occurrence a
    self-reference, or None if the occurrence is genuine
    (observation-over-time) rather than a mechanism-name reference."""
    for ctx in (_trailing_context(bullet, end), _leading_context(bullet, start)):
        mm = MECHANISM_RE.search(ctx)
        if mm:
            return mm.group(0)
    return None


def classify(acceptance: str) -> dict:
    """Classify an acceptance section. Returns a dict with
    `is_observation_only`, `genuine_hits`, and `self_references`."""
    genuine: list[dict] = []
    selfrefs: list[dict] = []
    for bullet in split_bullets(acceptance):
        for label, pat in SENTINELS:
            for m in pat.finditer(bullet):
                token = is_self_reference(bullet, m.start(), m.end())
                record = {
                    "phrase": label,
                    "matched_text": m.group(0),
                    "bullet": bullet,
                }
                if token is None:
                    genuine.append(record)
                else:
                    record["mechanism_token"] = token
                    selfrefs.append(record)
    return {
        "is_observation_only": bool(genuine),
        "genuine_hits": genuine,
        "self_references": selfrefs,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Decide whether a build candidate's `## Acceptance` section "
            "is observation-only (exit 1) or buildable (exit 0). "
            "Sentinel occurrences that only name the fail-safe / hook "
            "mechanism are NOT counted as hits."
        )
    )
    parser.add_argument("path", help="Per-item backlog file path")
    args = parser.parse_args(argv)

    p = Path(args.path)
    try:
        text = p.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        sys.stderr.write(f"check_observation_only: {p}: {e}\n")
        return 2

    acceptance = extract_acceptance(text)
    result = classify(acceptance)
    result["item"] = str(p)
    result["has_acceptance_section"] = bool(acceptance.strip())
    # Stable key order for readability.
    ordered = {
        "item": result["item"],
        "is_observation_only": result["is_observation_only"],
        "has_acceptance_section": result["has_acceptance_section"],
        "genuine_hits": result["genuine_hits"],
        "self_references": result["self_references"],
    }
    print(json.dumps(ordered, indent=2))
    return 1 if result["is_observation_only"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
