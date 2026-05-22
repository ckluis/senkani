#!/usr/bin/env python3
"""
check-backlog-statuses — validate that every per-item file in
`spec/autonomous/backlog/` uses a status value the /senkani-autonomous
loop recognizes.

The loop's pick precedence at SKILL.md Step 3 matches only:

    open | blocked | manual | manual_ready | in_progress | done | skipped

Files using any other status (e.g. `ready`, `ready_to_build`, `wip`)
sit invisible to all four round modes — they are never picked, never
groomed, never closed. The 2026-05-13 trigger:
`onboarding-milestone-6-workstream-create-discoverability-2026-05-13`
and `onboarding-milestone-7-sprint-review-seeder-2026-05-13` were
filed mid-walk by Cowork with `status: ready`, an invalid value.

Companion frontmatter sanity checks:

  - `groomable: true` requires `status: manual` (groom-mode picks from
    `manual` items only) OR a `groomed:` date (post-groom items have
    `status: manual_ready` and keep the flag for audit).
  - `groomed:` is set IFF `status` is one of {manual_ready, done,
    skipped, in_progress} — pre-groom items must not carry the date.
  - `scope_groomable: true` requires `status: manual` (scope-groom
    picks from manual items only) OR a `scope_groomed:` date.

Background: `process-gap-cowork-walks-write-invalid-status-2026-05-13`
(in-spirit; tracked here, no separate backlog item — the validator
IS the fix).

Usage:
    python3 tools/autonomous/check-backlog-statuses.py [BACKLOG_DIR]

Default BACKLOG_DIR: `spec/autonomous/backlog`.

Exit codes:
    0 — every file uses a valid status + companion flags consistent
    1 — one or more files flagged (each printed to stdout)
    2 — usage / IO error
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

VALID_STATUSES = {
    "open",
    "blocked",
    "manual",
    "manual_ready",
    "in_progress",
    "done",
    "skipped",
}

GROOMED_DATE_VALID_STATUSES = {"manual_ready", "done", "skipped", "in_progress"}
DECOMPOSED_DATE_VALID_STATUSES = {"manual_ready", "done", "skipped", "in_progress"}


def parse_frontmatter(text: str) -> dict[str, str]:
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---\n", 4)
    if end == -1:
        return {}
    fm: dict[str, str] = {}
    for line in text[4:end].splitlines():
        m = re.match(r"^([a-zA-Z_][\w-]*):\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm


def check_file(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    fm = parse_frontmatter(text)
    findings: list[str] = []

    status = fm.get("status", "").strip().strip('"').strip("'")
    if not status:
        findings.append("no `status:` field")
    elif status not in VALID_STATUSES:
        valid = " | ".join(sorted(VALID_STATUSES))
        findings.append(f"status: {status!r} is not in the taxonomy ({valid})")

    groomable = fm.get("groomable", "").lower() == "true"
    decomposable = fm.get("decomposable", "").lower() == "true"
    scope_groomable = fm.get("scope_groomable", "").lower() == "true"
    groomed = fm.get("groomed", "").strip()
    decomposed = fm.get("decomposed", "").strip()
    scope_groomed = fm.get("scope_groomed", "").strip()

    if groomable and status not in {"manual", "manual_ready", "in_progress", "blocked"} | {""}:
        # `blocked` allowed because a manual+groomable item can become blocked
        # without losing its grooming intent. `in_progress` allowed because the
        # round may be mid-groom.
        if status in VALID_STATUSES:
            findings.append(
                f"`groomable: true` but status={status!r} — groom mode "
                "picks only `manual` (or post-groom `manual_ready`). "
                "Likely the file means `status: manual` or should drop "
                "`groomable: true`."
            )

    if groomed and status not in GROOMED_DATE_VALID_STATUSES:
        if status in VALID_STATUSES:
            findings.append(
                f"`groomed: {groomed}` set but status={status!r}. "
                "A groomed date means a groom-mode round closed and "
                "wrote `status: manual_ready` (or operator/Cowork "
                "already flipped to `done`/`skipped`/`in_progress`). "
                "Pre-groom items must not carry this field."
            )

    if decomposable and status not in {"manual", "manual_ready", "in_progress", "blocked"} | {""}:
        # Same shape as groomable: post-decompose items keep the flag with
        # status: manual_ready (for audit) until operator confirms split
        # and flips to done. `blocked` allowed for the manual + decomposable
        # + blocked-on-something case. `in_progress` allowed mid-decompose.
        if status in VALID_STATUSES:
            findings.append(
                f"`decomposable: true` but status={status!r} — decompose "
                "mode picks only `manual` (or post-decompose "
                "`manual_ready`). Likely the file means `status: manual` "
                "or should drop `decomposable: true`."
            )

    if decomposed and status not in DECOMPOSED_DATE_VALID_STATUSES:
        if status in VALID_STATUSES:
            findings.append(
                f"`decomposed: {decomposed}` set but status={status!r}. "
                "A decomposed date means a decompose-mode round closed "
                "and wrote `status: manual_ready` (or operator already "
                "flipped to `done`/`skipped`/`in_progress`). Pre-decompose "
                "items must not carry this field."
            )

    if scope_groomable and status not in {"manual", "manual_ready", "in_progress", "open", "blocked", "skipped", "done"} | {""}:
        # `manual_ready` and `in_progress` allowed because a scope-
        # groomable item can transit through decompose mode (where the
        # operator's scope decisions stay queryable as the children inherit
        # them) or groom mode (where the scope decisions inform the test
        # plan). `done` allowed because a fully-resolved item retains the
        # flag as audit trail (the operator's scope-groom answers are
        # preserved verbatim in the `## Scope decisions` body section).
        if status in VALID_STATUSES:
            findings.append(
                f"`scope_groomable: true` but status={status!r}. "
                "Scope-groom picks only `manual`; after the interview "
                "the item flips to `open`/`blocked`/`skipped`/`done` "
                "and keeps the flag for audit. `manual_ready` / "
                "`in_progress` are tolerated for items transiting "
                "decompose or groom mode."
            )

    if scope_groomed and status == "manual" and not scope_groomable:
        # benign — a scope-groomed manual item likely had the flag flipped
        # to false post-interview if it's still manual. Skip.
        pass

    return findings


def main(argv: list[str]) -> int:
    repo_root = Path(__file__).resolve().parents[2]
    default_dir = repo_root / "spec" / "autonomous" / "backlog"
    if len(argv) > 2:
        print(f"usage: {argv[0]} [BACKLOG_DIR]", file=sys.stderr)
        return 2
    backlog_dir = Path(argv[1]) if len(argv) == 2 else default_dir
    if not backlog_dir.is_dir():
        print(f"backlog dir not found: {backlog_dir}", file=sys.stderr)
        return 2

    flagged = 0
    for path in sorted(backlog_dir.glob("*.md")):
        if path.name == "index.md":
            continue
        findings = check_file(path)
        if findings:
            flagged += 1
            print(f"{path.relative_to(repo_root)}:")
            for f in findings:
                print(f"  - {f}")

    if flagged == 0:
        print(f"OK — all {sum(1 for _ in backlog_dir.glob('*.md')) - 1} "
              f"backlog files use valid statuses.")
        return 0
    print(f"\n{flagged} file(s) flagged.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
