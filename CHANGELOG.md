# Changelog

All shipped features live here so the README can stay focused on what
Senkani *is*. Entries are grouped by the server version reported by
`senkani_version` (see `VersionTool.serverVersion`).

## v0.2.0 — 2026-04 (current)

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
