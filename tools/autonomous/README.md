# Senkani autonomous development loop

Continuous plan → build → test → re-audit → doc-sync cycles driven by
the backlog at `spec/autonomous-backlog.yaml`.

## Components

- **`spec/autonomous-backlog.yaml`** — the typed work queue. Each item
  has `id`, `title`, `status`, `scope`, `acceptance`, `roster`, and
  `blocked_by`. Persistent state between rounds. Keep this file under
  version control.
- **`~/.claude/skills/senkani-autonomous/SKILL.md`** — the per-round
  playbook. Invoked via `/senkani-autonomous`. Runs the full Luminary
  process on ONE item, ships it, updates docs, marks it done, and
  exits. Designed for fresh-context invocations.
- **`tools/autonomous/run-rounds.sh`** — unattended driver that loops
  `claude -p "/senkani-autonomous"` with a configurable gap between
  rounds. Each iteration is a fresh `claude` session by construction.

## Usage patterns

### Interactive (one round at a time)

```
/clear
/senkani-autonomous
```

Each `/clear` + `/senkani-autonomous` pair ships one backlog item.

### Unattended shell loop

```bash
# Every 10 minutes, run the next round until the backlog empties
./tools/autonomous/run-rounds.sh

# Custom gap + cap
./tools/autonomous/run-rounds.sh --gap 1800 --max 5

# Dry run (log what would happen, don't invoke claude)
./tools/autonomous/run-rounds.sh --dry-run
```

### Scheduled (cron-style)

Use Claude Code's `CronCreate` tool to schedule rounds at specific
times:

```
Create a cron trigger that runs `/senkani-autonomous` every day at
02:00 local time until the backlog empties.
```

Each scheduled fire is a fresh Claude Code session, so context is
cleared between rounds by construction.

## Safety rails

1. **`in_flight` lock.** Top of the YAML. If a round crashes mid-way,
   the lock stays set. The next round's skill refuses to start until
   an operator clears it (set `in_flight: null` + mark the stuck item
   `status: skipped` with a note).
2. **Fresh-context discipline.** The skill explicitly exits after one
   round. The shell driver invokes a new `claude` session per round.
   Don't chain rounds in one Claude session — stale context leaks.
3. **Abort paths.** Skill marks items `status: skipped` and exits
   cleanly when: build fails with ambiguous root cause, pre-audit
   reveals item is already shipped, unforeseen blocker surfaces, or
   round exceeds ~60 minutes.
4. **Doc-sync gate.** A round only marks an item `done` if docs are
   synced. Missing docs → item stays `in_progress` (and the lock
   blocks the next round) until the operator intervenes.
5. **No broken commits.** The skill is instructed to revert source
   changes before exiting if tests fail. Backlog-state commits are
   separate and always safe.

## Adding items

Append to `spec/autonomous-backlog.yaml`:

```yaml
  - id: <kebab-case-id>
    title: "Human-readable one-liner"
    status: pending
    size: small | medium | meaty
    roster: [Torvalds, Jobs, ...]        # Luminary members for the round
    scope: |
      Prose describing what's in and what's deferred.
    acceptance:
      - Concrete, verifiable criteria
    blocked_by: [other-item-id, ...]    # optional
    tests_target: <integer>             # rough expectation
    notes: |
      Optional background, links, caveats.
```

New items MUST have `status: pending`. Never mutate existing items'
status by hand while a round is in flight.

## Invariants

- **One round = one item shipped.** If it takes more, the round was
  mis-scoped — operator splits the item.
- **Backlog is the handoff medium.** Everything a future round needs
  to know about a past round lives in `spec/autonomous-backlog.yaml`
  (moved to `completed:`) or in the docs that the round synced.
- **Docs are always current.** If a round ships green, README,
  CHANGELOG, roadmap, spec/*, index.html, and manual-log all reflect
  the new state before the next round begins.
