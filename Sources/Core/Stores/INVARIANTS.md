# SessionDatabase store invariants

The compatibility façade `SessionDatabase` (`Sources/Core/SessionDatabase.swift`)
delegates to four extracted stores under this directory:

| Store              | File                  | Tables owned end-to-end                                    |
|--------------------|-----------------------|------------------------------------------------------------|
| `CommandStore`     | `CommandStore.swift`  | `sessions`, `commands`, `commands_fts` + FTS5 triggers     |
| `TokenEventStore`  | `TokenEventStore.swift` | `token_events`, `claude_session_cursors`                |
| `SandboxStore`     | `SandboxStore.swift`  | `sandboxed_results`                                        |
| `ValidationStore`  | `ValidationStore.swift` | `validation_results`                                     |

The façade itself retains `event_counters`, schema/version orchestration,
and the cross-store composition reads documented below.

The split was shipped under the `sessiondb-split-2` … `sessiondb-split-6`
rounds (Luminary P2-11, 2026-04-20 → 2026-04-24). Before adding a fifth
store, or before splitting `KnowledgeStore` / `LearnedRulesStore` along
the same pattern, read this doc — it is the rule-set the split rounds
discovered and is now the contract for the next ones.

## I1 — One connection, one queue, store-private writes

**Rule.** Every store shares the parent's `db` handle and the parent's
serial dispatch queue (`parent.queue`, label
`com.senkani.sessiondb`). Stores **must not** open a second SQLite
handle and **must not** dispatch onto their own queue. All reads and
writes flow through `parent.queue.sync` or `parent.queue.async`.

**Why.** SQLite's WAL mode tolerates concurrent readers but a single
process should still funnel writes through one mutex; the serial
queue *is* that mutex. It is also what makes single-statement writes
across stores globally ordered without explicit `BEGIN` — see I2.

**Tests.**
- `Tests/SenkaniTests/SessionDatabaseTests.swift::twoProjectsGetSeparateStats`
  exercises a shared connection across stores in one process.
- `Tests/SenkaniTests/CommandStoreTests.swift::fts5SyncPreservesConsistencyUnderSerialWrites`
  proves the serial-queue ordering keeps `commands_fts` consistent
  with `commands` under back-to-back writes.

## I2 — `BEGIN IMMEDIATE` is reserved for multi-statement writes

**Rule.** Today exactly one method wraps work in an explicit
transaction:

- `CommandStore.recordCommand` — `BEGIN IMMEDIATE` …
  `INSERT INTO commands` (which fires the FTS5 triggers) …
  `UPDATE sessions` … `COMMIT` / `ROLLBACK on defer`. The boundary
  is load-bearing because search results would otherwise be visible
  before the session aggregate row updates, and aggregates would
  drift from the base table if the second statement failed.

Every other write today is a single statement and relies on the serial
queue (I1) for global ordering. That is the **only** correct shape
for new single-statement writes.

