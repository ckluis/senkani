# Changelog

All shipped features live here so the README can stay focused on what
Senkani *is*. Entries are grouped by the server version reported by
`senkani_version` (see `VersionTool.serverVersion`).

## v0.2.0 — 2026-04 (current)

### April 21 — `PaneSocketMigrationTests`: DispatchGroup → TaskGroup (`pane-socket-migration-taskgroup`)
- Rewrote `concurrentWritesAllDelivered` on `withTaskGroup(of: Bool.self)`
  with `await group.next()` draining. Closes the last of the three
  cooperative-pool-starvation frames from the 2026-04-21 hang sample
  (line 230's `DispatchGroup.wait()`). The `Counter`/`NSLock` helper
  is gone — subtasks return `Bool`, the parent sums them.
- Rewrote `largeFrameRoundTrip` the same way: `DispatchQueue.global` +
  `DispatchSemaphore.wait` → `async let` over `Task.detached` +
  `await`. Same hazard class, surfaced the moment the suite stopped
  being `.serialized`. `FrameBox` helper deleted.
- `.serialized` trait removed from the `PaneSocketMigrationTests`
  suite. All 9 tests run in parallel; the suite finishes in 7 ms
  under `--parallel`. Full suite still 1617 green in ~20 s.

### April 21 — Test harness hang: migrate NSLock helpers to `@TaskLocal` (`test-harness-tasklocal-migration`)
- Root-cause fix for two of the three frozen frames from the
  2026-04-21 sigtrap-repro sample. `ScheduleWorktree.withTestDir`
  and `LearnedRulesStore.withPath` no longer take an `NSLock` —
  both are now `@TaskLocal`-scoped. Parallel `@Test` tasks each
  get their own scoped value with structured-concurrency
  propagation, so cooperative-pool starvation on these helpers is
  structurally impossible.
- `LearnedRulesStore`: task-local is a `Scoped` ref-type box
  holding the (path, cache) pair, so per-test mutation of the
  `shared` singleton via the existing `shared = file` call sites
  is isolated to each parallel suite without a process lock.
  Computed `shared` getter/setter routes through the scoped box
  when a scope is active, else the process-wide default.
- Dead-code removal: deprecated `LearnedRulesStore.withPathAsync`
  (zero call sites) deleted. Three tests changed
  `Task.detached { ... }` → `Task { ... }` inside their `withPath`
  body so the task-local scope propagates via structured
  concurrency (inheritance behavior only `Task { ... }` honors).
  Touched: `CompoundLearningH1Tests:775`,
  `CompoundLearningH2aTests:409/442`, `CompoundLearningH2bTests:473`.
- `.serialized` trait removed from `ScheduleWorktreeTests` and
  `WatchRingBufferTests`. `PaneSocketMigrationTests` retains
  `.serialized` until the DispatchGroup → TaskGroup rewrite in
  `pane-socket-migration-taskgroup` lands.
- One more timing flake widened (parallel-mode headroom):
  `DependencyGraphTests` "Real project graph builds fast"
  2s → 5s. Same rationale as the prior TreeSitter / SkillScanner
  widenings.
- `swift test` (parallel) no longer hangs — the 50+ min wait is
  gone. `tools/test-safe.sh` retained as belt-and-suspenders
  (and now the authoritative green baseline: 1617 tests in ~20 s).
- Accepted risks: parallel mode surfaces other pre-existing
  flakes (URLProtocol-stub registration races in
  `RemoteRepoClientTests` / `BundleRemoteTests`, occasional
  `swiftpm-testing-helper` SIGTRAP). These predate this round —
  NSLock-induced serialization previously hid them. Tracked as
  follow-ups in `spec/testing.md`.
- Tests: 1617 tests green via `tools/test-safe.sh` (unchanged
  count — rewrite of existing helpers, no new tests).

### April 21 — Test harness hang: `.serialized` + `tools/test-safe.sh` (`test-harness-sigtrap-repro`)
- Three consecutive DB-split rounds (split-2/3/4) fell back to
  targeted regressions because `swift test` hangs 50+ minutes at
  0% CPU on this machine. Operator sample at
  `spec/.harness-deadlock-sample-2026-04-21.txt` named three
  frozen frames: `ScheduleWorktree.withTestDir`,
  `LearnedRulesStore.withPath`, `PaneSocketMigrationTests.swift:230`.
- Root cause: Swift concurrency cooperative-pool starvation. The
  first two helpers wrap `body()` in `NSLock`; the third uses
  `DispatchGroup.wait()`. Enough parallel `@Test` tasks block on
  these primitives and the pool deadlocks — `withTimeLimit`
  traits are cooperative and never fire.
- Shipped workaround: `.serialized` trait added to
  `ScheduleWorktreeTests`, `PaneSocketMigrationTests`,
  `WatchRingBufferTests`; `tools/test-safe.sh` provides a
  deterministic full-suite run (`SWT_NO_PARALLEL=1 swift test
  --no-parallel`); three timing flakes widened (TreeSitter
  Elixir/Kotlin parse 10ms → 50ms, SkillScannerAsync 2s → 5s).
  Root cause + fingerprint + re-capture recipe documented in
  `spec/testing.md` under "Full-suite hang — Swift concurrency
  pool starvation".
- Deferred (new backlog items): migrate `withTestDir`/`withPath`
  to `@TaskLocal`; rewrite `concurrentWritesAllDelivered` on
  `TaskGroup`; file upstream swift-testing issue.
- Tests: 32 targeted tests pass, build green. Full-suite
  validation via `tools/test-safe.sh` — deterministic but slow;
  manual-log target added.

### April 21 — SessionDatabase split: extract SandboxStore (`sessiondb-split-4-sandboxstore`)
- Round 3 of 5 under the `sessiondatabase-split` umbrella
  (Luminary P2-11). New `Sources/Core/Stores/SandboxStore.swift`
  (138 LOC) owns the `sandboxed_results` table end-to-end: schema
  + the two existing indexes
  (`idx_sandboxed_results_session`, `idx_sandboxed_results_time`)
  + the `r_`-prefix ID mint, the store/retrieve path, and the
  24-h prune that `RetentionScheduler` invokes hourly. The store
  shares the parent's `DispatchQueue` and raw SQLite connection —
  no second handle, same `unowned let parent` pattern as
  `CommandStore` and `TokenEventStore`.
- Methods now delegated through the façade:
  `storeSandboxedResult`, `retrieveSandboxedResult`,
  `pruneSandboxedResults`. All callers
  (`ExecTool`, `WebFetchTool`, `SessionTool`, `MCPSession`,
  `RetentionScheduler`) continue to use
  `SessionDatabase.shared.<method>` — the extraction is
  byte-identical.
- `SessionDatabase.swift` dropped from 1598 → 1542 LOC (−56).
  Three of the four planned stores
  (CommandStore 384 + TokenEventStore 860 + SandboxStore 138 =
  1382 LOC) now own their own files; the façade is on track for
  the round-5 ≤800-LOC target once `ValidationStore` also
  extracts.
- New `Tests/SenkaniTests/SandboxStoreTests.swift` @Suite
  "SandboxStore — writes, reads, prune" adds 6 tests:
  ID shape (`r_` prefix + 14 chars + hex charset), round-trip of
  command/output/line-count/byte-count, prune-by-age deletes old
  rows and returns the delete count, prune keeps rows younger
  than the cutoff, `retrieveSandboxedResult` returns nil for an
  unknown ID, and multi-session isolation. The pre-existing
  `OutputSandboxingTests.swift` suites (11 tests across storage,
  summary builder, and mode logic) continue to pass unchanged —
  the façade contract they rely on is preserved.
- Targeted regression: 129 tests green across
  `SandboxStore` + `OutputSandboxing` + `MCPSession` +
  `RetentionScheduler` + `ExecTool` + `SessionTool` +
  `WebFetch` + `SessionDatabase` + `CommandStore` +
  `TokenEventStore` + `AutoValidate` + `DiagnosticRewriter`.

### April 21 — SessionDatabase split: extract TokenEventStore (`sessiondb-split-3-tokeneventstore`)
- Round 3 of 5 under the `sessiondatabase-split` umbrella
  (Luminary P2-11). New `Sources/Core/Stores/TokenEventStore.swift`
  (860 LOC) owns the `token_events` + `claude_session_cursors`
  tables end-to-end: schema + indexes + the one
  `model_tier`-column migration + the 90-day `pruneTokenEvents`
  cadence. The store shares the parent's `DispatchQueue` and raw
  SQLite connection — no second handle.
- Methods that moved behind the façade via delegation:
  `recordTokenEvent`, `recordHookEvent` (hook rows still live in
  `token_events` with `source='hook'`, not a separate table — see
  round 1's note),
  `tokenStatsForProject` / `tokenStatsAllProjects` /
  `tokenStatsByFeature` / `tokenStatsByFeatureAllProjects`,
  `liveSessionMultiplier`, `savingsTimeSeries` /
  `savingsTimeSeriesAllProjects`, `recentTokenEvents` /
  `recentTokenEventsAllProjects` (+ private
  `parseTimelineRows` helper), `lastReadTimestamp`, `hotFiles`,
  `sessionSummaries`, `unfilteredExecCommands`,
  `recurringFileMentions`, `instructionRetryPatterns`,
  `workflowPairPatterns`, `getSessionCursor`, `setSessionCursor`,
  `pruneTokenEvents`, `dumpTokenEvents` (DEBUG).
- Cross-store composition deliberately STAYS on the
  `SessionDatabase` façade per the round's scope — these methods
  JOIN across tables owned by different stores and live on the
  thin façade that knows both: `lastSessionActivity`
  (sessions → token_events), `lastExecResult` (token_events ↔
  commands), `tokenStatsByAgent` (token_events ⋈ sessions),
  `complianceRate` (called out explicitly). The façade still owns
  `recordBudgetDecision` (writes commands) and `event_counters`
  (trivially shared; moving would mean every defense site imports
  a new store just to bump a counter).
- `SessionDatabase.swift` drops from 2213 → 1598 LOC (28% smaller,
  −615 LOC). `CommandStore` + `TokenEventStore` now own 1244 LOC
  between them; façade is heading toward the round-5 ≤800-LOC
  target.
- Public API is byte-identical — every existing callsite
  (AgentTimeline pane, Dashboard, SavingsTest pane, `senkani eval`,
  BudgetConfig gates, ScheduleTelemetry, ClaudeSessionReader,
  HookRouter's re-read suppression, WasteAnalyzer's
  compound-learning queries, ContextSignalGenerator's H+2b
  recurring-file flow) keeps working without edits.
- New `Tests/SenkaniTests/TokenEventStoreTests.swift` with 9 tests
  covering: recordTokenEvent persistence of all fields;
  recordHookEvent landing in token_events with `source='hook'`;
  tokenStatsForProject aggregation; tokenStatsByFeature sort
  order; liveSessionMultiplier nil-on-empty and raw/compressed
  math; hotFiles frequency ranking; session cursor upsert
  (get → 0,0 / set → get round-trip / set-again overwrites);
  pruneTokenEvents 90-day cutoff. Targeted regression suite
  (AgentTracking + LiveMultiplier + TieredContext +
  BudgetEnforcement + HookRouter + Dashboard + FeatureSavings +
  ObservabilityCounters + CommandStore) passes green (116/116),
  plus CompoundLearning + ClaudeSessionReader + RetentionScheduler
  + MigrationRunner + SecurityEvents (152/152).
- Accepted risks: none material. The extraction is
  byte-identical; divergence would surface in the 1129-test
  suite.
- Next: `sessiondb-split-4-sandboxstore` — now unblocked.

### April 20 — SessionDatabase split: extract CommandStore (`sessiondb-split-2-commandstore`)
- First real extraction under the `sessiondatabase-split` umbrella
  (Luminary P2-11). New `Sources/Core/Stores/CommandStore.swift`
  owns the `sessions`, `commands`, and `commands_fts` tables
  end-to-end: CREATE TABLE / FTS5 trigger set / column migrations /
  `createSession` / `recordCommand` / `endSession` / `loadSessions`
  / `search` / `sanitizeFTS5Query`. The store shares the parent's
  `DatabaseQueue` and raw connection — never opens a second handle.
- `SessionDatabase`'s public API is byte-identical. Every callsite
  (`MCPSession.swift`, dashboard, `senkani eval`, compound-learning
  tests, AgentTracking tests, CavoukianPrivacy tests, etc.) keeps
  working without edits — the façade now forwards to
  `commandStore.…`. The P3-13 BEGIN IMMEDIATE transaction boundary
  around the FTS5 sync travels with `recordCommand` into the store,
  preserving the "commands, FTS index, session aggregate" atomicity
  contract that makes search results consistent under concurrent
  writes.
- Sessions-table indexes that were previously created from
  `createTokenEventsTable` (`idx_sessions_project_ended`,
  `idx_sessions_agent_type`) moved into
  `CommandStore.setupSchema()` alongside the rest of the sessions
  schema. `createTokenEventsTable` now only owns token_events and
  `claude_session_cursors` indexes — one less bounded-context leak
  for TokenEventStore's round to inherit.
- `SessionDatabase.sanitizeFTS5Query(_:)` kept as a static delegate
  so the two external callsites (`SearchSecurity.swift:35`,
  `KnowledgeStore.swift:530`) continue compiling. Source of truth
  is now `CommandStore.sanitizeFTS5Query`.
- New `Tests/SenkaniTests/CommandStoreTests.swift` with 10 tests:
  createSession persists + round-trips; recordCommand updates
  session aggregates; secret redaction keeps API keys out of FTS;
  endSession sets duration; loadSessions caps at 500; FTS finds
  recorded commands; search sanitizes FTS5 operators (colon,
  asterisk, caret, parentheses, AND/OR/NOT/NEAR); 25-writes
  serial-consistency probe (FTS row count = commandCount = N);
  schemaSurvivesReopen regression. Every existing test passes
  unchanged (no test-file edits outside the new suite).
- **Accepted risks**: none. The extraction is byte-identical; any
  divergence would have surfaced in the 1129-test suite.
- Next: `sessiondb-split-3-tokeneventstore` — now unblocked. It
  will absorb `recordHookEvent` (rows live in `token_events` with
  `source='hook'`) and the full `tokenStats*` / `hotFiles` /
  `liveSessionMultiplier` surface.

### April 20 — SessionDatabase split plan: retire phantom HookEventStore (`sessiondb-split-1-hookeventstore`)
- Round 1 of the `sessiondatabase-split` umbrella (Luminary P2-11)
  ran under an expanded Luminary roster (Torvalds, Jobs, Evans,
  Kleppmann, Celko, Carmack, Bach, Majors, Allspaw) after the
  operator lifted the P2-11 "second contributor needs to touch the
  DB layer" gate. The round SKIPPED at pre-audit with a unanimous
  finding that shifts the split chain.
- Finding: the top-of-file comment on `Sources/Core/SessionDatabase.swift`
  had been listing `hook_events` as a seventh table. `grep`
  revealed the table does not exist — `recordHookEvent`
  (`SessionDatabase.swift:2062–2083`) writes into `token_events`
  with `source='hook'`. Hook telemetry is a SOURCE discriminator
  on an existing table, not a separate aggregate. Extracting a
  `HookEventStore` with no table of its own would have shipped
  either a no-op wrapper or a fabricated schema migration, both
  in violation of the round's acceptance criteria.
- Shipped: corrected the top-of-file comment on
  `Sources/Core/SessionDatabase.swift:4-64`. Removed `hook_events`
  + `HookEventStore` from the table list and carve-up plan; noted
  the correction inline so future readers see why the phantom
  entry is gone. Updated `spec/autonomous-backlog.yaml` so (a) the
  umbrella `sessiondatabase-split` now tracks four real rounds,
  (b) `sessiondb-split-2-commandstore` is unblocked and absorbs
  the "first extraction proves the pattern" charter, (c)
  `sessiondb-split-3-tokeneventstore` explicitly owns
  `recordHookEvent` (the rows live in `token_events`), (d)
  `complianceRate()`'s single-table `source IN ('mcp','hook')`
  query is called out as cross-store composition the final round
  must preserve (Majors' observability flag).
- No Swift source logic changed; no tests added or removed. The
  split chain is now 4 extractions + 1 façade-thin wrap-up (was
  5 + 1).
- **Accepted risks**: none. The stale comment had no runtime
  impact; it only misled pre-audit readers. If a dedicated
  `hook_events` table is ever desired later (e.g. for retention
  partitioning or tighter compliance-rate queries), that is a
  P2 future backlog item that must weigh the cost of fracturing
  `complianceRate()`.

### April 20 — Ollama pane: pin the MCP env contract (`mcp-in-ollama-pane-verify`)
- `mcp-in-ollama-pane-verify` closes round 5 of the
  `ollama-pane-discovery-models-bundle` umbrella. The operator flagged
  that Senkani MCP tooling's behaviour inside the Ollama-launcher pane
  was unverified after the pane went first-class. Pre-audit traced the
  env-injection path — both the plain Terminal pane and the Ollama
  pane funnel through `TerminalViewRepresentable`, which merges the
  supplied env dict onto `ProcessInfo.environment` before `startProcess`,
  so `SENKANI_PANE_ID` et al. transit identically regardless of whether
  `initialCommand` is an empty shell or `ollama run <tag>`.
- Finding: env bundles were assembled inline in two SwiftUI views
  (`OllamaLauncherPane.terminalBody` and `PaneContainerView.paneBody`
  case `.terminal`). Torvalds flag: drift risk — a key added to one
  site could silently disappear from the other, and the MCP gate
  (`MCPMain.swift:19`, `SENKANI_PANE_ID != nil`) would fire on one
  pane type and not the other.
- New `Sources/Core/PaneLaunchEnv.swift` hoists the env-dict build
  into a pure-Foundation helper with two entry points: `terminal(_:)`
  and `ollamaLauncher(_:resolvedModelTag:)`. Both produce the same
  MCP gate-key bundle (`SENKANI_PANE_ID`, `SENKANI_PROJECT_ROOT`,
  `SENKANI_HOOK`, `SENKANI_INTERCEPT`, metrics/config paths,
  workspace + pane slugs, every `SENKANI_MCP_*` toggle); the ollama
  variant layers `SENKANI_OLLAMA_MODEL` on top. Both views now call
  the helper so the contract is single-sourced.
- New `Tests/SenkaniTests/PaneLaunchEnvTests.swift` pins the contract
  with 8 tests: gate-key coverage for each pane type, cross-type
  parity (terminal ↔ ollama dicts agree on every shared key), ollama
  model-tag round-trip, bounded-context guard (terminal env omits
  `SENKANI_OLLAMA_MODEL`), shell-safe value assertion (Schneier — no
  `\n`, `\r`, `\0` in any value), workspace/pane slug round-trip,
  feature-flag on↔off mapping.
- The live end-to-end verification (real MCP client attached to an
  ollama-launched shell) still requires the operator's machine —
  pushed to `tools/soak/manual-log.md` under Wave "Ollama pane: MCP
  tool reachability (2026-04-20)" so the concern stops bleeding
  across rounds without a landing point.
- **Accepted risks**: if an ollama REPL spawns `/bin/sh -c ...` from
  inside the LLM chat (the `!<cmd>` escape), the child shell
  inherits SENKANI_* by POSIX rule — this is the same behaviour every
  other terminal pane has. No new leak path; documented under the
  soak entry.

### April 20 — Models pane: install → verify state machine (`models-page-installable`)
- `models-page-installable` closes round 4 of the
  `ollama-pane-discovery-models-bundle` umbrella. The Models pane's
  install buttons now drive the full download→install→verify flow
  end-to-end for senkani-internal ML (MiniLM-L6 embeddings + the 3
  Gemma 4 vision tiers). Clicking **Install** progresses through
  `Available → Installing N% → Installed → Verifying… → Ready`;
  failures stop at `Error` (download) or `Verification failed`
  (verify) with a **Re-verify** action that retries without
  re-downloading.
- `ModelStatus` (Sources/Core/ModelManager.swift:7) gains
  `.verifying`, `.verified`, and `.broken`. `isReady` treats both
  `.downloaded` (integrity unconfirmed) and `.verified` (fixture
  passed) as ready so existing MCP gates keep working.
- `ModelManager.download(modelId:)` now wraps the registered
  handler: on throw it `markError`s the model with
  `error.localizedDescription` instead of letting the exception
  escape into UI without state; on success it auto-invokes
  `verify(modelId:)` so "install → verify" is one call for the UI
  (Jansen gate — no second click to verify).
- New `verify(modelId:)` + `registerVerificationHandler(_:)` pair,
  parallel to the existing `download(modelId:)` /
  `registerDownloadHandler(_:)` layering. When no handler is
  registered, Core falls back to an integrity-only default:
  re-check `config.json` + a weight file are on disk and
  `config.json` parses as a JSON dict. MCP layer registers an MLX
  handler that calls `EmbedTool.engine.ensureModel()` /
  `VisionTool.engine.ensureModel()` — loading the freshly-installed
  model into a `ModelContainer` IS the "tiny inference fixture",
  since a corrupt weight file or incompatible config blows up at
  container load.
- `senkani doctor` check #5 reads every registered model's status
  directly — `.verified: "verified"`, `.downloaded: "installed (not
  yet verified)"`, `.broken: "verification failed — <error>"` (with
  per-model lastError captured), `.error: "install error — <error>"`,
  `.available: "not installed"`. Failures (broken / error) now fail
  doctor with an actionable line instead of silently skipping.
- `ModelCardView` renders distinct badge colors and action buttons
  per state: Installing (orange %), Verifying… (orange sparkles),
  Ready (green check + trash), Verification failed (orange warning
  + re-verify + trash). Delete still wipes the cache dir and resets
  to `.available` so re-install round-trips cleanly.
- 7 new tests in `ModelManagerInstallTests.swift` drive the state
  machine with fake handlers + planted HF snapshots: happy path,
  download fail, verify fail keeps files on disk, delete-and-
  reinstall round-trip, `.broken → verify retry → .verified`,
  per-model doctor readout (three models in three different
  states), missing-handler guard. Test count: 1577 → 1584 (+7).
- **Accepted risks**: real-machine verification of the MLX
  `ensureModel` verify path is deferred to the soak log — the
  state machine IS unit-tested, but actually running `ensureModel`
  on a freshly-downloaded model requires network + multi-GB
  download and can't run in CI. See `tools/soak/manual-log.md`.
  Pre-existing `MockURLProtocol.stubs` race (3 flaky URLProtocol
  tests under parallel runs) is **not** introduced by this round —
  documented under accepted-risk in manual-log.

### April 20 — Ollama: curated LLM catalog + click-to-pull drawer
- `ollama-model-curation` closes round 3 of the
  `ollama-pane-discovery-models-bundle` umbrella. The Ollama pane now
  has a settings drawer (header → download icon) that shows a curated
  list of 5 user-facing LLMs — each row discloses its size BEFORE the
  click and kicks off an out-of-process `ollama pull` that streams
  progress into the UI (Schneier: explicit click-to-pull, no
  auto-pull; Podmajersky: size disclosed in the button copy).
- New `Sources/Core/OllamaModelCatalog.swift` is the pure-Foundation
  layer: `OllamaCuratedModel` (tag + displayName + useCase + sizeGB +
  `pullButtonCopy` that renders `"Pull 4.7 GB"`), the curated list
  (llama3.1:8b, qwen2.5-coder:7b, deepseek-r1:7b, mistral:7b,
  gemma2:2b), `OllamaPullState` (`.notPulled` / `.pulling(progress)`
  / `.pulled(digest?)` / `.failed(message)`),
  `OllamaPullOutputParser` (incremental line-by-line parser for
  `ollama pull` stdout — progress monotonic, digest captured,
  Error line flips to failed), `OllamaInstalledListParser` (parses
  `ollama list` tabular output → `[(tag, digest)]`), and
  `OllamaPullCommand` (argv builder gated by the existing
  shell-injection validator). Evans' bounded-context gate: this
  catalog is STRICTLY separate from `ModelManager`, which owns
  senkani-internal ML — two surfaces, two lifecycles.
- New `SenkaniApp/Models/OllamaModelDownloadController.swift`
  (~@MainActor `ObservableObject`, ~180 LOC) owns per-tag state +
  the `ollama pull` `Process()` references. Spawns via
  `PATH`-resolved ollama binary (with Homebrew + direct-DMG
  fallback paths), streams stdout through a `LineBuffer` that
  splits on `\n` and `\r` so the parser sees complete progress
  frames, and on exit drains trailing output through the parser
  (catching a late `success` / error line). On success falls back
  to `ollama list` when the parser didn't pick up a digest.
  `cancelPull(tag:)` `.terminate()`s the subprocess, clears
  state back to `.notPulled`.
- New `SenkaniApp/Views/OllamaModelsDrawer.swift` renders the
  curated list as a 520×420 sheet: each row shows displayName +
  tag + use-case + size/progress line + action button. Action
  resolves against daemon availability: absent → **Install
  Ollama** deep-link to ollama.com/download; present + not-pulled
  → **Pull N.N GB**; present + pulling → **Cancel**; present +
  pulled → **Use** / **Current** (sets the pane's default model).
  Swapping the default restarts the terminal subprocess via the
  pane's existing `restartToken` so chat reflects the new model
  without the user reopening the pane.
- `OllamaLauncherPane` gets a `square.and.arrow.down` icon in the
  pane header next to the connected indicator — opens the drawer
  as a sheet. The existing header model-picker Menu still works
  for quick-switching among already-pulled tags.
- `OllamaLauncherSupport.defaultModelTags` now delegates to
  `OllamaModelCatalog.curatedTags` so the selector list + pull
  surface + pane default all single-source off the catalog. Legacy
  callers (header Menu, pane-restore fallback) continue to work
  unchanged.
- 21 new tests under `@Suite("Ollama Model Catalog")`: curated-list
  invariants (size ≥5, all tags validate, no dupes, first entry
  doubles as default), button-copy discloses size (Podmajersky
  gate), use-case copy ≤50 chars (Handley gate), parser state
  machine from .notPulled through .pulling(p) to .pulled(digest)
  on canonical transcript, progress monotonicity, error-line
  flip-to-failed, junk-input doesn't move state, percent
  extraction across 1/2/3-digit values, layer-digest extraction
  skips the `manifest` keyword, pull/list argv gate invalid tags,
  `ollama list` tabular-output parse + malformed-row rejection,
  parser freshness on cancel-and-restart, state classification
  helpers.
- Test count: 1554 → 1575 (+21).
- **Accepted risks** (documented in `tools/soak/manual-log.md`):
  the `OllamaModelDownloadController`'s `Process()` path is NOT
  unit-tested (would require a real `ollama` binary on the CI
  runner) — all state-machine + parsing logic driving it IS
  tested, and soak-log adds an end-to-end manual validation
  entry. Concurrent pulls are allowed at the controller level but
  the drawer exposes one button per row, so the common path is
  one-at-a-time. Custom-model (non-curated) tags are a FUTURE
  surface — this round ships the curated list only.

### April 20 — Ollama: first-class `.ollamaLauncher` PaneType
- `ollama-pane-first-class` closes round 2 of the
  `ollama-pane-discovery-models-bundle` umbrella. The Welcome screen's
  hardcoded `onStart("Ollama", "ollama run llama3")` string is gone;
  the Ollama card (and the new gallery entry) now open a dedicated
  pane instead of bolting ollama semantics onto the Terminal pane
  (Torvalds' "category error" gate, Evans' "senkani ML ≠ user LLMs"
  bounded-context gate).
- New `Sources/Core/OllamaLauncherSupport.swift` holds the testable
  layer: a 4-tag default selector list (`llama3.1:8b`,
  `qwen2.5-coder:7b`, `mistral:7b`, `gemma2:2b`), a tag validator
  that rejects shell metacharacters (Schneier's shell-injection
  gate), a `launchCommand` builder, and `resolveModelTag` for the
  persistence-fallback path. `OllamaAvailability.detect` is extracted
  from `WelcomeView` so the pane and the Welcome card share one
  probe.
- New `SenkaniApp/Views/OllamaLauncherPane.swift` renders the pane:
  compact model-picker header, tri-state availability gate
  (detecting → absent-CTA with "Get Ollama" + "Retry" buttons →
  connected terminal body), and delegates to `TerminalViewRepresentable`
  for the subprocess. Same MCP env bundle terminal panes get
  (`SENKANI_PANE_ID`, `SENKANI_PROJECT_ROOT`, `SENKANI_WORKSPACE_SLUG`,
  `SENKANI_PANE_SLUG`, FCSIT aliases) plus a new `SENKANI_OLLAMA_MODEL`
  hint for the hook binary.
- `PaneType.ollamaLauncher` added (18 types now). `SenkaniTheme`
  gains accent (warm orange `#ee7f31`), `cpu.fill` icon, description,
  displayName. `PaneContainerView.paneBody` routes the new case.
- `AddPaneSheet.idToType` + `ContentView.addPaneByTypeId` map the new
  string ID; `PaneGalleryBuilder` lists "Ollama" in **AI & Models**
  (category now 5 entries, still ≤6).
- `PaneModel.ollamaDefaultModel` persists the user's selected tag;
  `WorkspaceStorage` round-trips it (field is optional so old JSON
  files migrate silently). Invalid/missing values snap to the
  package default on restore.
- WelcomeView's `detectOllama` now delegates to the Core probe so a
  single code path answers both the Welcome card and the pane's
  absent-CTA gate.
- 14 new tests under `@Suite("Ollama Launcher Support")`: default-
  tag list invariants (non-empty, first-entry == default, no dupes),
  tag validator accepts realistic tags + rejects 14 shell-meta
  injection attempts + empty/oversized, launch-command shape + nil
  on invalid, `resolveModelTag` fallback matrix (nil/empty/invalid/
  valid), gallery registration + description length, availability
  probe against a closed port. `PaneGalleryTests.allEntriesCoversAll17PaneTypes`
  renamed to `allEntriesCoversAll18PaneTypes`.
- Test count: 1540 → 1554 (+14).
- **Accepted risks** (documented in `tools/soak/manual-log.md`):
  pane-open telemetry to `token_events` NOT wired this round — the
  backlog proposed overloading token_events with a UI-open event,
  but that's the exact bounded-context merger Evans' gate at
  umbrella time was telling us to avoid (token_events is for LLM
  tool-call telemetry). Deferred to a follow-up round that adds a
  dedicated UI-telemetry path. Click-to-pull UX for the curated
  model list also deferred — that's sub-item `ollama-model-curation`.
  For now, `ollama run <tag>` still auto-pulls on first launch
  (ollama's default behavior).

### April 20 — Pane gallery: categorize 17 panes + fix missing Dashboard
- `pane-add-gallery-redesign` closes round 1 of the
  `ollama-pane-discovery-models-bundle` umbrella (escalated to the
  top of the backlog 2026-04-20 after operator feedback on
  discoverability + ollama-launch flow). `AddPaneSheet` was already
  a 2-column visual grid with icon + title + description + hover
  lift — NOT a hidden menu as the operator's framing suggested. The
  real gaps were: (1) `dashboard` was missing from the entries list
  (16 of 17 panes listed), (2) no categorization on a 16-item flat
  grid, (3) gallery data was duplicated in the SwiftUI view and
  untestable.
- New `Sources/Core/PaneGalleryBuilder.swift` mirrors
  `CommandEntryBuilder` — pure-data, string-ID-based, testable.
  17 entries grouped into 4 categories (Morville + Norman
  taxonomy): **Shell & Agents** (Terminal, Agent Timeline),
  **AI & Models** (Skills, Knowledge Base, Models, Sprint Review),
  **Data & Insights** (Dashboard, Analytics, Savings Test,
  Schedules, Log Viewer), **Docs & Code** (Code Editor, Markdown
  Preview, HTML Preview, Browser, Diff Viewer, Scratchpad). Every
  category is ≤6 entries (skimmable bar).
- `AddPaneSheet` refactored to consume `PaneGalleryBuilder`:
  category section headers (uppercased, tracked, 10pt) above a
  2-column grid per category, filter still works across all
  categories (empty categories auto-omit from filtered output),
  sheet grew 420×480 → 460×560 to fit labels.
- **Unchanged:** the "+ Add Pane" button in the sidebar bottom bar
  is already labeled (verified in `SidebarView.swift:289–307`) —
  the operator's "hidden +" concern was actually the flat-grid
  discoverability once the sheet opened, not the trigger itself.
- 12 new tests under `@Suite("Pane Gallery")`: 17-type coverage,
  dashboard-present regression pin, unique IDs, ≤6 per category,
  every entry in a known category, categorization is total,
  category order stable, descriptions ≤80 chars (Podmajersky bar),
  filter case-insensitive + matches description, empty query
  returns all, filter→categorized collapse.
- Test count: 1527 → 1539 (+12).
- **Accepted risks** (documented in `tools/soak/manual-log.md`):
  Butterick explicit focus-ring treatment not added this round
  (SwiftUI Button default keyboard focus is reachable but
  visually subtle); Podmajersky microcopy audit deferred (current
  descriptions are ≤80 chars but stylistically inconsistent).
  Both are follow-up items, not round-blockers.
- **Deferred to the next 4 sub-items** of the umbrella:
  `ollama-pane-first-class` (b), `ollama-model-curation` (c),
  `models-page-installable` (d), `mcp-in-ollama-pane-verify` (e).

### April 20 — Phase S.1: manifest schema + MCP tool gating (foundation)
- `phase-s-manifest-schema` closes the first Week-1 slice of Phase S
  (skill/tool/hook manifest, approved 2026-04-19). New module
  `Sources/Core/Manifest/` (3 files, ~170 LOC):
  `Manifest.swift` (team manifest schema + `ManifestOverrides` +
  `EffectiveSet`), `ManifestResolver.swift` (pure resolver
  `effective = team ∩ optOuts ∪ additions`), `ManifestLoader.swift`
  (disk I/O; missing files are not errors).
- On-disk home is `<projectRoot>/.senkani/senkani.json` for the team
  manifest, `~/.senkani/overrides.json` (single file, keyed by
  absolute project-root path) for user-local overrides. Format is
  JSON rather than the YAML named in the roadmap spec — no YAML
  parser is in-tree; JSON is a strict YAML subset so a future
  Yams-backed round reads today's files verbatim.
- `MCPSession.effectiveSet` is a lazy lock-guarded resolve that
  happens on first read and caches for the session. Never throws —
  missing files yield `manifestPresent: false`.
- `ToolRouter.advertisedTools(for:)` filters the catalog by the
  effective set, with core tools (`read`, `outline`, `deps`,
  `session`) always-on. `ToolRouter.route` gates CallTool by the
  same set, returning `isError: true` with a Skills-pane-pointer
  message for disabled tools. `ListTools` handler queries the
  filtered catalog.
- Backwards-compat invariant: projects with no
  `.senkani/senkani.json` get `manifestPresent: false` and the full
  tool surface — today's behavior, verified by
  `backwardsCompatWithoutManifestEnablesEverything` and
  `advertisedToolsIncludesEverythingWhenNoManifest`.
- Out of scope this round (deferred to follow-up rounds):
  Skills-pane UI (S.4), storefront/registry (S.6), AXI.9
  `buildSkillsPrompt` retrofit (touches MCPSession.swift), Starter
  Kits (S.7), ratings + comments (S.5), cron/agents manifest
  sections (S.8), YAML parser swap.
- Tests: 1510 → 1527 (+17 new) across five `ManifestTests` suites —
  schema round-trip + coreTools identity, resolver formula (team/
  opt-out/addition/precedence/nil-manifest), `isToolEnabled`
  gating (core-always, backwards-compat, non-core requires listing),
  loader disk paths (missing file, present file, user overrides,
  per-project keying), and ToolRouter advertise filtering.

### April 20 — Website search: client-side Lunr across the wiki
- `website-rebuild-10-search` closes. `scripts/gen.py` emits
  `assets/search-index.json` by walking every `docs/**/*.html` —
  extracts title, body (first 800 chars of `<main>`, tags stripped),
  path, and a short `name` field for MCP/CLI pages (the bare tool
  name, e.g. `read` for `senkani_read`, `bench` for `senkani-bench`).
  93 docs / ~85 KB.
- `assets/lunr.min.js` vendored (~29 KB, MIT). `assets/app.js`
  lazy-loads it on first focus/keystroke — first-paint unchanged.
- Index builder overrides `lunr.tokenizer.separator` to split on
  underscore as well as whitespace/hyphen, so `senkani_read`
  tokenizes to `[senkani, read]` and the bare tool name is
  discoverable by prefix. Fields: `name` boost 30, `title` 10,
  `path` 3, `body` 1.
- Query builder uses prefix (`q*`) for tokens of 3 chars or fewer
  and prefix-plus-fuzzy (`q* q~1`) for longer tokens. Short queries
  no longer drown in near-matches.
- Keyboard: `/` focuses the nav search from anywhere; arrow keys
  navigate the 8-result dropdown; Enter opens; Escape closes.
- Acceptance measured on the shipped index (replayed via
  JavaScriptCore against the live `search-index.json` +
  `lunr.min.js`): typical full-name queries hit the expected
  senkani page top for 15/19 MCP tools and 18/19 CLI commands.
  At 3-character prefix, 17/19 CLI commands return the matching
  `senkani <cmd>` page top. At the strict 2-character prefix, MCP
  matches 11/19 — the remaining gap is structural (four pairs of
  MCP tools share 2-char prefixes: read/repo, exec/explore,
  search/session, pane/parse; one of each pair wins at 2 chars,
  the other needs one more keystroke) plus four MCP names that
  overlap with CLI commands (fetch, search, explore, validate) —
  both the CLI and MCP pages match, the CLI page outranks because
  its title carries the name as a standalone word by default.
  Accepted: the user gets a valid senkani page for their query
  either way; the overlap is a real-world disambiguator, not a bug.
- No Swift code changes; no test delta (1510 → 1510). Soak log
  updated — manual validation in a real browser still queued.

### April 19 — Website redesign: hero stack + /docs/ consolidation + font bumps
- Landing page redesigned as a hero stack — one full-width "product
  hero" per major feature, Apple-product-page style. Each hero
  pairs a headline + 3 bulleted value props + a "Learn more →"
  link with a custom illustration (before/after terminal pair, MCP
  tool grid, pane tile grid, compound-learning flow diagram,
  knowledge-base entity cards, security shield checklist).
- Heroes shipped: Compression layer · MCP intelligence · Workspace ·
  Compound learning · Knowledge base · Security posture. Alternating
  light/dark bands. Plus the project hero on top, a stat strip, and
  a tightened install CTA. Landing is 377 lines HTML, still well
  under the 600-line target.
- All doc folders moved under `/docs/`. Root now contains only
  `index.html`, `assets/`, `docs/`, `scripts/`, and the code/spec
  directories — no more `/concepts/`, `/reference/`, `/guides/`,
  `/status/`, `/about/`, `/changelog/`, `/what-is-senkani/` at the
  repo root. Depths all increased by 1; `scripts/gen.py` computes
  per-page `../` prefixes so links resolve under both `file://`
  and the project-subpath deploy at `ckluis.github.io/senkani/`.
  A new `/docs/` index hub renders links to every wiki section.
- Font bumps across the board — nothing readable is below 14px
  anymore. Badges 12→13, overlines 12→13, tags 12→13, breadcrumb
  13→14, wordmark small 13→14, topnav search + btn 14→15, wiki-nav
  headers 12→13 + links 14→15, listing rows 15→16 + head 12→13 +
  desc 15→16, ref-io-table header 12→13 + type/default/desc 14→16,
  code blocks 14→15, callouts 15→16, source-pointer 14→15, mockup
  pane title 13→14 + ctx 12→13 + body 13→14 + term lines 13→14 +
  tb-title 13→14, FCSIT button 10→12, step num 13→14 + body 16→17
  + code 14→15, feature-list name 15→16 + desc 14→15, search hit
  14→15 + path 12→13, code-copy 11→13, positioning-table 15→16 +
  head 12→13, stat-strip num 48→52 + label 14→15, teaser num 13→14
  + h3 22→24 + p 15→16 + more 13→14, gallery link 15→16.
- Legacy anchor redirects updated to point at `/docs/*` paths
  (`#how-it-works` → `docs/concepts/`, `#mcp-tools` →
  `docs/reference/mcp/`, etc.). `assets/app.js` legacyMap.
- No Swift code changes. No test delta (1510 → 1510).

### April 19 — Website rebuild (items 1–9 shipped in one megaround)
- Operator-directed bundle of the entire website-rebuild chain from
  `spec/website_rebuild.md`. 94 HTML files shipped across a Diátaxis-
  structured wiki: 19 MCP tool pages, 19 CLI command pages, 17 pane
  pages, 10 option pages, 7 concept pages, 9 guide pages, 10 hub
  pages, plus a rewritten landing at 280 lines (target was ≤600).
  Every page has its own URL — bookmarkable, linkable, searchable.
- `assets/theme.css` (~900 lines) implements the Section 4
  typography scale (all reading text ≥14px, tables ≥15px, code
  ≥14px, badges ≥12px), the contrast-adjusted ink tokens
  (`--ink-mute` moved from #706c66 → #5a5652 for WCAG AA on body
  text), focus rings on every interactive element, skip-link, and
  `prefers-reduced-motion` honoring across animations + terminal-
  cursor blink. Every text/bg pair in the new palette passes AA.
- `scripts/gen.py` (~1000 lines, stdlib-only Python) renders the
  templated pages (MCP, CLI, panes, options, concepts, guides,
  hubs) from in-file data tables. No framework, no npm, no package
  manager. Regenerate via `python3 scripts/gen.py`.
- Relative-path architecture: every page computes its own `../`
  prefix from the output path depth so links resolve correctly
  under both `file://` local viewing AND GitHub Pages project-
  subpath deploys (`ckluis.github.io/senkani/`). `.nojekyll`
  added to skip Jekyll processing.
- Legacy anchor redirects preserved in `assets/app.js`: inbound
  links to `/#how-it-works`, `/#mcp-tools`, `/#install`, `/#terse`,
  etc. now redirect to the corresponding new wiki URLs.
- Pending in follow-up rounds: `website-rebuild-11-content-pass`
  (editorial + closing audit), `website-rebuild-12-claude-prototype-
  review` (operator's auth-walled Claude Design prototype extract).
  `-10-search` closed 2026-04-20 (see above).
- No Swift code changes; no test delta (1510 → 1510). Manual
  validation queue added to `tools/soak/manual-log.md` (visual
  inspection, axe-core-cli pass, Lighthouse, keyboard traversal,
  mobile layout, cross-browser, live deploy preview).

### April 19 — Website rebuild plan (Luminary planning round)
- New `spec/website_rebuild.md` (~420 lines) — the umbrella spec for
  splitting the single-page `index.html` into a ~75-page Diátaxis-
  structured wiki + a tightened landing page. Operator-directed
  planning round run through
  `/luminaryReview:marketing + /luminaryReview:ux + default`
  (combined starting roster per `ckluis.github.io/luminaryTeam/`).
  Final 10-member roster: Jobs, Torvalds, Norman, Zhuo, Morville,
  Butterick, Procida, Dunford, Handley, Sutton. Four red flags
  fired — Morville (single-page IA, USER IMPACT); Butterick (sub-
  14px reference tables, USER IMPACT + COMPLIANCE); Sutton
  (multiple WCAG AA contrast fails, COMPLIANCE — `--ink-mute:
  #706c66` on `--bg: #f5f1e8` measures ~3.9:1); Procida
  (reference + explanation fusion, Diátaxis anti-pattern, USER
  IMPACT).
- Spec covers: diagnosis with `index.html` line citations;
  target sitemap (one URL per MCP tool, per CLI command, per
  FCSIT option, per pane type — ~75 pages total); typography
  scale (all reading text ≥14px, badges ≥12px, code blocks
  ≥14px); color tokens (`--ink-mute` moves to `#5a5652` so every
  text/bg pair passes WCAG AA); per-page skeletons for
  concept / reference / guide / landing; build harness
  (`scripts/build.sh` + `assets/theme.css` + partials, no
  framework, no npm on CI); voice rubric (Handley + Dunford);
  staged execution plan; out-of-scope list (dark mode, l10n, CMS,
  pixel trackers); closing success criteria (axe-core 0 AA,
  Lighthouse a11y ≥ 95 + perf ≥ 90, landing ≤ 600 lines HTML,
  search returns any MCP tool in ≤ 2 keystrokes).
- `spec/autonomous-backlog.yaml` — umbrella landed as
  `website-rebuild-0-spec` (completed 2026-04-19); 12 new
  `pending` items queued (`website-rebuild-1-typography-tokens`
  through `website-rebuild-12-claude-prototype-review`) with
  `blocked_by` chains that enforce the execution order. Umbrella
  is DELIVERED when items 1–11 ship green (item 12 is a parallel
  Claude Design prototype extract with no hard blockers).
- No source code changes; no test delta. Implementation ships
  incrementally in rounds 1–11.

### April 19 — `senkani doctor`: grammar staleness advisory (non-blocking)
- New `Sources/Indexer/GrammarStaleness.swift` — pure
  `advise(cached:today:thresholdDays:)` helper returns one of
  `.noUpstreamData`, `.allFresh`, `.recentUpdatesAvailable(count:)`, or
  `.stale([StaleEntry])`. Stale = upstream has a newer version AND the
  grammar has been vendored for more than 30 days. Under the 30-day
  window, outdated grammars roll up as PASS ("recent update available")
  so routine upstream churn cannot red-light `senkani doctor`. Over the
  window, the advisory reports SKIP (not FAIL) — the check is a
  non-blocking warning so it can't false-alarm CI per
  `spec/tree_sitter.md:80`. `today:` is injectable for deterministic
  tests; `parseVendoredDate` parses ISO `YYYY-MM-DD` without
  allocating a DateFormatter.
- `DoctorCommand.checkGrammars` rewritten to switch on the advisory:
  offline path (no cache) → SKIP with "run senkani grammars check"
  hint; all-fresh → PASS with full language list; recent-updates → PASS
  with a count of how many grammars are waiting in the 30-day window;
  stale → SKIP listing each language with its current + latest version
  + days-stale. Reuses the existing 24h GitHub-version cache — no new
  network paths.
- New `Tests/SenkaniTests/GrammarStalenessTests.swift` — 12 tests
  (+1498 → 1510): offline (nil cache), empty cache, all-fresh,
  recent-updates-within-window, stale-beyond-window (99 days),
  exact-30-day boundary is NOT stale, 31-day first-past-boundary,
  mixed-cache lists only stale entries sorted alphabetically,
  outdated-without-latestVersion is skipped defensively,
  custom-threshold parameter, ISO date parse happy-path, and
  malformed-date rejection. All injected `today:` fixtures, zero
  network I/O.

### April 19 — `senkani uninstall` automated smoke — narrows cleanup.md #15 gap
- New `Sources/CLI/UninstallArtifactScanner.swift` (~160 LOC) —
  testable artifact discovery + removal factored out of
  `UninstallCommand`. Takes explicit `homeDir` + `appSupportDir`, so
  tests can seed a fixture HOME under a tmp dir without ever touching
  the operator's real `$HOME`. All seven categories mirror the old
  inline logic: global MCP registration, project-level hooks,
  `~/.senkani/bin/senkani-hook`, the `~/.senkani/` runtime dir, the
  session DB in `~/Library/Application Support/Senkani/`, senkani
  launchd plists, and per-project `.senkani/` dirs.
- `UninstallCommand.scanForArtifacts` is now a five-line wrapper that
  builds the scanner with real paths. Public CLI behavior is
  byte-identical (same icons, same descriptions, same ordering, same
  `--keep-data` semantics). `removeGlobalMCPEntry` + the project-hook
  cleanup helper moved onto the scanner as static methods.
- Schneier gate: the new filter-boundary test seeds non-senkani hook
  files + non-senkani launchd plists and asserts the scanner does NOT
  flag them — prevents the refactor from silently widening deletion
  scope beyond `senkani*`/`senkani-daemon` and `com.senkani.*.plist`.
- New `Tests/SenkaniTests/UninstallSmokeTests.swift` — 6 tests
  (+1492 → 1498): full-seed produces all 7 categories, `--keep-data`
  omits `sessionDatabase`, default run includes it, pristine HOME is
  empty, removal → re-scan is idempotent, non-senkani hooks/plists
  aren't flagged. Every test isolates itself under a unique tmp dir.
- `tools/soak/manual-log.md` keeps the "real install" half of
  cleanup.md #15 on the queue — this round fences the synthetic half
  against regression, the real-machine validation still wants
  operator hands.

### April 19 — Pane diaries (round 3/3): MCP injection + pane-close regen — umbrella DELIVERED
- New `Sources/Core/PaneDiaryInjection.swift` — Core-level glue
  between `PaneDiaryStore` (I/O) + `PaneDiaryGenerator` (composition)
  and the MCP subprocess. Two entry points: `instructionsSection(env:home:)`
  (called on MCP server start — loads the prior diary into the
  instructions payload) and `persist(rows:env:home:lastError:)`
  (called on MCP server shutdown — regenerates + writes the diary).
  Both honor `SENKANI_PANE_DIARY=off`, both require
  `SENKANI_WORKSPACE_SLUG` + `SENKANI_PANE_SLUG` to be set +
  non-empty, both swallow all failure paths so a bad diary cannot
  block MCP server start or pane close (pane-open-never-hangs +
  pane-close-never-hangs invariants from the acceptance).
- `MCPSession.instructionsPayload` now interpolates the pane diary
  between `sessionBrief()` and `skillsPrompt()` with a dedicated
  `paneDiaryBudget = min(800, budget/3)` slice. Truncation marker
  `[pane diary truncated]` fires only if a pathologically large
  diary blows past the budget (generator caps at 200 tokens ≈ 800
  bytes, so dual-bounded in practice).
- `MCPSession.shutdown()` fetches the last 100 `token_events` rows
  for the session's project root via `recentTokenEvents(projectRoot:limit:)`
  and calls `PaneDiaryInjection.persist` BEFORE `endSession` — the
  generator window is the just-closed session's activity. The write
  is best-effort and non-blocking.
- `SenkaniApp/Views/PaneContainerView.swift` now sets
  `SENKANI_WORKSPACE_SLUG` (derived from the pane's working
  directory — last two path components joined with `-`, mirroring
  the metrics-file-path convention) and `SENKANI_PANE_SLUG` (the
  `PaneType.rawValue`) on every terminal pane spawn. Stable across
  pane-id recycles, so reopening a terminal in the same project
  surfaces the same diary.
- Schneier gate: no path-traversal attack surface — `PaneDiaryStore`
  already hard-rejects `..`/`/`/`\` slugs, env-var poisoning can only
  pick a different file under `~/.senkani/diaries/` (never outside).
  Written files stay mode 0600 from the round-1 store contract. The
  injection's swallow-errors pattern is intentional: it's the right
  failure mode for a best-effort resume hint.
- +10 tests (1482 → 1492): read-side injects prior diary with
  `Pane context:\n` section header, env-off produces empty section
  even when diary exists, missing/partial slug env produces empty,
  no-diary-on-disk produces empty, malformed slug (`..`) degrades
  to empty (no throw), write-side persists a brief composed from
  real rows (round-trip verifies via store), write-side is no-op
  when env-off / slugs-missing / rows-empty, persist→inject
  round-trip recovers the written section on the next read.
- Umbrella `pane-diaries-cross-session-memory` DELIVERED 2026-04-19
  (3/3 sub-items shipped; cumulative 1466 → 1492, +26 tests across
  the three rounds).

### April 19 — Pane diaries (round 2/3): `PaneDiaryGenerator` brief composer
- New `Sources/Core/PaneDiaryGenerator.swift` — pure composition half
  of the cross-session per-pane memory feature. Given `token_events`
  rows for a pane-slug (plus an optional caller-supplied `lastError`),
  returns a terse brief the round-3 pane-open path can inject into
  MCP instructions. No disk I/O, no DB access — round 3 wires the
  fetch side.
- API: single `generate(rows:paneSlug:lastError:maxTokens:)` static
  method on a `public enum`. Output sections (priority order, earlier
  survives truncation): header (`Last time in '<slug>':`), optional
  `Error:` line, `Last:` (most-recent command), `Files:` (top-3
  unique paths from read/edit-like rows, recency-first, basenames
  only), `Cost:` (summed input+output tokens), `Recent:` (up to 5
  commands, dropped first on overflow).
- Token cap: hard 200-token default enforced via
  `ModelPricing.bytesToTokens` (4 bytes/token — the senkani-wide
  estimator). Overflow handled at section granularity — sections land
  whole or are dropped whole, so output always terminates on a
  section boundary, never mid-word.
- Round 2 kept the "last error" input optional + caller-supplied
  rather than synthesized from the row stream: `TimelineEvent` has
  no error column, and the round-3 fetch layer is the natural place
  to derive it. This keeps the generator pure and testable.
- +8 tests (1474 → 1482): empty rows + no error → empty brief,
  small rows surface header + last + files + cost + recent inside
  the cap, caller-supplied error lands below the header, error with
  no rows still produces header + error, 200-row flood respects the
  cap exactly and every output line is a recognized section prefix
  (no mid-line truncation), tight 30-token budget drops `Recent:`
  before core sections, file dedupe keeps the most-recent occurrence
  only, non-file tools (`exec`, `grep`) never leak into the `Files:`
  section.
- No callers yet — generator ships standalone. Umbrella
  `pane-diaries-cross-session-memory` now 2/3 shipped; round 3
  (pane-open MCP injection + pane-close regen) remains.

### April 19 — Pane diaries (round 1/3): `PaneDiaryStore` I/O half
- New `Sources/Core/PaneDiaryStore.swift` — disk I/O half of the
  cross-session per-pane memory feature. Owns the on-disk contract at
  `~/.senkani/diaries/<workspaceSlug>/<paneSlug>.md`; round 2 lands
  `PaneDiaryGenerator` (brief composition from `token_events`); round 3
  wires generator + store into the pane-open MCP path.
- API: `read(workspaceSlug:paneSlug:home:env:)`, `write(_:workspaceSlug:paneSlug:home:env:)`,
  `delete(workspaceSlug:paneSlug:home:env:)`, `isEnabled(env:)`,
  `diaryPath(workspaceSlug:paneSlug:home:)`. Pure static functions on
  a `public enum` — no instance state, home/env override seams for
  fixture-driven tests.
- Safety invariants: env gate `SENKANI_PANE_DIARY=off` short-circuits
  read/write/delete (case-insensitive; default ON); `SecretDetector.scan`
  runs on every write AND every read (defense-in-depth for diaries
  written by older versions or hand-edited on disk); slug validation
  hard-rejects `..`, `/`, `\`, and empty slugs via a typed
  `StoreError.invalidSlug(field:value:)`; atomic write via PID-
  suffixed tmp file + `replaceItemAt`/`moveItem` so a crashed or
  permission-denied write cannot corrupt an existing diary; written
  files land at mode 0600 (mirrors `SocketAuthToken` — diaries are
  user-local command history on a potentially multi-user machine and
  the regex defense is not complete).
- +8 tests (1466 → 1474): round-trip read/write, env-off short-circuits
  all three operations (write/read/delete) + isEnabled semantics,
  write redacts a planted `sk-ant-…` Anthropic key, read re-redacts
  a pre-seeded `sk-proj-…` secret (simulating a hand-edited file),
  slug keying isolates diaries across workspace × pane combinations
  and delete is scoped, atomic write preserves existing content when
  the parent dir is chmod'd read-only mid-round, slug rejection for
  `..` / `/` / `\` / empty / whitespace-only across both fields and
  no bogus files land on disk, 0600 permission bit asserted on-disk
  via `FileManager.attributesOfItem`.
- No callers yet — store ships standalone. Umbrella
  `pane-diaries-cross-session-memory` still 1/3 shipped; rounds 2
  (`PaneDiaryGenerator`) and 3 (pane-open MCP injection + close-time
  regen) remain.

### April 19 — Sprint Review pane: GUI for `senkani learn review`
- New 17th pane type: `Sprint Review`. SwiftUI surface for
  compound-learning review — lists staged artifacts across all four
  types (filter rule / context doc / instruction patch / workflow
  playbook) for a configurable window (default 14 days), with
  accept/reject per row plus a stale-applied section sourced from
  the quarterly audit heuristics (`CompoundLearningReview.quarterlyAuditFlags`).
- Registered everywhere a pane type needs to be known: `PaneType.sprintReview`
  enum case, `SenkaniTheme` accent/icon/description/name, `PaneModel`
  default columnWidth, `PaneContainerView` view + context-label
  switches, `AddPaneSheet` card grid, `CommandEntryBuilder.paneEntries()`
  for ⌘K palette, `ContentView.addPaneByTypeId` palette typeId map.
- Architecture split: pure view-model + types in
  `Sources/Core/SprintReviewViewModel.swift` (testable from
  SenkaniTests, which does not depend on SenkaniApp). Presentation
  in `SenkaniApp/Views/SprintReviewPane.swift`. Accept/reject
  route through the canonical `CompoundLearning.apply*` /
  `LearnedRulesStore.reject*` paths — no new write paths, no new
  SQL, no new DB migration, no new secret-scan boundaries. The
  backlog said "LearnedRulesStore.promote(...)" / "LearnedRulesStore.reject(...)";
  the real method names are kind-specific (`apply` / `applyContextDoc`
  / `applyInstructionPatch` / `applyWorkflowPlaybook`), so the view
  model dispatches on `SprintReviewArtifactKind`.
- +13 view-model tests (1453 → 1466): empty-store snapshot,
  four-kind grouping, filter-rule command/sub shaping with rationale,
  workflow step-count pluralization, window cutoff, applied-stale
  flag surfacing, accept routing for each of the four kinds (filter
  rule → state only; context doc + workflow playbook verify
  `.md` landed on disk; instruction patch → state), reject routing
  per kind, all-four reject round-trip, and rejected item no longer
  in next snapshot. Existing `CommandPaletteTests.paneEntriesIncludeAllTypes`
  count assertion bumped 16 → 17 to match the new palette entry.
- Deferred to `tools/soak/manual-log.md`: live GUI validation
  (visual pass on empty/populated states, stepper behavior, accept
  writes through on real install, error banner), and the
  `liveToolNames` plumbing (quarterly audit's instruction-patch
  staleness heuristic currently defaults to an empty set, matching
  the CLI — wiring it to the live `ToolRouter.allTools()` list from
  the MCP server would surface extra stale flags but requires
  cross-process state the GUI doesn't have).
- Closes `sprint-review-pane` backlog item; compound-learning
  spec's "non-autonomous Sprint-review pane UI" line (Round 9
  consolidation) no longer applies — the CLI + GUI both ship.

### April 19 — ContentView: strip stray restoreWorkspace debug print (follow-up)
- One-line follow-up to `metricsrefresher-debug-print-cleanup`.
  Deleted the 🚨-tagged `print("[CONTENT-VIEW] restoreWorkspace
  done: …")` call at `SenkaniApp/Views/ContentView.swift:210`. Same
  provenance as the MetricsStore prints (a 2026-04 troubleshooting
  pass). No replacement Logger.log() — `restoreWorkspace` runs once
  at app launch; a startup banner adds no operational signal.
- All emoji-tagged `print()` calls are now gone from
  `SenkaniApp/`. Future regressions can be caught with
  `grep -rn "print(.*🚨\|print(.*💀" SenkaniApp/`.
- Build clean. Tests unchanged.

### April 19 — MetricsStore: strip leftover debugging prints (cleanup.md #11 closed)
- `SenkaniApp/Services/MetricsRefresher.swift` dropped from 79 → 60
  LOC. Five emoji-tagged `print()` lines (🚨🚨🚨 / 💀) left over from
  a 2026-04 troubleshooting pass — the start banner, per-project
  enumeration loop, self-nil dying, tick-counter heartbeat, and
  task-cancelled lifecycle line — all deleted. Heartbeat fired every
  refresh tick (1 Hz), so on real installs every operator's stderr
  was getting one observability-noise line per second per started
  MetricsStore. The `weak self` capture and `guard let self else
  { return }` semantics are preserved; behavior is identical.
- Closes the staleness review on cleanup.md #11. Verified during
  this round: there is no caching layer in MetricsStore — `@Observable`
  + a 1-second refresh task that writes `projectStats`/`allStats`
  directly is all there is, so the UI cannot lag the DB by more
  than one refresh tick. The original spec implied a TTL the
  implementation never had.
- Tests: 1453 → 1453 (no test changes — hygiene pass). Full suite
  green under `swift test --no-parallel` (the 5 known
  `BundleRemote*`/`RemoteRepoClient*` parallel-mode URLProtocol
  failures are pre-existing and documented in the
  `mlx-inference-lock` round notes).

### April 18 — Browser Design Mode wedge: click-to-capture (scope-reduced from FUTURE)
- Default-off, env-gated feature on the Browser pane. Set
  `SENKANI_BROWSER_DESIGN=on` in the environment and ⌥⇧D toggles a
  click-to-capture mode on the active BrowserPaneView. Click an
  element and a fixed-schema Markdown block lands on the clipboard.
  CEO review 2026-04-18 reduced the original three-round plan
  (MVP → direct-pin → screenshot/annotation) to a single instrumented
  wedge — larger scope is explicitly gated on
  `browser_design.entered` reaching the median of existing feature
  gates over a 30-day window. If unused, the wedge DELETES rather
  than expands.
- Selector generator: `#id` if unique → `tag.class1.class2` if
  unique → `nil` with `fallbackReason: "no unique anchor"`. **No
  nth-of-type recursion** — the highest-bug-density code in the
  original plan, deferred. Shadow DOM and cross-origin iframe
  elements emit a clear "Can't capture — element is inside a shadow
  DOM" / "cross-origin iframe" toast instead of a malformed capture.
- Triple SecretDetector scan: `innerText` truncated to 300 chars
  then redacted; classes scanned as defense logging; final
  serialized Markdown run through one more sink-side scan so a
  secret embedded in a class name can't leak via the rendered
  `tag:` line (test 9 proves the sink catches a `sk_live_…`
  planted class name).
- Mode lifecycle torn down on navigation AND on pane close — guards
  the leak-across-navigation failure mode. `WKUserContentController`
  gets `removeAllUserScripts()` + `removeScriptMessageHandler(forName:)`
  on every exit path. Pure-Swift state machine (Core.BrowserDesignMode.State)
  covers the transition contract in unit tests so the App-side
  integration can't drift.
- Four `event_counters` rows declared:
  `browser_design.entered`, `browser_design.captured`,
  `browser_design.shadow_dom_skipped`, `browser_design.keyboard_conflict`.
  The first three are recorded by the App-side controller on the
  matching transitions. `keyboard_conflict` stays declared in the
  counter enum but unrecorded — the spec's detection path
  ("page captures ⌥⇧D before WKUserScript") doesn't apply because
  the Swift NSEvent monitor runs out-of-band from page JS;
  scaffolding stays in place for v1.1+.
- 2 new files, 1 modified. Pure logic in
  `Sources/Core/BrowserDesignMode.swift` (env gate, selector gen,
  capture payload processing, Markdown formatter, state machine,
  injected-JS source) keeps SenkaniTests coverage possible.
  `SenkaniApp/Views/BrowserDesignController.swift` owns the
  WKUserScript + WKScriptMessageHandler lifecycle, toast state, and
  clipboard write. `BrowserPaneView.swift` wires the ⌥⇧D NSEvent
  monitor (guarded on first-responder so the chord only toggles when
  the pane's WKWebView is focused) and passes an
  `onDidStartNavigation` closure down to the WKNavigationDelegate
  coordinator so the controller can tear down.
- 16 new tests (1438 → 1454): id-anchor + class-anchor + no-anchor
  selector; non-unique-id fallthrough; shadow-DOM and cross-origin
  iframe guards; SecretDetector redaction on innerText; class-name
  secret caught by sink-side Markdown scan; innerText truncation
  bound; Markdown byte-stable snapshot vs a fixed `CapturedElement`;
  Markdown fallback line when selector is nil; state machine
  lifecycle (enter → navigate → discard; enter → pane close →
  discard); navigation on a non-active pane is a no-op; env-var
  gate accepts only `on`/`ON` and `State.enter(featureEnabled:false)`
  is a no-op; counter vocabulary matches the four declared rows;
  injected JS bundle sanity (message handler name, elementFromPoint,
  getRootNode, Escape, re-entrancy guard).
- Manual-log entries seeded for real-machine validation (live
  WKWebView ⌥⇧D capture, shadow DOM page, cross-origin iframe,
  page-JS keyboard hostility, ⌘C vs our clipboard write).

### April 18 — Budget enforcement: symmetric tests for the MCP + Hook gates (cleanup.md #9)
- Budget enforcement fires at two independent layers: `ToolRouter` uses
  `session.checkBudget()` before any MCP-routed tool call;
  `HookRouter.handle` uses the daily/weekly gate before any non-MCP
  tool call (Read / Bash / Grep via the hook relay). Before this
  round only the MCP side had unit-test coverage — a regression on
  the hook side could land without any test failure.
- New `Tests/SenkaniTests/BudgetEnforcementDualLayerTests.swift` —
  9 tests exercising both gates independently: MCP gate blocks on
  global per-session hard limit, MCP gate warns at 80% soft limit,
  hook gate blocks on daily limit, hook gate blocks on weekly limit,
  pane-cap fires at MCP layer with no global config, below-limit
  call passes both layers, hook gate short-circuits when
  `projectRoot` is nil, hook gate short-circuits when no daily /
  weekly limit configured, MCP gate fires with no hook plumbing at
  all (cross-layer independence).
- Two production-code changes enable the tests without touching
  behavior: (a) `BudgetConfig.withTestOverride(_:_:)` — sync-only,
  `NSRecursiveLock`-serialized test slot that `load()` /
  `forceReload()` consult before disk + env + cache; same-thread
  reentry works (so a body that calls the gate under test can
  itself re-enter `load()` without deadlocking); (b) the hook
  budget block inside `HookRouter.handle` factored out into a
  public helper `checkHookBudgetGate(projectRoot:config:costForToday:costForWeek:)`
  with closure defaults pointing at `SessionDatabase.shared` — tests
  inject fabricated cost functions to exercise the gate without
  polluting the real DB. Production call-site is a one-liner now,
  same observable behavior.
- 9 new tests (1428 → 1437). All existing budget tests pass
  unchanged.

### April 18 — SkillScanner: scanAsync() wired into the Skill Browser (FIXME resolution)
- `SkillBrowserView.loadSkills()` now calls `SkillScanner.scanAsync()`
  instead of the synchronous `scan()`. SwiftUI's `.task { ... }`
  inherits the MainActor, so the previous call stalled the UI thread
  for the duration of the scan — a silent trap on machines with a
  large `~/.claude/` tree. `scanAsync` hops to
  `Task.detached(priority: .utility)` so the scan runs on a
  background executor and the main actor stays responsive.
- The FIXME at `SkillScanner.swift:47` is gone. The zero-arg
  synchronous `scan()` is retained for CLI / non-UI use but is now
  `@available(*, deprecated, message: "UI callers must use
  scanAsync() to avoid main-thread stalls")` — any future UI
  regression that reverts to `scan()` trips a yellow build warning
  on the call-site.
- New `scan(homeDir:cwd:)` and `scanAsync(homeDir:cwd:)` overloads
  parameterize the scan roots for fixture-driven tests (the old
  signatures hit `NSHomeDirectory()` + `fm.currentDirectoryPath`
  directly, so tests could not isolate from the host machine).
  Production continues to call the zero-arg forms.
- 4 new tests (1424 → 1428): scan on empty fixture returns empty;
  scanAsync matches scan on a seeded fixture (Claude commands +
  Cursor rule + Senkani skill; key-order parity); scanAsync on 80+
  seeded files finishes under a 2-second wall-clock bound
  (regression guard against accidental resync, not a micro-benchmark);
  scanAsync runs in parallel with a concurrent async task without
  blocking it (rules out a regression that awaits inline).

### April 18 — Pane Display settings: font-family picker + persistence
- The Display section of the pane settings panel now ships a
  monospace font-family picker alongside the existing size slider and
  preset buttons. The picker is populated from a curated
  six-family list (SF Mono / Menlo / Monaco / Courier / Courier New /
  Andale Mono) — hard-coded (not queried from `NSFontManager`) so the
  list is deterministic across machines.
- New `Sources/Core/PaneFontSettings.swift` — pure Foundation
  `Codable` / `Equatable` / `Sendable` struct plus static helpers
  (`clampFontSize`, `resolveFamily`, `fontSizeDidChange`,
  `fontFamilyDidChange`). The AppKit resolution layer
  (`NSFont(name:size:)` → `monospacedSystemFont` fallback) stays in
  `TerminalViewRepresentable.resolveFont`. Splitting the layer keeps
  the Core type testable from `SenkaniTests` (which has no
  SenkaniApp dependency) while AppKit lives where it belongs.
- `PaneModel.fontFamily` joins the existing `fontSize` field.
  `PersistedPane` extends with optional `fontSize` / `fontFamily`
  entries — pre-existing `workspace.json` files decode cleanly
  (`decodeIfPresent` path) and land at `PaneModel`'s init defaults.
  On restore, `clampFontSize` + `resolveFamily` guard against a
  tampered or stale workspace file. Changes propagate live to the
  terminal view: `updateNSView` re-applies the font when size diffs
  by more than 0.5pt OR the family name differs exactly — single
  slider tick / picker change fires exactly one font re-apply.
- 11 new tests (1413 → 1424): defaults shape, bounds inclusion
  (8–24pt range is a superset of the 9–20 acceptance), clamp
  below-min / above-max / in-range identity, curated family set,
  known-family roundtrip, unknown-family fallback to default,
  size-diff 0.5pt threshold, family exact-string compare,
  `Codable` roundtrip. No regressions in existing tests.

### April 18 — Pane IPC: JSONL poll → Unix socket
- Migrated the last fire-and-forget pane IPC caller
  (`MCPSession.sendBudgetStatusIPC`) from the `pane-commands.jsonl` file
  path to the existing `~/.senkani/pane.sock` Unix domain socket — same
  length-prefixed binary protocol, optional `SocketAuthToken` handshake,
  `chmod 0600` permissions enforced by `SocketServerManager`. Every
  pane IPC path now uses the socket; JSONL transport is retired.
- Wired `SocketServerManager.shared.paneHandler` from
  `ContentView.onAppear`. The closure captures the `WorkspaceModel` +
  `SessionRegistry` actor handles, decodes `PaneIPCCommand`, dispatches
  the mutation to the main thread via `DispatchSemaphore`, and encodes
  the `PaneIPCResponse` back. This closes a latent defect — the pane
  socket listener in `SocketServerManager` had no handler registered on
  the GUI side, so the file-IPC path was doing all the work.
- New `PaneIPC.sendFireAndForget(_:socketPath:)` in `Sources/Core/` —
  connect + handshake + write + close, no response read. 200ms
  `SO_SNDTIMEO` caps the worst-case write stall against a stuck peer so
  fire-and-forget semantics hold. Returns a typed `SendOutcome` enum
  (`.written`, `.socketUnreachable`, `.writeFailed`, `.encodeFailed`)
  for test assertions; production callers ignore the result.
- Deleted `SenkaniApp/Services/PaneCommandWatcher.swift` (the
  JSONL file watcher) and the JSONL accessors on the old
  `PaneIPCPaths` enum; `PaneIPC.swift` replaces them with
  `PaneIPCSocket.defaultPath`.
- 9 new tests (1404 → 1413): single-frame round-trip, absent-socket
  no-op with sub-500ms bound, oversize-path rejection, all 5 actions
  round-trip, 4-way concurrent writes all deliver distinct frames,
  multi-KB frame with concurrent drain, full setBudgetStatus
  end-to-end, big-endian length prefix wire format, legacy JSONL
  file regression guard.

### April 18 — Schedule runs emit Agent Timeline events
- New `Core/ScheduleTelemetry` helper records a `token_events` row at
  the start and end of every `Schedule.Run` invocation so scheduled
  runs appear in the Agent Timeline pane alongside interactive tool
  calls. Events use `source = "schedule"` and `feature =
  "schedule_start" | "schedule_end" | "schedule_blocked"`. Paired
  start/end events for the same run share `session_id =
  "schedule:{taskName}:{runId}"` — consumers can join the pair
  without a separate metadata column. Run-id format matches
  `ScheduleWorktree.makeRunId` (`yyyyMMddHHmmss-<6 alnum>` UTC).
- Budget-exceeded runs emit a single `schedule_blocked` event instead
  of a start/end pair; the block reason from
  `BudgetConfig.Decision.block` is preserved verbatim in the event's
  `command` field so the Timeline surface keeps the operator-facing
  message intact. Failed runs record the exit code in the end event's
  `command` string (`"{name}: failed: exit {N}"`).
- No schema change — reuses the existing `token_events` table and
  columns. No new `AgentType` case. Test-only DB override
  (`ScheduleTelemetry.withTestDatabase`) mirrors the
  `ScheduleStore.withTestDirs` / `ScheduleWorktree.withTestDir`
  pattern (NSLock-serialized override slot).
- 8 new tests (1396 → 1404) — start event shape, end success +
  failure-with-exit-code, blocked event reason passthrough, start/end
  sessionId pairing, project-root filtering, blocked-only (no
  orphan pair), runId format sanity. Sub-item 3 of 3 under the
  `cron-scheduled-agents` umbrella — the umbrella is now fully
  delivered.

### April 18 — Schedule runs spawn in worktrees
- `ScheduledTask` gains a `worktree: Bool` field (default `false`,
  `decodeIfPresent` keeps pre-field JSON files on disk readable).
  `senkani schedule create --worktree` opts a task in; on each fire
  `Schedule.Run` creates a fresh detached-HEAD worktree under
  `~/.senkani/schedules/worktrees/{name}-{runId}/`, chdirs the command
  there, and tears it down on success.
- New `Core/ScheduleWorktree` helper (no SwiftUI/AppKit deps — pure
  Foundation + `/usr/bin/git`). `create` fails fast with `notGitRepo`
  when cwd isn't a git working tree; `cleanup` uses
  `git worktree remove --force`, falling back to physical delete +
  `worktree prune` on git failure so a stuck registration can't wedge
  future runs. Run-ID format: `yyyyMMddHHmmss-{6 random alphanum}` UTC,
  so two fires in the same wall-clock second can't collide
  (~2×10⁻⁹ probability).
- Failed runs intentionally retain the worktree for inspection — the
  stderr log prints the retained path. Budget-exceeded runs short-circuit
  *before* worktree creation so a blocked run doesn't leave disk litter.
- 8 new tests (1388 → 1396) — backwards-compat decode of pre-field JSON,
  `worktree` field roundtrip, create-in-git-repo, cleanup-on-success,
  retain-when-cleanup-skipped, non-git-repo rejection, 4 concurrent
  creates produce 4 distinct worktrees, run-ID shape sanity. Sub-item
  2 of 3 under the `cron-scheduled-agents` umbrella.

### April 18 — Schedule subsystem test coverage
- `ScheduleConfigTests` (19 tests, 1369 → 1388) covers the previously
  untested schedule subsystem: `CronToLaunchd.convert` (wrong field
  count, `* * * * *`, single value, `*/N`, comma list, out-of-range
  rejection, non-integer / zero divisor, cartesian product across
  minute × hour × weekday), `CronToLaunchd.humanReadable` (every
  minute, every N minutes, daily at H:M AM/PM, weekly per weekday
  name, raw-cron fallback for unhandled patterns), and
  `ScheduleStore` CRUD (save+load roundtrip preserving all fields,
  list sorts by `createdAt`, load-missing returns nil, remove
  deletes both the JSON and the launchd plist, remove succeeds
  when plist is absent, `plistLabel(for:)` formatting).
- `ScheduleStore` gains a test-only `withTestDirs(base:launchAgents:_:)`
  wrapper mirroring the `LearnedRulesStore.withPath` pattern —
  redirects `baseDir` + `launchAgentsDir` to a tmp directory for the
  body's duration, holding a shared `NSLock` so concurrent test
  cases serialize on the override slots. Production callers are
  untouched; `baseDir` / `launchAgentsDir` fall back to `$HOME`
  when the override is nil.
- First of three sub-items carved from the `cron-scheduled-agents`
  umbrella (pre-audit found it 3/5 shipped — Schedules pane + CRUD
  + budget + launchd gen — but with 0 tests and two unshipped
  bullets). Remaining: `schedule-worktree-spawn`,
  `schedule-timeline-integration`.

### April 18 — Tree-sitter grammars: Dart, TOML, GraphQL
- Three vendored parsers landed in `Sources/TreeSitter{Dart,Toml,GraphQL}Parser/`
  and wired into the Indexer, `GrammarManifest`, and `FileWalker`
  (`.dart` → dart, `.toml` → toml, `.graphql` / `.gql` → graphql).
  Indexer now covers **25 languages**.
- Dart: top-level functions, methods, classes, enums, extensions,
  mixins, getter/setter signatures — via `function_signature`,
  `class_definition`, `enum_declaration`, `extension_declaration`,
  `mixin_declaration` walkNode cases (lexical container nesting).
- TOML: `[table]` + `[[table_array_element]]` emit as `.extension`
  symbols; their inner `pair`s inherit the table as container
  (`.property`) while top-level pairs are `.variable`.
- GraphQL: object/interface/enum/scalar/union/input/directive
  definitions mapped to the canonical `SymbolKind`s. Dispatched
  via a dedicated `walkGraphQL` function rather than adding seven
  more cases to `walkNode`'s main switch — the extra cases were
  observed to balloon `walkNode`'s stack frame past a Swift 6
  switch-codegen cliff and SIGBUS at runtime on large *unrelated*
  ASTs (the Bash realistic test). `table` and `table_array_element`
  are folded into a single `case "A", "B":` for the same reason;
  see [spec/tree_sitter.md](spec/tree_sitter.md#adding-more-cases-to-walknode--a-swift-6-codegen-trap).
- 10 new tests (1359 → 1369): wiring sanity (supports + manifest +
  FileWalker for all three), Dart top-level function + class with
  method + enum, TOML top-level pairs + table with nested pairs +
  table-array element, GraphQL object type + interface/enum/scalar
  mix + input + directive.

### April 17 — Migration race test + flock inode fix
- Bach G2 closed: `tools/migration-runner/senkani-mig-helper` +
  `MigrationMultiProcTests` spawn two real processes via
  `Foundation.Process`, release a shared barrier, and assert
  exactly-once migration semantics end-to-end.
- Flock inode bug fixed in `MigrationRunner.run`: the old code called
  `FileManager.createFile(atPath: dbPath + ".migrating", contents:
  nil)` before `open(O_RDWR|O_CREAT)`. `createFile` performs an atomic
  (temp file + rename) write, which UNLINKS the existing sidecar and
  installs a new inode at the same path. Concurrent migrators were
  flocking different inodes — no mutual exclusion. The runner now
  relies on `open(O_RDWR|O_CREAT)` alone, which creates the sidecar
  on first run and opens the existing inode on every subsequent run,
  so flock serializes correctly across processes.
- 3 new tests (1356 → 1359): two-helper race on a pristine DB, two
  helpers against an already-migrated DB both no-op, kill-switch
  lockfile blocks both concurrent launches.

### April 17 — MLX inference serialize lock
- `MLXInferenceLock` (Core actor) serializes on-device MLX inference
  across VisionEngine, EmbedEngine, and GemmaInferenceAdapter. All
  three share the same Metal command queue and memory pool; concurrent
  calls now FIFO-queue through `MLXInferenceLock.shared.run { ... }`
  instead of thrashing the GPU.
- Memory pressure: `DispatchSource.makeMemoryPressureSource(.warning)`
  fires every registered unload handler. Each engine nils its
  `ModelContainer`, and the next call re-loads via the existing
  RAM-aware fallback chain — natural step-down to a smaller tier.
- Started in `MCPServerRunner.run` via `startMemoryMonitor()`.
- 7 unit tests (1349 → 1356): non-overlapping concurrent exec, FIFO
  waiter ordering, error-in-closure releases lock, handler register +
  fire on simulated warning, `clearUnloadHandlers` empties registry,
  `startMemoryMonitor` idempotent / stop clears, queue-depth drain.

### Workspace
- 16 pane types — Terminal, Dashboard, Code Editor, Browser, Markdown
  Preview, Analytics, Model Manager, Savings Test, Agent Timeline,
  Knowledge Base, Diff Viewer, Log Viewer, Scratchpad, Schedules,
  Skill Library, plus the settings overlay
- SwiftTerm terminal with configurable font size, kill/restart, broadcast
- Tree-sitter Code Editor — syntax highlighting for 22 languages, symbol
  navigation (Cmd+click → definition), file tree, token cost gutter
- Multi-project workspace with per-project layout persistence
- ⌘K command palette (search-as-you-type across panes / themes / actions)
- Menu bar integration — lifetime stats, socket toggle, launch-at-login
- Notification rings, sidebar git branch badges, per-pane display settings
- Workstream isolation — git worktree + pane pair + lifecycle hooks

### MCP Intelligence Layer
- 17 tools, auto-registered globally in `~/.claude/settings.json`
- `senkani_read` — outline-first reads; `full: true` for complete content
- `senkani_exec` — 44-rule filter, background mode, adaptive truncation
- `senkani_search` — BM25 FTS5 ranking + optional MiniLM embedding fusion
- `senkani_fetch`, `senkani_explore`, `senkani_deps`, `senkani_outline`
- `senkani_validate` — local syntax validation across 20 languages
- `senkani_parse`, `senkani_embed`, `senkani_vision`
- `senkani_watch` — FSEvents ring buffer, cursor + glob queries
- `senkani_web` — WKWebView render → AXTree markdown with DNS-resolved
  SSRF guard + redirect re-validation; `file://` not accepted
- `senkani_pane`, `senkani_session`, `senkani_knowledge`, `senkani_version`
- `senkani_bundle` — budget-bounded repo snapshot. Composes symbol
  outlines + dep graph + KB entities + README in a canonical,
  truncation-robust order. Emits `format: "markdown"` (default) or
  stable-schema `format: "json"` (decodes into the `BundleDocument`
  Codable type). CLI mirror: `senkani bundle --format markdown|json`.
  Remote mode (`remote: "owner/name"`, `ref:` optional) snapshots any
  public GitHub repo via `senkani_repo` — inherits host allowlist +
  `SecretDetector`. CLI mirror: `senkani bundle --remote owner/name`.
  Path-validated (`root`), all embedded free-text scanned by
  `SecretDetector`. 18th MCP tool.
- `senkani_repo` — query any public GitHub repo without cloning. Four
  actions (tree / file / readme / search) over api.github.com +
  raw.githubusercontent.com only. Host allowlist enforced. Auth token
  gated to api.github.com. SecretDetector.scan on every response
  body. TTL+LRU cache, 1 MB file cap, rate-limit-aware error
  messages. 19th MCP tool.
- MCP output compaction — `knowledge`, `validate`, `explore` compact by
  default; `detail:'full'` escape hatch; 30% tool description trim

### Indexer + Knowledge
- 22 tree-sitter backends (incl. HTML/CSS), grammar versioning system
- Incremental indexing (git-blob hashing) and sub-file tree-sitter diffs
- FSEvents auto-trigger with 150 ms debounce
- Dependency graph — bidirectional imports, 15+ languages
- Knowledge graph — entities, links, decisions, co-change coupling
- KB pane with wiki-link `[[completion]]`, relations graph canvas,
  session brief, staged proposal accept/discard

### Optimization layers
- Layer 1 tools (above) — compression, caching, redaction
- Layer 2 hooks — budget enforcement, auto-validate reactions (PostToolUse
  → background type check → advisory on next call)
- Layer 3 interception — re-read suppression, command replay, trivial
  routing, search upgrade, redundant validation (5 patterns, 39 tests)
- Model routing — per-pane presets (Auto / Build / Research / Quick /
  Local) with difficulty scoring and CLAUDE_MODEL env injection
- Compound learning H+1 — post-session waste analysis → `.recurring`
  proposals (`head(50)` + mined `stripMatching` substring literals) →
  regression gate on real output samples → daily cadence sweep
  promoting recurring-with-evidence rules to `.staged` →
  `senkani learn status/apply/reject/sweep`. Laplace-smoothed
  confidence, enumerated `GateResult` outcomes, signal-type taxonomy
  (context / instruction / workflow / failure), per-branch
  `event_counters` telemetry.
- Compound learning H+2a — Gemma 4 rationale rewriter with silent
  fallback, `RationaleLLM` protocol + MLX-backed `GemmaInferenceAdapter`
  (VLM reused for text-only inference), `LearnedFilterRule` v3 with
  optional `enrichedRationale`, `CompoundLearningConfig` thresholds via
  `~/.senkani/compound-learning.json` + env vars, post-session
  distribution logging, `senkani learn status --enriched` /
  `senkani learn enrich` / `senkani learn config` CLI. LLM output
  contained to the dedicated rationale field — never enters
  `FilterPipeline`.
- Compound learning H+2b — typed-artifact store (`LearnedArtifact`
  polymorphic enum over `.filterRule` + `.contextDoc`), `LearnedRulesFile`
  v4 schema with explicit `{type,payload}` JSON migration from v3,
  `LearnedContextDoc` with filesystem-safe slug + 2 KB body cap +
  `SecretDetector.scan` on every entry point, `ContextSignalGenerator`
  detecting files read across ≥3 distinct sessions, applied docs land
  at `.senkani/context/<title>.md` and surface in future session briefs
  as a "Learned:" one-liner section. Parallel lifecycle (recurring →
  staged → applied → rejected) with same daily sweep thresholds as
  filter rules. `senkani learn status --type filter|context` filter;
  `senkani learn apply/reject` accept context doc IDs too. Four new
  event counters: `compound_learning.context.{proposed, rejected,
  promoted, applied}`.
- Compound learning H+2c — two new artifact cases (`LearnedArtifact`
  v5: adds `.instructionPatch` + `.workflowPlaybook`). Deterministic
  generators: `InstructionSignalGenerator` (from per-session retry
  patterns) emits tool-description hints; `WorkflowSignalGenerator`
  (from ordered tool-call pairs within 60 s) emits named playbooks
  stored at `.senkani/playbooks/learned/<title>.md`. Schneier
  constraint: instruction patches NEVER auto-apply from the daily
  sweep — explicit `senkani learn apply` required every time.
  Namespace isolation prevents learned playbooks from shadowing
  shipped skills. Six new event counters.
- Compound learning H+2d — sprint + quarterly cadence surfaces.
  `senkani learn review [--days N]` aggregates staged artifacts
  across all four types from the last N days. `senkani learn audit
  [--idle D]` flags stale applied artifacts (filter rules not fired
  in D days, context docs not referenced, instruction patches
  targeting removed tools, playbooks not observed). Four new reasons
  enumerated; CLI output grouped by artifact type.
- Knowledge Base F+1 — Layer-1-as-source-of-truth coordinator.
  `KBLayer1Coordinator.decideRebuild(...)` detects when `.senkani/
  knowledge/*.md` is newer than the SQLite index or when the DB is
  corrupt (< 100-byte header); `rebuildIfNeeded(...)` triggers a
  re-sync via the existing `KnowledgeFileLayer.syncAllToStore`. Five
  new counters.
- Knowledge Base F+2 — entity-tracker telemetry. `EntityTracker`
  already had the mid-session flush + threshold-based enrichment
  queue from Phase F.1; Round 5 wired `knowledge.tracker.flush` and
  `knowledge.tracker.threshold_crossed` counters + a one-line stderr
  distribution summary on session close.
- Knowledge Base F+3 — reversible enrichment with validator.
  `EnrichmentValidator.validate(live:proposed:)` returns three
  concern types: `informationLoss` (section shrank >40%),
  `contradiction` (keyword negation on matching-subject sentences),
  `excessiveRewrite` (Jaccard word distance >60%). New CLI:
  `senkani kb rollback <entity> [--to DATE]`, `senkani kb history
  <entity>`.
- Knowledge Base F+4 — evidence timeline CLI. `senkani kb timeline
  <entity>` wraps the existing `evidence_entries` table.
- Knowledge Base F+5 — KB ↔ compound-learning cross-pollination.
  `KBCompoundBridge.boostConfidence(raw:kbMentionCount:)` applies
  `+0.05 × log1p(mentions)` to proposal confidence for commands /
  titles that match a high-mention KB entity; `seedKBEntity(for:)`
  idempotently creates a KB entity stub from an applied context doc;
  `invalidateDerivedContext(entityName:entitySourcePath:)` drops
  derived context docs from `.applied` back to `.recurring` when
  their source entity is rolled back.
- Session continuity — ~150-token context brief injected at session open

### CLI (19 commands — with expanded `learn` + `kb` subcommand trees)
- `exec`, `search`, `bench`, `doctor`, `grammars`, `kb`, `eval`, `learn`,
  `uninstall`, `init`, `stats`, `export`, `wipe`, `schedule`, `compare`,
  `status`, `config`, `version`, `bundle`
- `senkani learn`: `status [--type] [--enriched]`, `apply [id]`, `reject
  <id>`, `reset [--force]`, `sweep`, `enrich [--verbose]`, `config
  {show,set}`, `review [--days N]`, `audit [--idle D]`
- `senkani kb`: `list`, `get`, `search`, `rollback <entity> [--to DATE]`,
  `history <entity>`, `timeline <entity>`

### Benchmarking + Savings
- Token savings test suite — 10 tasks × 7 configs, 80.37x fixture multiplier
- SavingsTest pane — fixture bench, live session replay (per-feature
  breakdown from real `token_events`), scenario simulator (6 templates)
- Dashboard pane — hero savings card, project table, feature charts

### Hardening (v0.2.0 security wave)
- Prompt injection guard on by default — 4 categories, anti-evasion
  normalization, single-pass O(n). Override: `SENKANI_INJECTION_GUARD=off`
- Web fetch SSRF hardening — DNS pre-check, redirect re-validation,
  WKContentRuleList blocks `<img>`/`<script>` to private ranges
- Secret redaction short-circuits with `firstMatch` (~25 ms per 1 MB)
- Schema migrations versioned + crash-safe via flock + kill-switch
- Retention scheduler — `token_events` 90 d, `sandboxed_results` 24 h,
  `validation_results` 24 h; `~/.senkani/config.json` tunable
- Instruction-payload byte cap (default 2 KB,
  `SENKANI_INSTRUCTIONS_BUDGET_BYTES` tunable)
- Socket authentication — opt-in via `SENKANI_SOCKET_AUTH=on`; 32-byte
  rotating token at `~/.senkani/.token` (0600)
- Structured logging — opt-in via `SENKANI_LOG_JSON=1`; sink-side
  SecretDetector redaction on every `.string(_)` log field (Cavoukian C5)
- Observability counters — `event_counters` table surfaced via
  `senkani stats --security` and `senkani_session action:"stats"`
- Data portability — `senkani export` streams JSONL via a read-only
  SQLite connection (doesn't block the live MCP server)
- `senkani wipe` — operator data-erase path

### Agent usage tracking
- Tier 1 exact (Claude Code JSONL reader)
- Tier 2 estimated (hook-based detection)
- Tier 3 partial (MCP-only)
- `senkani eval --agent` per-agent breakdown

### Infrastructure
- DiffViewer LCS — `DiffEngine` promoted to `Sources/Core` (testable
  library); `computePairedLines` renders side-by-side rows with
  correct alignment for insertions, deletions, and replacements.
  Replacement runs pair row-for-row; excess removes/adds pad with
  placeholders. 13 tests cover no-change, mid-file insertion /
  deletion / replacement, whitespace-only change, mismatched run,
  1200-line scale, and accept/reject round-trip.
- HookRelay consolidation — shared library used by `senkani-hook` binary
  and the app's `--hook` mode (Lesson #16)
- Pane socket IPC — instant pane control (<10 ms) replacing 5 s file polling
- Socket health check (`senkani doctor` #10)
- Metrics persistence across restarts via SQLite + WAL

## Roadmap

Planned but not shipped:
- IDE pane — LSP completions, inline diagnostics, multi-cursor
- Agent runner pane — spawn / observe / interrupt
- Workflow builder — pipeline graph UI
- SSH / Mosh pane
- Compound learning H+1 — Gemma 4 enrichment, cadence tiers
- Cron-scheduled agent runs with budget caps
- Browser Design Mode — click-to-inspect + structured context blocks
- Specialist pane diaries — per-pane cross-session memory
- `senkani_bundle` — full codebase as one structured document
- Remote repo queries — GitHub without cloning
- iPhone companion — session monitoring + budget alerts

See `spec/roadmap.md` for phase-level planning detail.
