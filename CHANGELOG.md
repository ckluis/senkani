# Changelog

All shipped features live here so the README can stay focused on what
Senkani *is*. Entries are grouped by the server version reported by
`senkani_version` (see `VersionTool.serverVersion`).

## v0.2.0 — 2026-04 (current)

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
