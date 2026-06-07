#!/usr/bin/env python3
"""
file_sub_item — emit a per-item file under `spec/autonomous/backlog/`.

Loop-internal helper called by /senkani-autonomous decompose mode (phase
7 synthesis) once per child item. The helper writes a fresh per-item
file using the `spec/autonomous/_template.md` shape, validates
frontmatter enums against `check-backlog-statuses.py` invariants, and is
idempotent (refuses to overwrite an existing file). Prints the absolute
path of the written file on stdout for shell-pipeline chaining.

For operator hand-filing, use the `_template.md` copy path documented in
`spec/autonomous/PROCESS.md` § "Adding a new backlog item". The helper
exists so the loop's decompose mode can emit N children deterministically
in one round without operator hand-work.

Usage:
    python3 tools/autonomous/file_sub_item.py \\
      --id phase-v18a-1-schema-migration \\
      --title "V.18a-1 — RuntimeTelemetryDataset schema migration" \\
      --status open \\
      --type feature \\
      --size small \\
      --phase V \\
      --priority P2 \\
      --roster Majors,Tufte,Kleppmann \\
      --affects feature_added,session_database,subsystem_changed \\
      --blocked-by phase-v2-canonical-trace-row,phase-u2-validation-store-browser \\
      --parent-finding "phase-v18-runtime-telemetry-dataset — decomposition 2026-05-22 (1 of 9)" \\
      --tests-target 4 \\
      --scope-file /tmp/v18a-1-scope.md \\
      --acceptance-file /tmp/v18a-1-acceptance.md \\
      --created 2026-05-22 \\
      --last-touched 2026-05-22

Exit codes:
    0 — file written; absolute path printed on stdout
    1 — target file already exists (idempotency refusal)
    2 — frontmatter enum violation, missing input file, or argument error
"""
from __future__ import annotations
import argparse
import re
import sys
from datetime import date
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

VALID_TYPES = {
    "feature",
    "cleanup",
    "bug",
    "performance",
    "security",
    "docs",
    "infra",
    "research",
    "process",
}

VALID_SIZES = {"small", "medium", "meaty"}
VALID_PRIORITIES = {"P0", "P1", "P2", "P3"}
PHASE_RE = re.compile(r"^[A-Z][a-zA-Z0-9.]*$")
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
ISO_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _csv(arg: str | None) -> list[str]:
    if not arg:
        return []
    return [s.strip() for s in arg.split(",") if s.strip()]


def _yaml_list(values: list[str]) -> str:
    if not values:
        return "[]"
    return "[" + ", ".join(values) + "]"


def _yaml_quote(value: str) -> str:
    """Quote a string for YAML if it contains characters that need it."""
    if not value:
        return '""'
    if any(c in value for c in ':#"\'\n\r\t') or value[0] in "!&*?{[|>-" or value.endswith(" "):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return value