**Cross-store transactions are currently forbidden.** No method in the
façade or in any store opens a transaction that spans two stores'
tables. If a future feature genuinely needs one (e.g. "delete a
session and all its sandboxed results in one atomic step"), it must
be added with:

1. A new method on the façade (not on a store).
2. An explicit `BEGIN IMMEDIATE` … `COMMIT` issued through
   `parent.queue.sync`.
3. A test that proves rollback under a forced second-statement
   failure.

Do not let cross-store transactions leak into a store class — the
store is allowed to assume it owns its tables.

**Tests.**
- `Tests/SenkaniTests/CommandStoreTests.swift::recordCommandUpdatesSessionAggregates`
  asserts the post-commit invariant (commands inserted ⇒ session
  aggregates updated).
- `Tests/SenkaniTests/CommandStoreTests.swift::fts5SyncPreservesConsistencyUnderSerialWrites`
  asserts FTS5 sync inside the same boundary.

## I3 — Public-API byte-identity (the façade contract)

**Rule.** Every public method exposed before the split must keep its
signature, semantics, and observable behavior. Callers stay on
`SessionDatabase.shared.<method>(…)`. Forwarders live in the four
`SessionDatabase+*API.swift` extension files. No callsite outside the
`Sources/Core/Stores/` directory and `SessionDatabase*.swift` may
reference a store type directly — `CommandStore`, `TokenEventStore`,
`SandboxStore`, `ValidationStore` are `internal` for that reason.

**Why.** The split is a refactor, not a redesign. AutoValidate,
HookRouter, MCPSession, `senkani` CLI subcommands, and the GUI panes
were all written against the pre-split surface. Any deviation is a
silent behavior change that bypasses code review.

**Tests.**
- `Tests/SenkaniTests/SessionDatabaseTests.swift` — the entire file
  is the legacy-API conformance suite, exercised against the post-
  split façade.
- `Tests/SenkaniTests/MCPSessionTests.swift` and
  `AutoValidateTests.swift` — real callers run unchanged against the
  façade.

## I4 — Project isolation: `project_root` filter on every cross-project read

**Rule.** Every read that aggregates across sessions for a single
project **must** filter by `project_root` (normalized via
`SessionDatabase.normalizePath`). The two tables that carry
`project_root` directly are:

- `sessions.project_root` (added by `CommandStore` migration)
- `token_events.project_root` (column on the base schema)

Cross-store reads on the façade — `lastExecResult`,
`lastSessionActivity`, `tokenStatsByAgent`, `complianceRate` —
each take `projectRoot` as the first scoping argument and apply
the filter explicitly.

**Asymmetry — known and intentional.** `sandboxed_results` and
`validation_results` carry `session_id` only; they do **not** carry
`project_root`. They are session-scoped (24-hour retention,
session-keyed advisories) and the existing surface never asks
"all sandboxed results for project X". If a future feature needs
project-scoped reads on those tables, prefer joining through
`sessions.project_root` rather than denormalizing — and add a test
that proves another project's session never leaks.

`event_counters` carries `project_root` as its primary key half;
process-global events are stored under `project_root = ""`. Callers
must pass `""` explicitly to read process-global counters.

**Tests.**
- `Tests/SenkaniTests/SessionDatabaseTests.swift::nullProjectRootDoesNotContaminateNamedProjects`
  guards token-event project isolation.
- `Tests/SenkaniTests/SessionDatabaseTests.swift::twoProjectsGetSeparateStats`
  guards the same on aggregate reads.
- `Tests/SenkaniTests/SessionDatabaseTests.swift::trailingSlashNormalized`
  and the surrounding normalization tests guard
  `normalizePath`'s correctness.
- **Gap:** `complianceRate` and `lastExecResult` have no direct
  tests for project isolation. Filed as a follow-up in
  `spec/cleanup.md`.

## I5 — `token_events` is the single source of truth, with one writer

**Rule.** `token_events` has exactly **one** writer: `TokenEventStore`.
Reads happen from three places, by design:

- `TokenEventStore` itself — every `token_events`-only analytics
  read (`tokenStatsForProject`, `liveSessionMultiplier`,
  `recentTokenEvents`, `hotFiles`, `pruneTokenEvents`, …).
- `SessionDatabase` (the façade) — only when the read joins
  `token_events` against another store's table. Today those are
  `lastExecResult` (× `commands`), `lastSessionActivity` (×
  `sessions`), `tokenStatsByAgent` (× `sessions`),
  `complianceRate` (token_events alone but expressed as a
  hook-vs-MCP aggregate that's not meaningfully owned by one
  store).
- `SessionDatabaseExport` — read-only, redaction-aware, single-
  shot dump for `senkani export` and tests.

**Why.** Multiple writers would race the timestamp/cursor invariants
that downstream readers depend on (compound-learning H+2 patterns,
the live-session multiplier gate, the timeline pane). Multiple
writers would also force a per-row source-of-truth tag, which the
existing `source` column intentionally does not provide.

**Tests.**
- `Tests/SenkaniTests/TokenEventStoreTests.swift::recordTokenEventPersistsAllFields`
  pins the writer surface.
- `Tests/SenkaniTests/TokenEventStoreTests.swift::recordHookEventLandsInTokenEventsWithHookSource`
  pins the hook-event path that uses the same writer.
- `Tests/SenkaniTests/AgentTrackingTests.swift::tokenStatsByAgentGroupsCorrectly`
  pins a representative cross-store JOIN read.

## I6 — Persistence redaction is mandatory at every disk-bound write

**Rule.** Any column that carries agent-supplied or shell-supplied
text must pass through `PersistenceRedaction.redact` (or its
`redactedString` variant) before binding. The three writers that
honor this contract today are:

- `CommandStore.recordCommand` — `command` and `output_preview`.
- `TokenEventStore.recordTokenEvent` — `command`.
- `SandboxStore.storeSandboxedResult` — `command` and the full
  output (and the line/byte counts are computed from the
  **redacted** form so retrieval matches the summary).

`ValidationStore` does not redact `raw_output` today because the
output is structured validator stderr, not agent-supplied prose;
add redaction if the validator surface ever broadens to capture
arbitrary command output.

`CommandStore.recordCommand` also bumps the
`security.command.redacted` counter on the `event_counters` table
when the redactor matches, so `senkani stats --security` can show
the rate.

**Tests.**
- `Tests/SenkaniTests/CommandStoreTests.swift::recordCommandRedactsSecrets`.
- `Tests/SenkaniTests/SandboxStoreTests.swift` round-trip tests
  verify that retrieved output matches the redacted-on-write form.
- See also `Tests/SenkaniTests/PersistenceRedactionTests.swift`
  for the redactor itself.

## I7 — Logging contract: `db.<scope>.<outcome>` only

**Rule.** Every DB-init / SQL-error path inside the façade and the
four stores emits through `Logger.log` using the
`db.<scope>.<outcome>` event vocabulary — never `print(...)`. Stable
event names are `db.session.open_failed`,
`db.session.migrations_applied`, `db.session.migration_failed`,
`db.command.sql_error`, `db.sandbox.sql_error`,
`db.validation.sql_error`. Each event tags `outcome=success|error`.
Open events also tag `mode=default|test` and use `LogValue.path(...)`
for the DB path so home-directory prefixes are redacted at emit
(Cavoukian C2).

**Why.** A `print` from a daemon-side store leaks into stdout, which
is the MCP wire protocol — exactly the regression that Lesson #N
caught.

**Tests.**
- `Tests/SenkaniTests/LoggerRoutingTests.swift::sourceHasNoLegacyPrintInScopedFiles`
  fails the build if any of those files reintroduces a
  `print("[Component] …")` line.

## I8 — Cache-key conventions for the future store splits

The current `Sources/Core/Stores/` stores do **not** maintain
content-keyed caches. The convention exists in `IndexEngine.swift`,
`HookRouter.swift`, `KBLayer1Coordinator.swift`, and
`ProjectFingerprint.swift`, where it is:

- File-content cache key = **path + mtime**
  (`hashes[file] = "<size>-<mtime_seconds>"` in `IndexEngine`,
  `attrs[.modificationDate]` checks in `HookRouter` and
  `SessionBriefGenerator`).
- Project-scope cache key = **max source mtime under the project root**
  (`ProjectFingerprint` walks the tree because directory mtime is
  unreliable on macOS — see the comment block at the top of
  `Sources/Core/ProjectFingerprint.swift`).
- Command-result cache key = **command_hash + input file mtimes**
  is the convention reserved for upcoming `KnowledgeStore` /
  `LearnedRulesStore` splits.

When `KnowledgeStore` (929 LOC) and `LearnedRulesStore` (844 LOC) are
split, every sub-store that caches must (1) include path + mtime in
the key, (2) use `ProjectFingerprint` for project-scope keys (never
the directory mtime), and (3) document the key shape next to the
table schema.

## I9 — Schema migrations belong to the façade

**Rule.** `MigrationRunner.run` is invoked exactly once, by
`SessionDatabase.runMigrations`, after all stores have called their
`setupSchema`. Stores own `CREATE TABLE IF NOT EXISTS` and idempotent
`ALTER TABLE` for their tables only. Cross-store schema changes (a
new index that joins two tables, a column that affects two stores)
must land as a numbered migration in
`Sources/Core/Migrations.swift`, not as an `execSilent` ALTER inside
a store's `setupSchema`.

**Why.** The version stamp on the DB (`PRAGMA user_version`) is what
`senkani doctor` reports and what the migration kill-switch
lockfile checks. A store-local schema bump that doesn't land as a
numbered migration leaves the DB in a state that can't be diagnosed
or rolled forward.

**Tests.**
- `Tests/SenkaniTests/SessionDatabaseTests.swift` — "Opening same DB
  twice runs migrations twice without crash".
- `Tests/SenkaniTests/CommandStoreTests.swift::schemaSurvivesReopen`.

---

## Appendix — store-by-store quick reference

```
CommandStore
  Tables       : sessions, commands, commands_fts (+3 FTS5 triggers)
  project_root : sessions.project_root (filter on every cross-session read)
  Transactions : recordCommand wraps INSERT commands + UPDATE sessions
  Redaction    : command, output_preview
  Notes        : commands_fts is the only FTS5 surface. Triggers AI/AD/AU
                 keep it in sync; do not add a parallel writer to commands
                 without re-checking the trigger contract.

TokenEventStore
  Tables       : token_events, claude_session_cursors
  project_root : token_events.project_root (single source of truth — see I5)
  Transactions : single-statement writes, serialized via parent.queue
  Redaction    : command
  Notes        : The 90-day prune (pruneTokenEvents) is the only retention
                 policy for analytics history. Cursors are per-path, not
                 per-session — that's deliberate so a stopped session
                 doesn't lose its place.

SandboxStore
  Tables       : sandboxed_results
  project_root : NOT carried (session-scoped — see I4 asymmetry note)
  Transactions : single-statement, serialized via parent.queue
  Redaction    : command, full_output (line/byte counts post-redaction)
  Notes        : 24-hour prune via RetentionScheduler. ID format is
                 `r_<12-hex>` so the MCP tool stream can return a
                 compact retrieval pointer.

ValidationStore
  Tables       : validation_results
  project_root : NOT carried (session-scoped — see I4 asymmetry note)
  Transactions : single-statement, serialized via parent.queue
  Redaction    : NOT applied to raw_output today (validator stderr is
                 structured, not agent prose). Revisit if scope broadens.
  Notes        : `surfaced_at` is the source of truth for "this advisory
                 was already shown"; `delivered` stays for legacy UI.
```

---

## Appendix — coverage gaps tracked in `spec/cleanup.md`

- `SessionDatabase.complianceRate` has no direct test — the file uses
  it indirectly through MCP/hook flows.
- `SessionDatabase.lastExecResult` has no direct test — it is a
  cross-store JOIN that should have a unit test pinning project
  isolation, missing-row, and the `output_preview ABS(timestamp - ?) < 2.0`
  fuzziness.

These are tracked as follow-ups under "SessionDatabase store
coverage gaps" in `spec/cleanup.md`.
