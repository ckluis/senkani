#!/usr/bin/env python3
"""
check-backlog-statuses — validate that every per-item file in
`spec/autonomous/backlog/` uses a status value the /senkani-autonomous
loop recognizes.

The closed status taxonomy (PROCESS.md "Status taxonomy is closed") is NINE
values. Seven are pick-eligible at SKILL.md Step 3:

    open | blocked | manual | manual_ready | in_progress | done | skipped

Two more are valid but intentionally NON-pickable convergence/burndown statuses:

    retired | queued_for_console

(`retired` = reversible GC, prior status recorded in a `## GC note`;
`queued_for_console` = routed to the attended operator console. Both stay in
`backlog/` and preserve their prior status's companion flags — see
FLAG_PRESERVING_STATUSES below.)

Files using any value OUTSIDE these nine (e.g. `ready`, `ready_to_build`, `wip`)
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
  - A decomposed parent with `split_into:` may not remain
    `status: manual_ready` after every child has shipped `status: done`;
    the parent is then an already-resolved umbrella and should be flipped
    to `done` so it no longer looks operator-actionable.
  - A backlog item's `blocked_by:` must reference only ids that resolve
    to a real item in `backlog/` or `completed/`. A dangling id can never
    reach `status: done`, so the item is wedged out of the build queue
    forever (see `process-gap-phase-v13-dangling-blocked-by-phase-u1-
    tier-scorer-2026-05-26`).

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
    # Convergence/burndown statuses (PROCESS.md `## retired and queued_for_console`).
    # Both are NON-terminal, non-pickable, and stay in backlog/. `retired` is a
    # reversible GC status that records its prior status in a `## GC note`;
    # `queued_for_console` marks an item routed to the attended operator console.
    # The taxonomy is closed at these nine — see PROCESS.md "Status taxonomy is closed."
    "retired",
    "queued_for_console",
}

# `retired` and `queued_for_console` legitimately PRESERVE the companion flags
# (groomable / decomposable / scope_groomable / groomed / decomposed) of their prior
# status: `retired` is reversible (the prior status + its flags are restored on
# un-retire), and `queued_for_console` is en route back to a pickable status. So the
# per-file companion-flag invariants in `check_file` are SKIPPED for these two —
# checking them would flag a legitimately preserved flag (e.g. a retired-while-
# decomposed item carrying `decomposed:` + `decomposable: true`). The repo-wide
# checks (dangling `blocked_by`, decomposed-parent closure, completed-evidence) still
# apply, since they run in separate passes outside `check_file`.
FLAG_PRESERVING_STATUSES = {"retired", "queued_for_console"}

GROOMED_DATE_VALID_STATUSES = {"manual_ready", "done", "skipped", "in_progress"}
DECOMPOSED_DATE_VALID_STATUSES = {"manual_ready", "done", "skipped", "in_progress"}

# V.17a-7 / Option-C close-mode auto-stub recognition.
#
# Per `process-gap-close-mode-execution-evidence-invariant-vs-decomposed-
# parent-contract-2026-05-23` (operator chose Option C 2026-05-24):
# the close-mode sweep auto-appends a one-line evidence stub to
# decomposed-parent orphans that lack `## Execution evidence`. The
# stub format is fixed text; this validator recognizes that format
# so a stubbed parent is not mistaken for missing evidence.
#
# Stub-first-line shape: `## Execution evidence <YYYY-MM-DD>` followed
# by a sentinel sentence naming the operator-confirmed split.
EVIDENCE_HEADING_RE = re.compile(r"^## Execution evidence\b", re.MULTILINE)
EVIDENCE_AUTO_STUB_SENTINEL = "Operator confirmed decomposition is correct"


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


def parse_inline_list(value: str) -> list[str]:
    value = value.strip()
    if not (value.startswith("[") and value.endswith("]")):
        return []
    inner = value[1:-1].strip()
    if not inner:
        return []
    return [item.strip().strip('"').strip("'") for item in inner.split(",")]


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

    if status in FLAG_PRESERVING_STATUSES:
        # `retired` / `queued_for_console` preserve their prior status's companion
        # flags for audit + reversibility — skip the per-file companion-flag
        # invariants below. The repo-wide checks (dangling `blocked_by`,
        # decomposed-parent closure, completed-evidence) run in separate passes and
        # still apply to these items.
        return findings

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


def iter_item_files(backlog_dir: Path) -> list[Path]:
    autonomous_dir = backlog_dir.parent
    files = [path for path in sorted(backlog_dir.glob("*.md")) if path.name != "index.md"]
    completed_dir = autonomous_dir / "completed"
    if completed_dir.is_dir():
        files.extend(path for path in sorted(completed_dir.rglob("*.md")) if path.name != "index.md")
    return files


def classify_evidence_section(text: str) -> str:
    """Return one of "absent", "auto_stub", "operator".

    "auto_stub" matches the Option-C close-mode auto-stub format (per
    `process-gap-close-mode-execution-evidence-invariant-vs-decomposed
    -parent-contract-2026-05-23`); "operator" is any other non-empty
    evidence section the operator (or a build-mode close) wrote.
    """
    m = EVIDENCE_HEADING_RE.search(text)
    if not m:
        return "absent"
    body = text[m.end():]
    # Look only at the first ~500 chars under the heading — enough to
    # recognize the auto-stub sentinel without false-matching deeper
    # content that mentions the sentence in unrelated context.
    window = body[:500]
    if EVIDENCE_AUTO_STUB_SENTINEL in window:
        return "auto_stub"
    return "operator"


def check_decomposed_completed_evidence(backlog_dir: Path) -> dict[Path, list[str]]:
    """Flag completed decomposed-parent items whose body lacks any
    `## Execution evidence` section.

    Decompose-mode parent body template historically said evidence was
    "optional," but the Step 2 close-mode invariant required it. The
    operator picked Option C (auto-stub in close-mode sweep) on
    2026-05-24 — so every decomposed parent in `completed/` should now
    have at minimum an auto-stub. A completed parent with `decomposed:`
    + `split_into:` and NO evidence section indicates a close-mode
    sweep that bypassed the auto-stub path (operator close without the
    SKILL.md edit, or a bug). Data-hygiene flag.
    """
    autonomous_dir = backlog_dir.parent
    completed_dir = autonomous_dir / "completed"
    if not completed_dir.is_dir():
        return {}
    findings: dict[Path, list[str]] = {}
    for path in sorted(completed_dir.rglob("*.md")):
        if path.name == "index.md":
            continue
        text = path.read_text(encoding="utf-8")
        fm = parse_frontmatter(text)
        decomposed = fm.get("decomposed", "").strip()
        split_into = parse_inline_list(fm.get("split_into", ""))
        if not decomposed or not split_into:
            continue
        kind = classify_evidence_section(text)
        if kind == "absent":
            findings.setdefault(path, []).append(
                "decomposed parent in `completed/` has no `## Execution "
                "evidence` section. Option-C close-mode auto-stub should "
                "have appended one — see `process-gap-close-mode-"
                "execution-evidence-invariant-vs-decomposed-parent-"
                "contract-2026-05-23`. Append a stub or operator-"
                "provided evidence and re-validate."
            )
    return findings


def check_decomposed_parent_closure(backlog_dir: Path) -> dict[Path, list[str]]:
    """Return repo-wide findings for decomposed parents whose children
    already shipped.

    Decompose-mode intentionally leaves the parent in backlog/manual_ready
    until the operator confirms the split. Once every child resolves to
    `status: done`, the parent is no longer a work item and should flip to
    `done` for close-mode finalization.
    """
    items: dict[str, tuple[Path, dict[str, str]]] = {}
    for path in iter_item_files(backlog_dir):
        fm = parse_frontmatter(path.read_text(encoding="utf-8"))
        item_id = fm.get("id", "").strip().strip('"').strip("'")
        if item_id:
            items[item_id] = (path, fm)

    findings: dict[Path, list[str]] = {}
    for path in sorted(backlog_dir.glob("*.md")):
        if path.name == "index.md":
            continue
        fm = parse_frontmatter(path.read_text(encoding="utf-8"))
        status = fm.get("status", "").strip().strip('"').strip("'")
        if status != "manual_ready":
            continue
        children = parse_inline_list(fm.get("split_into", ""))
        if not children:
            continue
        child_statuses: list[tuple[str, str]] = []
        missing: list[str] = []
        for child in children:
            record = items.get(child)
            if record is None:
                missing.append(child)
                continue
            child_statuses.append((child, record[1].get("status", "").strip().strip('"').strip("'")))
        if missing:
            findings.setdefault(path, []).append(
                "`split_into:` references missing child item(s): "
                + ", ".join(missing)
            )
            continue
        if child_statuses and all(status == "done" for _, status in child_statuses):
            findings.setdefault(path, []).append(
                "`status: manual_ready` decomposed parent has all children "
                "`status: done`; flip parent to `status: done` so the "
                "umbrella does not remain operator-actionable."
            )
    return findings


def check_dangling_blocked_by(backlog_dir: Path) -> dict[Path, list[str]]:
    """Flag backlog items whose `blocked_by:` references an id that resolves
    to no item anywhere in `backlog/` or `completed/`.

    The loop's pick precedence (SKILL.md Step 3) only builds an item when
    every `blocked_by` id resolves to a real item with `status: done`. A
    `blocked_by` id that matches NO item can never resolve — the item is
    silently wedged out of the build queue forever, with nothing flagging
    the typo-class data error. This is the inverse of the observation-only
    pre-pick fail-safe: that catches items that *would* be picked but
    shouldn't; this catches an item that *should* be pickable but never
    will be.

    Originating finding:
    `process-gap-phase-v13-dangling-blocked-by-phase-u1-tier-scorer-2026-05-26`
    — `phase-v13`'s `blocked_by` referenced `phase-u1-tier-scorer`, an
    envelope id that never existed (the U.1 tier-scorer shipped as three
    sub-items u1a/u1b/u1c), so the blocker never resolved and phase-v13 sat
    permanently unbuildable.

    Resolution set = backlog ∪ completed (via `iter_item_files`), matching
    the loop's actual `blocked_by` lookup. Completed items contribute ids
    too (a stale blocker on an already-`done` item is harmless), but only
    backlog items are flagged — they are the ones the loop tries to pick.
    """
    known_ids: set[str] = set()
    for path in iter_item_files(backlog_dir):
        fm = parse_frontmatter(path.read_text(encoding="utf-8"))
        item_id = fm.get("id", "").strip().strip('"').strip("'")
        if item_id:
            known_ids.add(item_id)

    findings: dict[Path, list[str]] = {}
    for path in sorted(backlog_dir.glob("*.md")):
        if path.name == "index.md":
            continue
        fm = parse_frontmatter(path.read_text(encoding="utf-8"))
        blockers = parse_inline_list(fm.get("blocked_by", ""))
        dangling = [b for b in blockers if b and b not in known_ids]
        if dangling:
            findings.setdefault(path, []).append(
                "`blocked_by:` references id(s) that resolve to no item in "
                "`backlog/` or `completed/`: "
                + ", ".join(dangling)
                + ". A blocker matching no item can never reach "
                "`status: done`, so the loop will never build this item. "
                "Correct the id (often a rename after the dependency was "
                "decomposed into sub-items) or drop the stale entry."
            )
    return findings


def display_path(path: Path, repo_root: Path) -> str:
    try:
        return str(path.relative_to(repo_root))
    except ValueError:
        return str(path)


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
            print(f"{display_path(path, repo_root)}:")
            for f in findings:
                print(f"  - {f}")

    closure_findings = check_decomposed_parent_closure(backlog_dir)
    for path, findings in closure_findings.items():
        flagged += 1
        print(f"{display_path(path, repo_root)}:")
        for f in findings:
            print(f"  - {f}")

    completed_evidence_findings = check_decomposed_completed_evidence(backlog_dir)
    for path, findings in completed_evidence_findings.items():
        flagged += 1
        print(f"{display_path(path, repo_root)}:")
        for f in findings:
            print(f"  - {f}")

    dangling_findings = check_dangling_blocked_by(backlog_dir)
    for path, findings in dangling_findings.items():
        flagged += 1
        print(f"{display_path(path, repo_root)}:")
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