def validate(args: argparse.Namespace) -> list[str]:
    """Return a list of human-readable validation errors; empty if clean."""
    errors: list[str] = []

    if not ID_RE.match(args.id):
        errors.append(
            f"--id {args.id!r} is not kebab-case (must match {ID_RE.pattern})"
        )

    if not args.title.strip():
        errors.append("--title is empty")

    if args.status not in VALID_STATUSES:
        errors.append(
            f"--status {args.status!r} not in taxonomy "
            f"({' | '.join(sorted(VALID_STATUSES))})"
        )

    if args.type not in VALID_TYPES:
        errors.append(
            f"--type {args.type!r} not in taxonomy "
            f"({' | '.join(sorted(VALID_TYPES))})"
        )

    if args.size not in VALID_SIZES:
        errors.append(
            f"--size {args.size!r} not in taxonomy "
            f"({' | '.join(sorted(VALID_SIZES))})"
        )

    if args.phase and not PHASE_RE.match(args.phase):
        errors.append(
            f"--phase {args.phase!r} not a valid phase code "
            f"(must match {PHASE_RE.pattern})"
        )

    if args.priority and args.priority not in VALID_PRIORITIES:
        errors.append(
            f"--priority {args.priority!r} not in taxonomy "
            f"({' | '.join(sorted(VALID_PRIORITIES))})"
        )

    if args.created and not ISO_DATE_RE.match(args.created):
        errors.append(f"--created {args.created!r} not ISO YYYY-MM-DD")

    if args.last_touched and not ISO_DATE_RE.match(args.last_touched):
        errors.append(f"--last-touched {args.last_touched!r} not ISO YYYY-MM-DD")

    # Companion-flag invariants (mirror of check-backlog-statuses.py)
    groomable = args.groomable
    decomposable = args.decomposable
    scope_groomable = args.scope_groomable
    if groomable and args.status not in {"manual", "manual_ready"}:
        errors.append(
            "--groomable true requires --status manual (or manual_ready)"
        )
    if decomposable and args.status not in {"manual", "manual_ready"}:
        errors.append(
            "--decomposable true requires --status manual (or manual_ready)"
        )
    if scope_groomable and args.status not in {"manual", "open", "blocked", "skipped"}:
        errors.append(
            "--scope-groomable true requires --status manual "
            "(or post-interview open/blocked/skipped)"
        )

    if args.blocked_reason and args.status not in {"blocked", "manual"}:
        errors.append(
            f"--blocked-reason set but --status {args.status!r} — "
            "blocked_reason is required only for blocked/manual"
        )
    if not args.blocked_reason and args.status in {"blocked", "manual"}:
        errors.append(
            f"--status {args.status!r} requires --blocked-reason"
        )

    if not Path(args.scope_file).is_file():
        errors.append(f"--scope-file {args.scope_file!r} not a readable file")
    if not Path(args.acceptance_file).is_file():
        errors.append(
            f"--acceptance-file {args.acceptance_file!r} not a readable file"
        )

    return errors


