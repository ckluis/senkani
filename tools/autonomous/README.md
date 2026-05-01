# Senkani autonomous development loop

Continuous plan → build → test → re-audit → doc-sync cycles driven by
a tiered backlog tree under `spec/autonomous/`.

## Components

- **`spec/autonomous.md`** — the router. Tree shape, status vocabulary,
  type taxonomy, common path. Start here.
- **`spec/autonomous/PROCESS.md`** — operational handbook. Per-round
  playbook, status transitions, doc-sync rules, index regeneration,
  quality gates.
- **`spec/autonomous/backlog/<id>-<slug>.md`** — one file per open /
  blocked / manual / in-progress item. Frontmatter carries state;
  body has scope, acceptance, notes.
- **`spec/autonomous/completed/<YYYY>/<YYYY-MM-DD>-<id>-<slug>.md`** —
  one file per shipped item, year-grouped, date-prefixed for ls-
  sortability.
- **`spec/autonomous/_state.yaml`** — live skill state (`in_flight`
  pointer, schema version). Hand-edit ONLY when no round is running.
- **`spec/autonomous-manifest.yaml`** — tells the skill where the
  tree lives, where doc-sync targets are, what process doc to use.
- **`~/.claude/skills/senkani-autonomous/SKILL.md`** — per-round
  playbook. Invoked via `/senkani-autonomous`.
- **`tools/autonomous/run-rounds.sh`** — unattended driver.
- **`tools/autonomous/migrate.py`** — one-shot migrator from the
  legacy single-file YAML to the v2 tiered tree.
- **`tools/autonomous/roundtrip.py`** — verifier; asserts the new
  tree round-trips against the legacy YAML and that every roadmap +
  cleanup heading is accounted for.

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
times. Each scheduled fire is a fresh Claude Code session, so context
is cleared between rounds by construction.

## Safety rails

1. **`in_flight` lock** lives in `spec/autonomous/_state.yaml`. If a
   round crashes mid-way, the lock stays set. The next round's skill
   refuses to start until an operator clears it.
2. **Fresh-context discipline.** The skill explicitly exits after one
   round. The shell driver invokes a new `claude` session per round.
3. **Abort paths.** Skill marks items `status: skipped` and exits
   cleanly when: build fails with ambiguous root cause, pre-audit
   reveals item is already shipped, unforeseen blocker surfaces, or
   round exceeds ~60 minutes.
4. **Doc-sync gate.** A round only marks an item `done` if docs are
   synced.
5. **No broken commits.** The skill reverts source changes before
   exiting if tests fail.
6. **Index files are derived.** `backlog/index.md` and
   `completed/index.md` are regenerated on every close. Never hand-
   edit; the next round's close will silently overwrite.

## Adding items

Copy the template:

```bash
cp spec/autonomous/_template.md spec/autonomous/backlog/<id>-<slug>.md
```

Edit the frontmatter (`id`, `title`, `status: open`, `type`, `size`,
`roster`, `affects`, `blocked_by`) and the body sections (`## Scope`,
`## Acceptance`, `## Notes`). See `spec/autonomous/PROCESS.md` for
the full per-item shape.

## Migration (v1 → v2 tree, 2026-05-01)

The legacy single-file backlog at `spec/autonomous-backlog.yaml` plus
the standalone `spec/roadmap.md` and `spec/cleanup.md` were folded
into `spec/autonomous/` on 2026-05-01.

```bash
# Run the migrator (idempotent; refuses to overwrite a non-empty
# spec/autonomous/ unless --force is passed).
python3 tools/autonomous/migrate.py spec

# Verify zero data loss before renaming the legacy files.
python3 tools/autonomous/roundtrip.py spec
# Both passes must exit 0 before deleting the legacy.

# After verifier is green, rename the originals (the manual step):
mv spec/autonomous-backlog.yaml spec/autonomous-backlog.yaml.legacy
mv spec/roadmap.md              spec/roadmap.md.legacy
mv spec/cleanup.md              spec/cleanup.md.legacy
```

The `.legacy` files stay in place until the next release ships
clean, then can be deleted. The verifier can be re-run against the
preserved `.legacy` file at any time as a sanity check.

Migration script is idempotent — re-running on an already-migrated
tree refuses to overwrite without `--force`.

## Invariants

- **One round = one item shipped.** If it takes more, the item was
  mis-scoped — operator splits.
- **Per-item files are the canonical source of truth.** Indexes are
  derived; `_state.yaml` carries only live lock state.
- **Docs are always current.** If a round ships green, README,
  CHANGELOG, phase files, subsystem specs, index.html, docs/, and
  manual-log all reflect the new state before the next round begins.