def render(args: argparse.Namespace, scope_body: str, acceptance_body: str) -> str:
    """Return the per-item file contents as a single string."""
    today = date.today().isoformat()
    created = args.created or today
    last_touched = args.last_touched or today

    fm_lines = [
        "---",
        f"id: {args.id}",
        f"title: {_yaml_quote(args.title)}",
        f"status: {args.status}",
        f"type: {args.type}",
    ]
    if args.phase:
        fm_lines.append(f"phase: {args.phase}")
    fm_lines.append(f"size: {args.size}")
    if args.priority:
        fm_lines.append(f"priority: {args.priority}")

    fm_lines.append(f"roster: {_yaml_list(_csv(args.roster))}")
    fm_lines.append(f"affects: {_yaml_list(_csv(args.affects))}")
    fm_lines.append(f"blocked_by: {_yaml_list(_csv(args.blocked_by))}")

    if args.blocked_reason:
        fm_lines.append(f"blocked_reason: {_yaml_quote(args.blocked_reason)}")

    if args.groomable:
        fm_lines.append("groomable: true")
    if args.decomposable:
        fm_lines.append("decomposable: true")
    if args.scope_groomable:
        fm_lines.append("scope_groomable: true")

    if args.parent_finding:
        fm_lines.append(f"parent_finding: {_yaml_quote(args.parent_finding)}")

    if args.tests_target is not None:
        fm_lines.append(f"tests_target: {args.tests_target}")

    fm_lines.append(f"created: {created}")
    fm_lines.append(f"last_touched: {last_touched}")

    if args.source_inspirations:
        fm_lines.append(
            f"source_inspirations: {_yaml_list(_csv(args.source_inspirations))}"
        )
    if args.legacy_ref:
        fm_lines.append(f"legacy_ref: {_yaml_quote(args.legacy_ref)}")

    fm_lines.append("---")

    body = (
        f"\n# {args.title}\n\n"
        "[Backlog index](../index.md) · [Router](../../autonomous.md) · "
        "[Process](../PROCESS.md)\n\n"
        "## Scope\n\n"
        f"{scope_body.rstrip()}\n\n"
        "## Acceptance\n\n"
        f"{acceptance_body.rstrip()}\n\n"
        "## Notes\n\n"
        "Round-by-round journal. Pre-round notes go here. The skill "
        "appends in-progress notes during the round and a closing "
        "summary at the end.\n"
    )

    return "\n".join(fm_lines) + body


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="file_sub_item",
        description="Emit a new per-item file under spec/autonomous/backlog/.",
    )
    parser.add_argument("--id", required=True, help="stable kebab-case id")
    parser.add_argument("--title", required=True, help="one-line title")
    parser.add_argument("--status", default="open", help=f"one of: {sorted(VALID_STATUSES)}")
    parser.add_argument("--type", required=True, help=f"one of: {sorted(VALID_TYPES)}")
    parser.add_argument("--size", required=True, help=f"one of: {sorted(VALID_SIZES)}")
    parser.add_argument("--phase", default="", help="optional phase code (T|U|V|W|...)")
    parser.add_argument("--priority", default="", help=f"optional: {sorted(VALID_PRIORITIES)}")
    parser.add_argument("--roster", default="", help="comma-separated names")
    parser.add_argument("--affects", default="", help="comma-separated intent/subsystem tags")
    parser.add_argument("--blocked-by", default="", help="comma-separated ids")
    parser.add_argument("--blocked-reason", default="", help="quoted reason string")
    parser.add_argument("--groomable", action="store_true", help="set groomable: true")
    parser.add_argument("--decomposable", action="store_true", help="set decomposable: true")
    parser.add_argument("--scope-groomable", action="store_true", help="set scope_groomable: true")
    parser.add_argument("--parent-finding", default="", help="audit-trail reference")
    parser.add_argument(
        "--tests-target", type=int, default=None,
        help="expected new test count",
    )
    parser.add_argument("--created", default="", help="ISO date (default: today)")
    parser.add_argument(
        "--last-touched", default="", help="ISO date (default: today)",
    )
    parser.add_argument("--source-inspirations", default="", help="comma-separated slugs")
    parser.add_argument("--legacy-ref", default="", help="optional legacy reference")
    parser.add_argument(
        "--scope-file", required=True,
        help="path to a file whose contents become the body's ## Scope section",
    )
    parser.add_argument(
        "--acceptance-file", required=True,
        help="path to a file whose contents become the body's ## Acceptance section",
    )
    parser.add_argument(
        "--slug", default="",
        help="optional filename suffix: backlog/<id>-<slug>.md (default: <id>.md)",
    )
    parser.add_argument(
        "--backlog-dir", default="",
        help="override target dir (default: spec/autonomous/backlog/ under repo root)",
    )

    args = parser.parse_args(argv[1:])

    errors = validate(args)
    if errors:
        for e in errors:
            print(f"file_sub_item: {e}", file=sys.stderr)
        return 2

    if args.backlog_dir:
        backlog_dir = Path(args.backlog_dir)
    else:
        repo_root = Path(__file__).resolve().parents[2]
        backlog_dir = repo_root / "spec" / "autonomous" / "backlog"

    if not backlog_dir.is_dir():
        print(
            f"file_sub_item: backlog dir not found: {backlog_dir}",
            file=sys.stderr,
        )
        return 2

    filename = f"{args.id}-{args.slug}.md" if args.slug else f"{args.id}.md"
    target = backlog_dir / filename

    if target.exists():
        print(
            f"file_sub_item: refuse to overwrite existing file: {target}",
            file=sys.stderr,
        )
        return 1

    scope_body = Path(args.scope_file).read_text(encoding="utf-8")
    acceptance_body = Path(args.acceptance_file).read_text(encoding="utf-8")

    content = render(args, scope_body, acceptance_body)
    target.write_text(content, encoding="utf-8")

    print(str(target.resolve()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
