# Changelog

All shipped features live here so the README can stay focused on what
Senkani *is*. Entries are grouped by the server version reported by
`senkani_version` (see `VersionTool.serverVersion`).

## v0.3.0 — unreleased

_Add new entries here as work ships. Promote this section to a
dated heading at release time._

### April 29 — Diátaxis Documentation Standard + structural docs-shape lint (`phase-w6-diataxis-doc-split`, W.6)
- `spec/spec.md` gains a **Documentation Standard** section
  codifying the four Diátaxis shapes — tutorial (learning-oriented
  set-up), how-to (task-oriented recipes), reference (schemas +
  APIs), explanation (why it exists) — as the docs requirement for
  every Phase T/U/V/W component before its Exit Criteria are
  checked. The section includes the canonical tutorial-vs-how-to
  distinction (different reader posture, different page) and a
  "ship the explanation page first" heuristic so the other three
  shapes don't drift on shared vocabulary.
- `Sources/Core/DocsShapeLint.swift` ships the structural lint:
  `DocsShape` enum, `ComponentDocs(id:paths:)` manifest, and
  `DocsShapeLinter.lint(components:fileSystem:)` returning
  `DocsShapeIssue` rows for missing declaration, missing-on-disk
  file, or zero-byte stub. `FileSystemProbe.real` is the default;
  tests inject `.inMemory(files:)`. Length / quality / freshness
  checks are deliberately out of scope — the v1 gate is binary and
  fast so authors can't argue about whether a paragraph "counts."
- `Tests/SenkaniTests/DocsShapeLintTests.swift` (4 tests, target
  was 4): all-shapes-present clean pass, missing-declaration flags
  the right shape, declared-but-missing-file flags `fileNotFound`,
  and a multi-component fixture with mixed missing + empty
  conditions reports both issues in deterministic order.
- `spec/roadmap.md` W.6 row flips to ✅ SHIPPED with per-round
  detail.

### April 29 — Quant-frontier review cadence + first 2026-Q2 report (`phase-w5-quant-frontier-cadence`, W.5)
- `spec/ml_models.md` gains a "Quantization Frontiers" subsection
  defining a quarterly review cadence (first business day of every
  quarter), the per-candidate tracking schema (KL-max, imatrix
  calibration mix, license, recipe class, footprint), and a binding
  five-condition **promotion gate** — any candidate Gemma 4 quant
  must beat the incumbent by ≥10 % on KL-max at equal-or-smaller
  RAM, carry imatrix coverage of chat + code + tool-calling, post
  `acceptable+` on `senkani ml-eval` real-machine, stay in-family
  (no third on-device model family), and ship under a permissive
  license. The section is explicitly walled off from the routing
  surface so quant fashion never leaks into request-path code.
- First quarterly report ships at
  `~/.senkani/reports/quant-frontier-2026-Q2.md`. Reviews APEX
  (Qwen3.6-35B-A3B + the `gemma-4-*-APEX-GGUF` family forward
  signal), Ternary Bonsai (1.58-bit), and dots.ocr against the
  promotion gate. Outcome: zero promotions — APEX recipe wins are
  absorbed as policy (KL-max as headline metric, imatrix calibration
  mix as the target, per-variant "best for" labels), Bonsai is
  flagged as a forward signal for any future ≤2-bit Gemma 4 release,
  dots.ocr is rejected as a third family but flagged as a candidate
  for the OCR-specialist path *inside* `senkani_vision` (out of W.5
  scope).
- Cadence on the team calendar: recurring quarterly, first business
  day of the quarter. Next review 2026-07-01.
- Zero code, zero new tests; W.5 is a policy round. "Two Models, Not
  Ten" remains the binding architectural constraint.

### April 29 — `ContextSaturationGate` + `PreCompactHandoffWriter` ship (`phase-w4-context-saturation-gate`, W.4)
- `Sources/Core/ContextSaturationGate.swift` ships the pure
  decision function. `evaluate(currentTokens:threshold:)` returns
  `.ok / .warn / .block` against a configurable
  `Threshold(warnAt:blockAt:budgetTokens:)`. Defaults follow
  Continuous Claude v4.7: warn 65 %, block 80 %, against a
  200 000-token active window. The `block` reason names the percent
  and tells the caller to write a handoff card before continuing.
- A DB-backed convenience overload reads `tokens_in + tokens_out`
  from `agent_trace_event` (V.2 canonical row) for a pane / project
  / time window, so callers don't have to thread the running total
  themselves. New `tokenUsage(...)` and `recentTraceKeys(...)`
  queries on `AgentTraceEventStore` plus public forwarders on
  `SessionDatabase`.
- `Sources/Core/PreCompactHandoffWriter.swift` ships the
  structured handoff card. `HandoffCard` is `Codable` with
  `schemaVersion` (currently 1), `sessionId`, `savedAt`,
  `contextPercent`, `openFiles`, `currentIntent`, `lastValidation`
  (outcome / file / advisory pulled from `validation_results`),
  `nextActionHint`, and `recentTraceKeys`. `write(_:rootDir:)`
  serialises to JSON, lands in a temp file, fsyncs, then renames
  into `<rootDir>/<sessionId>.json` (default `~/.senkani/handoffs/`)
  so a crash mid-write never leaves a half-card readable.
- `compose(...)` builds a card from `SessionDatabase` facts plus
  caller-supplied intent / openFiles / nextAction. The W.4 round
  ships the writer + composer; Hook-Router PreCompact wiring is
  W.4-bis (operator decision pending — needs a review of which
  hook payload fields the writer should auto-fill).
- `PreCompactHandoffLoader.load(sessionId:rootDir:)` and
  `loadLatest(rootDir:)` read a card on next-session start.
  Returns nil for missing files, corrupt JSON, OR cards written
  under a future schema version — Norman's "no fallback"
  policy: a card the next session can't trust is worse than no
  card.
- 15 new tests in `ContextSaturationGateTests` (6) +
  `PreCompactHandoffWriterTests` (9): every threshold band,
  custom thresholds, malformed-budget fallback, DB-backed
  derivation, Codable round-trip, atomic overwrite, real-clock
  <1 s SLO assertion (the W.4 acceptance row), DB-driven compose,
  missing-file / corrupt-JSON / future-schema → nil, and
  `loadLatest` mtime ordering. Full safe suite 2094 → 2109 green.

### April 29 — Markdown-first content negotiation ships (`phase-w2-markdown-first-fetch`, W.2)
- `Sources/Core/ContentNegotiator.swift` adds the three-tier
  fetch ladder used by `senkani_web` and `senkani_bundle`'s remote
  mode: `Accept: text/markdown` first, deterministic HTML→markdown
  transform on origin HTML, headless render only when both fail.
  Cheapest-correct-first per the markdown.new pattern, with
  caller-forceable tiers via `MarkdownFirstFetcher.fetch(url:method:)`
  (`.auto` default, `.transform`, `.render`).
- Every `ContentNegotiationResult` carries `tier`, `tokensEstimate`
  (`bytes/4`, the local-first analogue of `x-markdown-tokens`),
  `originBytes`, `needsRender`, and an optional `renderHint`. When
  tier 2 can't extract usefully, the raw HTML is handed back so the
  renderer doesn't pay a second fetch.
- `HTMLToMarkdown` is a protocol; the round ships a deterministic
  default transformer (strips `<script>` / `<style>` / `<head>` /
  `<svg>`, preserves `<h1>`–`<h6>`, paragraphs, list items, link
  syntax, and common HTML entities). The Gemma-4 adapter slot
  mirrors U.8's `ProseCadenceCompiler` DI pattern so Core stays
  MLX-free.
- 12 new tests in `ContentNegotiatorTests`: tier-1 native return +
  Accept header preference, tier-2 transform on HTML, tier-3
  render fallback (transformer-nil + empty body), `method=.render`
  short-circuits before any fetch, `method=.transform` forces tier 2
  even when origin advertises markdown, origin failure →
  `originUnreachable`, ≥40 % token reduction on a docs-page fixture,
  transformer preserves headings + drops `<script>`, transformer
  returns nil for empty input.
- Deferred to W.2-bis: live wire-up to `WebFetchTool` /
  `BundleTool` argument plumbing (`method` arg + `tokensEstimate`
  in tool-result metadata) and a Gemma-4-backed `HTMLToMarkdown`
  adapter (the deterministic transformer is the round-1 stand-in).

### April 29 — `senkani_search_web` MCP tool ships (`phase-w1-search-web-mcp`, W.1)
- `Sources/MCP/Tools/SearchWebTool.swift` adds `senkani_search_web`
  with DuckDuckGo Lite as the default backend. Schema:
  `{ query, limit (1–30, default 10), region (default "wt-wt"),
  recency ("any"|"d"|"w"|"m"|"y", default "any") }`. Returns
  formatted `{title, url, snippet}` triples in compact markdown.
- Defense in depth: URL builder pins the host to
  `lite.duckduckgo.com`; the backend re-checks the host pre-fetch,
  reuses `senkani_web`'s DNS-resolved private-range guard,
  rejects off-host redirects via a `URLSessionTaskDelegate`, and
  re-validates the final response host. Cookies disabled, ephemeral
  session per request.
- `guard-research` lands as a query-side filter at the tool
  boundary (`SearchWebQueryGuard`): blocks workstation paths
  (`/Users/`, `/etc/`, `~/...`, Windows drives), glob patterns
  (`/foo/*`, `**/*`), and any token flagged by `SecretDetector`.
  Public `site:` operators and ordinary phrase searches pass.
- Snippet + title outputs are passed through `SecretDetector`
  before formatting, so any third-party leak in DDG's organic
  results gets `[REDACTED:...]`-stamped before reaching the
  model. CAPTCHA / soft-block pages surface as a structured
  `BackendBlocked` error rather than silently returning zero
  results.
- `Sources/Core/Presets/PresetPrerequisiteCheck.swift` flips
  `senkani_search_web` and `guard-research` from "always warn"
  to ready — `autoresearch` and `competitive-scan` presets now
  satisfy those prerequisites against this binary.
- `Tests/SenkaniTests/SearchWebToolTests.swift` covers the parser
  (Lite-shaped HTML + CAPTCHA + entity decode + limit cap), the
  URL builder (region/recency/host pin), the `guard-research`
  filter (Unix paths + tilde-home + globs + ten secret families
  + clean queries), the redirect-pin delegate, the foreign-host
  rejection, end-to-end with an injected backend, and a
  100-fixture corpus that confirms every embedded secret-shaped
  token gets redacted in the formatted output. 23 new tests.

### April 29 — `NaturalLanguageSchedule` foundations (`phase-u8-natural-language-schedule`, U.8 round 1)
- `ScheduledTask` (in `Sources/Core/ScheduleConfig.swift`) gains
  optional `proseCadence`, `compiledCadence`, `eventCounterCadence`,
  and `locale` JSON fields. Backward-compat decoding: pre-U.8
  task JSON on disk decodes with these fields as `nil` and renders
  in the Schedules pane exactly as before.
- `Sources/Core/ProseCadenceCompiler.swift` defines the
  prose-to-cron protocol with `NullProseCadenceCompiler` (default
  when no LLM is installed; throws `.unavailable` so callers can
  fall back to operator-entered cron) and `MockProseCadenceCompiler`
  (test-time adapter that validates emitted cron via `CronToLaunchd`
  before returning a `ProseCadence`). Mirrors the `RationaleLLM`
  pattern — Core stays MLX-free; the production Gemma 4 adapter
  lives in MCPServer / App and wires in via DI when the model
  is downloaded.
- `Sources/Core/CronPreview.swift` emits the next N fire times
  for a 5-field cron string by walking minute-by-minute against
  `CronToLaunchd`'s launchd-interval expansion. Powers a
  Schedules-pane "show next 5 fires" tooltip + the
  `AmplificationGuard` sub-minute check; horizon caps at 1 year
  to terminate on degenerate crons.
- `Sources/Core/CounterCadenceRateLimiter.swift` is the
  in-process per-schedule rate limiter for counter-driven
  cadences ("every 10 tool_calls"). Default ≤ 1 fire / 60 s,
  per-schedule independent windows, NSLock-guarded. Defends
  against the Hermes amplification scenario where a power user
  fires 100 sessions in a day.
- `Sources/Core/AmplificationGuard.swift` is the pre-save
  validator: returns `.ok` or `.amplification(reason, floor)`
  for prose that compiles to a sub-minute cron OR for counter
  cadences with N ≤ 1. Includes `CounterCadence.parse` for
  "every N events" / "every Nth event" expressions.
- `SenkaniApp/Views/ScheduleView.swift` task row now surfaces
  prose / counter cadences with a tooltip exposing the compiled
  cron; cron-direct rows fall through to the existing
  human-readable cron rendering.
- 13 new tests in `Tests/SenkaniTests/NaturalLanguageScheduleTests.swift`
  cover Codable backward-compat, prose round-trip,
  Null/MockProseCadenceCompiler boundaries, CronPreview daily /
  weekly / invalid, rate-limiter block + allow + per-schedule
  isolation, AmplificationGuard amplification-detection +
  daily-cron pass, CounterCadence parsing.
- Deferred to follow-up u8b: Schedules pane "New Schedule" form
  prose input + "Show next 5 fires" preview button; real
  MLX-backed Gemma 4 adapter wiring; `HookRouter` post-tool
  counter-cadence runner that queries `SessionDatabase` event
  counts and fires the schedule subject to the rate limiter.

### April 29 — `PromptArtifactRegressionGate` + `ReflectiveLearningRun` (`phase-v4-regression-gate`, V.4 round 1)
- `Sources/Core/PromptArtifactRegressionGate.swift` is the V.4
  pre-merge gate for prompt-side artifacts (skills, hook prompts,
  MCP tool descriptions, brief templates) — distinct namespace
  from the Phase H+1 `RegressionGate`, which scores `FilterRule`
  savings deltas against `FilterEngine`. Bach's audit: distinct
  surfaces, distinct names, no payload-conflation. `EvalCorpus`
  is `[EvalCase]`; each case carries a `Requirement`
  (`.mustContain` / `.mustNotContain` / `.maxLength`) — round-1's
  three constructors cover the lowest-friction skill/hook
  invariants without committing to an LLM evaluator (V.4-bis
  extension point). `ArtifactScore = (passing, total, cost)`
  persists `total` for future uncertainty calibration (Gelman's
  audit) and `cost` as utf8 byte count of the body (Karpathy's
  audit: defensible token-cost proxy without a tokenizer in V.4).
  Gate accepts when `candidate.passing ≥ baseline.passing` (cost-
  only improvements are legal — the Pareto frontier filters
  dominated entries downstream); empty corpus and nil baseline
  accept unconditionally.
- `Sources/Core/ReflectiveLearningRun.swift` ships the
  `PromptMutator` protocol (Karpathy's "MutationStrategy" hook)
  and a five-mutator deterministic suite (`concise_prefix` /
  `trim_trailing_ws` / `drop_empty_lines` / `first_sentence_only`
  / `append_safety_footer`) as the round-1 stand-in. Karpathy red
  flag: this is **not** a GEPA implementation — round 1 is the
  scaffold; V.4-bis swaps in an MLX-backed mutator behind the
  same protocol. `ParetoFrontier.consider(_:)` enforces strict
  dominance (≥ on one dimension, > on the other), evicts
  dominated entries, and rejects exact-duplicate body+score
  pairs. Persistence: `<projectRoot>/.senkani/learn/pareto/<kind>.json`
  with `[.sortedKeys, .prettyPrinted]` + `.iso8601` JSON for
  byte-stable round-trip; per-kind partition means the four
  artifact kinds evolve independently.
- `Sources/Core/CompoundLearning.swift` adds
  `runReflectiveLearning(seed:corpus:projectRoot:mutators:db:)`
  — the V.4 Propose-step hook. Loads the existing frontier,
  runs the reflective loop, persists the merged frontier, and
  bumps `compound_learning.prompt_artifact.run` once per call +
  `compound_learning.prompt_artifact.proposed` by the
  newly-added entry count. **Operator-triggered**, not
  auto-fired in `runPostSession` (Schneier-style: silent prompt
  mutation churn is opt-in; V.4-bis adds a `senkani gate run`
  CLI + scheduled cadence).
- `spec/compound_learning.md` adds a "Phase V.4 — Prompt-side
  artifact gate" section documenting the corpus format, score
  shape, gate semantics, Pareto dominance rule, persistence
  layout, and the V.4-bis deferred work (LLM mutator, CLI
  surface, auto-fire, frontier UI, V.6-round-3 fails-evidence →
  EvalCase wiring).
- 20 new tests across two suites (`PromptArtifactRegressionGateTests`,
  `ReflectiveLearningRunTests`): score reports `passing`/`total`/
  `cost` honestly; vacuous-truth pct on empty corpus;
  equal-passing accepted (cost-only improvement legal);
  strictly-better accepted; **fixture-injected regression
  rejected (acceptance #1)**; nil baseline accepts; empty corpus
  accepts; `maxLength` counts utf8 bytes; strict dominance on
  lower-cost-same-passing; non-dominated coexist; ties
  distinguished by body; **save/load round-trips byte-stably +
  per-kind partition (acceptance #2)**; deterministic mutators
  are pure; run includes the seed; run drops dominated
  mutations; **`CompoundLearning.runReflectiveLearning` persists
  + bumps event counter (acceptance #3)**; idempotent re-run;
  stable `PromptArtifactKind.rawValue` contract.

### April 28 — `AnnotationStore` + signal generator backend (`phase-v6-annotation-system`, V.6 round 1)
- `Sources/Core/Migrations.swift` adds Migration v9 — a new
  `annotations` table. One row per operator-tagged segment of a
  skill or KB entity, append-only. Columns: `target_kind`,
  `target_id`, `range_start`, `range_end`, `verdict`
  (`works` / `fails` / `note`), `notes`, `authored_by`,
  `authorship` (the V.5 `AuthorshipTag` rawValue, explicit by
  construction), `created_at`, plus the three Phase T.5 chain
  columns (`prev_hash` / `entry_hash` / `chain_anchor_id`)
  nullable for forward compatibility. Three covering indexes —
  `(target_kind, target_id, created_at DESC)`,
  `(verdict, created_at DESC)`, and `(authorship)` — back the
  byTarget / verdict-rollup / authorship-pivot read paths.
- `Sources/Core/Stores/AnnotationStore.swift` owns the table:
  `record(_:)` returns the new rowid, `byTarget(kind:id:)` and
  `recent(limit:)` are newest-first reads, `verdictRollup(targetKind:)`
  buckets works/fails/note per `(kind, target)`, and
  `renameTarget(kind:fromId:toId:)` rewrites `target_id` so an
  artifact rename / fork preserves annotation lineage (Torres
  acceptance criterion).
- `Sources/Core/SessionDatabase+AnnotationAPI.swift` exposes the
  store on `SessionDatabase` matching the per-feature `+API.swift`
  convention: `recordAnnotation(_:)`, `annotationCount()`,
  `annotations(kind:id:)`, `recentAnnotations(limit:)`,
  `renameAnnotationTarget(kind:from:to:)`,
  `annotationVerdictRollup(targetKind:)`.
- `Sources/Core/AnnotationSignalGenerator.swift` is the read-side
  bridge to CompoundLearning Analyze. `analyze(db:targetKind:minTotal:limit:)`
  rolls up annotation rows into deterministic
  `AnnotationEvidence` rows tagged `failing` / `working` / `mixed`
  per a coarse classifier. Round 1 stops at evidence — no rule
  mutation, no auto-staging (Karpathy's red flag in the V.6
  audit synthesis: annotations are operator attestation, not
  agent inference).
- `Sources/Core/CompoundLearning.swift` adds
  `runAnnotationSignalDetection(projectRoot:db:)` and wires it
  into `runPostSession`. Each evidence row bumps
  `compound_learning.annotation.observed` plus a
  `compound_learning.annotation.{failing,working,mixed}` counter
  so operators can see the signal land via
  `senkani stats --security` without a UI surface.
- `Sources/Core/Stores/AnnotationStore.swift` ships three public
  enums: `AnnotationTargetKind` (`skill`, `kb-entity`),
  `AnnotationVerdict` (`works`, `fails`, `note`), and the
  `AnnotationVerdictRollup` / `AnnotationEvidence` structs that
  shape the analytics handoff.
- 12 new tests in `Tests/SenkaniTests/AnnotationStoreTests.swift`:
  schema shape; record + count; field round-trip; byTarget
  filtering + unknown empties; recent ordering + limit; rename
  preserves rows + does not cross kinds; verdictRollup buckets
  by works/fails/note; verdictRollup filters by kind;
  authorship `.unset` round-trip; the 100-fixture acceptance
  test that proves every annotation flows into
  `AnnotationSignalGenerator.analyze`; counters bump through
  `runAnnotationSignalDetection`.
- Accepted risks deferred to follow-up rounds: annotation rows
  schema-include but do not yet write the audit-chain hashes
  (V.6 round 2); SwiftUI annotation surface in SkillsLibrary /
  KnowledgeBase panes (V.6b); `fails` evidence → learned-rule
  Propose pathway (V.6 round 3).

### April 28 — `HandManifest` schema v1 + `senkani skill` CLI (`phase-u5-hand-manifest`, U.5 round 1)
- New `Sources/Core/HandManifest.swift` is the canonical
  capability-package shape: 13 fields covering identity
  (`name`, `description`, `version`), capability surface
  (`tools`, `settings`, `metrics`, `capabilities`), prompt
  structure (`system_prompt.phases`, `skill_md`), and runtime
  policy (`guardrails.requires_confirm/egress_allow/secret_scope`,
  `cadence.triggers/schedule`, `sandbox`).
- `Sources/Core/HandManifestLinter.swift` enforces 12 invariants
  Codable can't catch — schema-version pin, identity-field
  non-empty + kebab-case warning, phase non-empty,
  `requires_confirm` ⊆ `tools[]`, known `cadence.triggers`,
  non-empty `egress_allow` hosts. `lintJSON(_:)` surfaces decode
  failures as one error-severity issue at path `(decode)`.
- `Sources/Core/HandManifestExporter.swift` translates one
  manifest to five harnesses. First-class: `claude-code` (SKILL.md
  YAML frontmatter + sectioned phases) and `senkani` (WARP.md
  with `tools:` + `sandbox:` frontmatter). Shape-only: `cursor`
  (`.mdc` rule), `codex` and `opencode` (JSON envelope
  `{harness, manifest}`). Per-harness installer hardening lands
  in V.10 / V.11.
- `Sources/CLI/SkillCommand.swift` wires `senkani skill lint
  <path>` (with `--json`) and `senkani skill export --target
  <harness> <path>`. Export refuses to emit when lint reports
  errors. `Senkani.swift` registers `Skill.self` as a top-level
  subcommand.
- `spec/skills.md` is the frozen schema doc with field table,
  lint matrix, exporter status table, CLI surface, and round
  history. `spec/autonomous-manifest.yaml` adds the `skills`
  subsystem mapping so future doc-sync routes here.
- 20 new tests across three suites
  (`HandManifestTests`, `HandManifestLinterTests`,
  `HandManifestExporterTests`) covering happy-path decode,
  decode rejects unknown sandbox, multi-phase round-trip, every
  lint invariant, and one assertion per exporter target.

### April 28 — `agent_trace_event` canonical row + idempotency keys (`phase-v2-canonical-trace-row`, V.2)
- `Sources/Core/Migrations.swift` adds Migration v8 — a new
  `agent_trace_event` table with one wide row per tool call.
  Conformed dimensions: `pane`, `project`, `model`, `tier`,
  `feature`, `result`. Measures: `started_at`, `completed_at`,
  `latency_ms`, `tokens_in`, `tokens_out`, `cost_cents`,
  `redaction_count`, `validation_status`,
  `confirmation_required`, `egress_decisions`. The Stripe-style
  accumulator pre-rolls everything an analytics query would
  otherwise stitch from raw `token_events`. Three covering
  indexes — `(project, started_at)`, `(pane, started_at)`,
  `(feature, started_at)` — back the three pivot helpers.
- `idempotency_key` is `UNIQUE`. Writes go through
  `INSERT … ON CONFLICT(idempotency_key) DO NOTHING`, so a
  retry from the call site lands one row, not two. The dedup
  test fires 100 retries with the same key and asserts the
  table holds exactly one row.
- `Sources/Core/Stores/AgentTraceEventStore.swift` owns the
  writes + reads. Three pivots ship: `pivotByProject`,
  `pivotByFeature` (with success/failure split),
  `pivotByResult`. All three respect an optional `since:` filter.
- `Sources/Core/SessionDatabase+AgentTraceAPI.swift` exposes
  the public façade — `recordAgentTraceEvent`,
  `agentTracePivotByProject`, `agentTracePivotByFeature`,
  `agentTracePivotByResult`.
- `spec/architecture.md` documents the conformed-dimension
  vocabulary in a new "Canonical Trace Rows (Phase V.2)"
  section. Accepted risk: the canonical row is *derived*, so it
  is not chain-anchored — the source `token_events` rows are.
- 14 new tests in `Tests/SenkaniTests/AgentTraceEventStoreTests.swift`:
  schema shape, UNIQUE-constraint enforcement, 100-retry dedup,
  inserted-vs-deduped flag, distinct-keys split rows, full
  dimension/measure roundtrip, NULL-tier default (filled by U.1
  later), all three pivot rollups, NULL-project bucket, `since:`
  filter, coexistence with existing `token_events` analytics, and
  EXPLAIN-QUERY-PLAN proof the project index is used. The
  existing 161-test DB / store / migration / chain regression
  suite still passes.
- Reference: `spec/inspirations/analytics-visibility/stripe-canonical-log-lines.md`,
  `spec/inspirations/analytics-visibility/future-agi.md`.

### April 28 — MarkdownStreamingTranscoder Swift port (`phase-v8-markdown-streaming-transcoder`, V.8)
- `Sources/Core/MarkdownStreamingTranscoder.swift` ports the
  `@wterm/markdown` per-line dispatcher pattern to Swift. `push(_:)`
  appends delta chunks, splits on `\n`, processes complete lines to
  ANSI-styled output, and keeps the trailing partial line buffered
  for the next call. `flush()` drains the orphan tail and closes any
  open code fence. Inline scanner is a single forward pass: backtick
  code spans win first (their content is pasted verbatim), then `**`
  bold, `*` italic, and `[text](url)` links. Block dispatch covers
  ATX headings (`# … ######`), bullet lists (`-`/`*`/`+`), ordered
  lists (`N.`), and blockquotes (`> `). State is just `_buffer`,
  `_inCodeBlock`, and the open fence's language hint.
- `Tests/SenkaniTests/MarkdownStreamingTranscoderTests.swift` —
  10 tests covering the load-bearing wterm streaming describe:
  buffer-on-incomplete-line, multi-chunk pushes across line
  boundaries, code-fence open/close (including the rule that
  asterisks inside a fenced block survive verbatim), inline bold +
  italic, inline-code protecting its body from re-scan, headings +
  links, `flush()` draining an orphan code block, list items, the
  `transcode(_:)` static convenience, and a streaming jitter
  benchmark — 5 K-character corpus pushed one byte at a time
  finishes in ~4 ms (budget is <50 ms / three frames at 60 Hz).
- Reference: `spec/inspirations/native-app-ux/wterm.md` →
  "What Senkani Should Borrow / Concrete Senkani Actions". Terminal
  pane integration (route MCP-streaming text responses through the
  transcoder) is the follow-up wedge — the algorithmic core landed
  here so any caller can consume it.

### April 28 — KB markdown vault is configurable + portable (`phase-v7-knowledgebase-plain-md`, V.7)
- `Sources/Core/KBVaultConfig.swift` resolves the per-project
  knowledge dir against three layers: `SENKANI_KB_VAULT_ROOT` env
  override, `~/.senkani/config.json` `kb_vault_path`, then the
  legacy `<projectRoot>/.senkani/knowledge` default. When a vault
  root is configured, the resolved dir is `<vault_root>/<project-slug>`
  so multiple projects don't collide on entity name. `getenv` is read
  live so test setenv calls take effect without stale snapshots.
- `Sources/Core/KBVaultMigrator.swift` copies the vault between two
  directories, content-hash idempotent: `migrate` skips files already
  present byte-for-byte, surfaces conflicts (different content) as a
  separate list rather than silently overwriting, and never deletes
  the source unless the operator passes `--prune`. `unmigrate` is the
  same operation in reverse.
- `Sources/Core/WikiLinkResolver.swift` is the click-through resolver
  complementing `WikiLinkHelpers` completion. Stems resolve exact;
  multi-hits without a folder hint return `.ambiguous([URL])` so the
  caller can disambiguate; `folder/Name` and `nested/folder/Name`
  hints anchor the suffix of the path components.
- `Sources/CLI/KBCommand.swift` adds `senkani kb migrate --to <path>
  [--prune]` (persists path to `~/.senkani/config.json` for the next
  session) and `senkani kb unmigrate [--prune]` (clears the config
  key when pruning). Conflicts cause non-zero exit so the operator
  must reconcile manually — Cavoukian's "no silent data leak across
  vaults" rule.
- `Sources/Core/KnowledgeFileLayer.swift` gains
  `init(vaultDir:store:)` for explicit paths; the existing
  `init(projectRoot:store:)` is now a convenience that delegates
  through `KBVaultConfig.resolvedVaultDir`. Same plumbing in
  `KBLayer1Coordinator.decideRebuild` so staleness detection follows
  the relocated vault. The Layer-2 SQLite DB still pins to
  `<projectRoot>/.senkani/knowledge/knowledge.db` — derived state,
  not user-edited markdown.
- 12 new tests in `Tests/SenkaniTests/KBVaultV7Tests.swift` cover
  config defaults / env override / slug sanitization, migrator
  copy / idempotency / unmigrate / conflict-not-overwrite, resolver
  exact / folder-hint / ambiguous / not-found, and the layer
  end-to-end round-trip through `init(vaultDir:)`.
- All KB-touching test suites green: 12 new V.7 + 12 KnowledgeFileLayer
  + 5 KBLayer1Coordinator + 11 KBPaneViewModel + 14 WikiLinkCompletion
  = 54 tests. The full `swift test` run hits a pre-existing test-bundle
  SIGTRAP (verified to reproduce on `main` without these changes); see
  manual-log entry for the soak follow-up.

### April 28 — Authorship badges in KB / Timeline / Skills panes (`phase-v5d-authorship-ui-badges`, V.5 round 4)
- `Sources/Core/AuthorshipBadge.swift` is a pure-Core descriptor that
  is total over `AuthorshipTag?` × `BadgeContext`
  (`.knowledgeBase` / `.timeline` / `.skills`). It returns a
  `(label, weight, tooltip)` triple where `Weight` distinguishes the
  three explicit tags (`.explicit`), an in-band `.unset` row owing a
  decision (`.unset`), a legacy NULL on the KB (`.legacy`), and a
  surface that doesn't yet carry the column at all (`.untracked`).
  The three non-explicit weights all label as "Untagged" — the host
  never silently relabels a missing tag as AI / Human / Mixed
  (Cavoukian's V.5 contract).
- `SenkaniApp/Views/AuthorshipBadgeView.swift` is the SwiftUI host —
  monospaced 8-pt capsule with surface-aware tooltips. Visual weight
  scales: `.explicit` rides the KB accent, `.unset` shows a small
  orange nudge for the operator's decision, `.legacy` and `.untracked`
  fade into the row chrome.
- Wiring: `KnowledgeBaseView` renders the badge in the entity row and
  the entity detail header (real authorship column);
  `AgentTimelinePane` renders the `.untracked` badge on every timeline
  row with a tooltip explaining that `token_events` doesn't carry the
  column today; `SkillBrowserView` does the same for the skill list
  row + skill detail header (filesystem-scanned, no DB column).
- 10 new tests in `Tests/SenkaniTests/AuthorshipBadgeTests.swift` lock
  the explicit-tag → label/weight/tooltip mapping, the no-silent-
  inference contract across every untagged cell, the explicit-tag
  context-invariance, and the Podmajersky single-sentence ≤150-char
  tooltip rule.
- 1948 → 1958 tests green; build green via `swift test --no-parallel`.

### April 28 — `senkani authorship backfill` CLI (`phase-v5c-authorship-cli-backfill`, V.5 round 3)
- `Sources/CLI/AuthorshipCommand.swift` adds the operator-triggered
  `senkani authorship backfill --since YYYY-MM-DD --tag <aiAuthored|humanAuthored|mixed>`
  CLI for healing legacy NULL `authorship` rows on the KB
  (`knowledge_entities`). The in-band `.unset` sentinel is **never**
  overwritten — it represents an explicit operator deferral, distinct
  from the pre-V.5 NULL state. Without `--yes` the command prints a
  dry-run preview (count + project root + tag); `--yes` writes.
- `Sources/Core/KnowledgeStore/EntityStore.swift` gains
  `countNullAuthorship(since:)` and `backfillNullAuthorship(since:tag:)`.
  The UPDATE matches `created_at >= since AND authorship IS NULL` only,
  wrapped in `BEGIN IMMEDIATE`/`COMMIT`. Idempotent by construction —
  a second pass with the same args writes 0 rows because the predicate
  no longer matches.
- `Sources/Core/AuthorshipBackfillRunner.swift` bridges the KB write
  with the chain-participating audit log: each non-empty batch opens a
  fresh session in `SessionDatabase.shared` and records one row in the
  `commands` table with `tool_name="authorship.backfill"`. That row
  carries `prev_hash` / `entry_hash` / `chain_anchor_id` (Phase T.5
  round 3 chain) — the "self-audited row in the chain" required by
  V.5c.
- Cavoukian invariants: bulk operations are operator-triggered, never
  automatic; the CLI rejects `--tag unset` because backfill exists to
  record an explicit decision; `.unset` and the three explicit tags are
  preserved on every backfill pass.
- Tests: 7 new tests in `Tests/SenkaniTests/AuthorshipBackfillTests.swift`
  cover the SQL contract (since-cutoff, idempotency, `.unset` and
  explicit-tag preservation, all three explicit tags) plus the
  audit-chain runner integration (one chain row per non-empty batch
  with a 64-char SHA-256 entry_hash; no audit row on empty batches).

### April 28 — Save-path authorship prompt sheet (`phase-v5b-authorship-ui-prompts`, V.5 round 2)
- `Sources/Core/AuthorshipPromptResolver.swift` is a pure-Core resolver
  that owns the V.5b decision: `needsPrompt(priorAuthorship:)` returns
  true exactly when the row's stored tag is `.unset` (V.5 round 1
  sentinel) or `nil` (legacy NULL); the three explicit tags pass
  through silently. `resolve(choice:)` is a documented pass-through to
  `AuthorshipTracker.tag(forExplicitChoice:)` — no inference, no
  defaulting, no timeout-based silent resolution. Cavoukian's red flag
  holds: the operator is the sole authority on which tag a row carries.
- `SenkaniApp/Views/AuthorshipPromptSheet.swift` is the SwiftUI host
  for the resolver. Podmajersky-reviewed copy: 1-line verb-first
  question ("Who wrote this?", 16 chars), three buttons matching
  `AuthorshipTag.displayLabel` exactly (AI / Human / Mixed) with no
  preselected default, plus a tertiary "Skip for now" that returns
  control to the editor without saving (Skip preserves dirty state —
  it never silently writes `.unset` through this path).
- `KBPaneViewModel.saveUnderstanding()` now gates on
  `AuthorshipPromptResolver.needsPrompt`; when true it sets
  `pendingAuthorshipPrompt = true` and defers the write. The new
  `resolveAuthorship(_:)` and `skipAuthorship()` callbacks complete or
  abort the save; the existing fast path (prior tag explicit) preserves
  the row's authorship value verbatim. `KnowledgeBaseView` binds the
  flag to a `.sheet` modifier so the prompt surfaces inline in the KB
  pane.
- Bypass for headless callers is unchanged: `KnowledgeStore.upsertEntity(_,authorship:)`
  takes an explicit tag and never touches the prompt path.
  `KBCompoundBridge.seedKBEntity` (`.aiAuthored`) and tests that pass
  `authorship:` continue to work as before.
- Tests: 10 new tests in `Tests/SenkaniTests/AuthorshipPromptResolverTests.swift`
  covering the predicate (5 cases — `nil`, `.unset`, three explicit
  tags), the pass-through resolution invariant across all enum cases,
  the Podmajersky copy contract (verb-first / one-line / button labels
  match `displayLabel` / Skip distinct from primaries), and the
  end-to-end bypass round-trip on `upsertEntity`.

### April 28 — `AuthorshipTag` + KB schema migration v7 + `AuthorshipTracker` facade (`phase-v5-authorship-tracker`, V.5 round 1)
- `Sources/Core/AuthorshipTag.swift` adds the four-case provenance
  enum (`aiAuthored`, `humanAuthored`, `mixed`, **`unset`**) used by
  every artifact row from V.5 forward. Round 1 honors Gebru's red
  flag from the Phase 5 synthesis: `.unset` is the explicit "operator
  has not yet chosen" sentinel — never silently equivalent to
  `.humanAuthored`.
- `Sources/Core/AuthorshipTracker.swift` is a pure facade for
  resolving a tag from an explicit operator action. There is no
  inference path — every code site that wants a tag routes through
  one of three call surfaces (`tag(forExplicitChoice:)`,
  `tagForUnknownProvenance()`, `decode(_:)`). `grep -n
  "AuthorshipTracker"` finds every authorship resolution in the
  codebase.
- Migration v7 lands the `authorship` TEXT NULL column on
  `knowledge_entities`, with a non-unique index for read-side
  filtering. NULL is the legacy "pre-V.5 row" state and is distinct
  from the in-band `.unset` rawValue. New inserts always carry an
  explicit tag string.
- `EntityStore.upsertEntity(_:authorship:)` requires an explicit
  `AuthorshipTag` parameter (non-optional). The
  `KnowledgeStore.upsertEntity(_:authorship:)` facade defaults the
  parameter to `.unset`, which preserves source compatibility for
  ~75 existing test call sites without softening the contract — the
  default is the explicit unresolved sentinel, not silent inference.
- The two production callers in `Sources/Core/KBCompoundBridge.swift`
  (compound-learning seed → `.aiAuthored`) and
  `Sources/Core/KnowledgeFileLayer.swift` (markdown-vault sync →
  `.unset`, awaiting V.5b prompt) pass explicit tags.
- Tests: 13 new tests in `Tests/SenkaniTests/AuthorshipTrackerTests.swift`
  covering enum surface, facade pass-through invariants, decode
  round-trip + corrupt-row signal, schema column existence, all-cases
  upsert round-trip, conflict-overwrite, default-arg-lands-as-unset
  contract, and FTS5 search column-shift regression.
- Round 1 deliberately defers the V.5 UI prompts (`phase-v5b`),
  CLI backfill (`phase-v5c`), and pane badges (`phase-v5d`) — those
  ride on this round's enum + column foundation.

### April 27 — Partial-result notice strip + a11y on Dashboard tiles (`phase-v1c-pane-refresh-notice-ui`, V.1 round 3)
- `Sources/Core/PaneRefreshTileDisplay.swift` extracts a pure,
  unit-testable display projection of `PaneRefreshState`. Three
  tones — `normal`, `warning`, `error` — drive distinct tile chrome
  in `DashboardView.liveTileCard`: error renders a red strip with
  an `exclamationmark.octagon.fill`, notice renders a yellow strip
  with `exclamationmark.triangle.fill`, and the precedence rule
  ensures the UI never shows both at once (error wins).
- Each tile now sets `accessibilityLabel` so VoiceOver reads a
  single coherent phrase (e.g. "Budget Burn, partial: no spend
  yet") instead of an unlabeled stack of `Text` nodes.
- `paneRefreshFixtureFetch(failuresBeforePartial:notice:)` ships
  alongside the display helper as a test-mode fetch that injects
  `.failure` for the first N calls then `.partial(notice:)`,
  exercising the notice surface end-to-end through the worker pool.
- 6 new tests in
  `Tests/SenkaniTests/PaneRefreshTileDisplayTests.swift`: tone
  routing for normal / notice / error, error-precedence-over-notice,
  warming a11y label, and the 3-tick round-trip where the third
  tick flips the fixture from `.failure` to `.partial(notice:)` and
  the resulting display projects a warning strip with the expected
  a11y label.
- Test count: 1912 → 1918 (+6).
- Closes V.1 by clearing the deferred row "Partial-result notice
  rendered on a fixture-injected upstream failure" from the
  original V.1 acceptance.

### April 27 — `pane_refresh_state` persistence + Dashboard tile coordinator (`phase-v1b-pane-refresh-persistence`, V.1 round 2)
- `Sources/Core/Stores/PaneRefreshStateStore.swift` and migration v6
  add `pane_refresh_state` (project_root, tile_id, the seven Glance
  state fields, plus `prev_hash` / `entry_hash` / `chain_anchor_id`
  for tamper-evidence). Append-only by design — every
  `applyOutcome` writes a fresh row; `paneRefreshStates` reads
  latest-per-tile via `idx_pane_refresh_state_latest`. Writes go
  through `ChainState`, so verification + repair work the same
  way as the four T.5 chain participants.
  `ChainVerifier.verifyAll` now returns five entries (token_events,
  validation_results, sandboxed_results, commands,
  pane_refresh_state).
- `Sources/Core/PaneRefreshCoordinator.swift` owns the three round-2
  Dashboard tiles — budget burn (30 s), validation queue (5 s),
  repo dirty state (10 s) — under one `PaneRefreshWorkerPool`
  (default cap 4). `tick(now:)` sweeps every refresher whose
  `requiresUpdate` is true, persists the outcome, and bumps the
  `pane_refresh.persisted` counter. `rehydrate()` restores tile
  state on app start in one query and bumps the
  `pane_refresh.rehydrated` counter.
- `SenkaniApp/Views/DashboardView.swift` adds a "Live Tiles"
  section rendering the three coordinator-backed states; the
  existing 2 s timer drives both the legacy `refreshData` path
  and the new `coordinator.tick()` sweep. Visual polish for the
  notice strip ships in V.1 round 3 (`phase-v1c`).
- 9 new tests across
  `Tests/SenkaniTests/PaneRefreshStateStoreTests.swift` +
  `Tests/SenkaniTests/PaneRefreshCoordinatorTests.swift`:
  migration shape, append-only / latest-wins, bulk rehydrate,
  chain OK after clean writes, tamper detection at the right
  rowid, tick persists + surfaces outcomes, rehydrate round-trip,
  failure outcome propagates to snapshot, bounded pool peak ≤ 4
  across 12 simultaneous wakes.
- _Deferred to a follow-up:_ FSEvents-driven invalidation for
  `repo_dirty_state` (today's 10 s polling is the bridge), and
  rewiring the existing summary cards on the scheduler (V.1
  round 3 territory).
- Test count: 1903 → 1912 (+9).

### April 27 — `PaneRefreshScheduler` Core protocol layer (`phase-v1-pane-refresh-scheduler`, V.1 round 1)
- `Sources/Core/PaneRefreshScheduler.swift` ships the per-tile
  refresh contract borrowed from Glance's `widgetBase`. The
  `PaneRefreshScheduler` protocol declares `state`,
  `requiresUpdate(now:)`, `update(ctx:)`, `scheduleNextUpdate(now:)`,
  and `scheduleEarlyUpdate(now:)`. `PaneRefreshState` carries the
  seven required fields — `cacheType`, `cacheDuration`,
  `nextUpdate`, `retryCount`, `lastError`, `notice`,
  `contentAvailable`. `PaneCacheType` covers `infinite` /
  `duration` / `onTheHour`.
- `PaneRefreshOutcome` is `success` | `partial(notice:)` |
  `failure(error:)`. `success` clears retry count + error +
  notice and flips `contentAvailable` true. `partial` preserves
  prior `contentAvailable`, clears the error, and surfaces the
  notice — the Glance pattern for keeping a stale-but-usable tile
  on screen with an inline warning. `failure` bumps `retryCount`,
  records the error, and uses `PaneRefreshBackoff` (squared
  minutes, 1800 s default cap) for the early retry — capped by
  the natural `nextUpdate` so a slow-moving tile doesn't retry
  past its own freshness budget.
- `StatefulPaneRefresher` is the reference implementation:
  thread-safe via `NSLock`, takes a `@Sendable` fetch closure,
  exposes `replaceState` for round-2 SessionDatabase rehydration.
  `PaneRefreshWorkerPool` is a Swift actor with FIFO continuation
  waiters, bounded by `maxConcurrent` — Dashboard / Analytics /
  monitoring tiles dispatch through the pool so a wave of
  on-the-hour boundary updates doesn't fan out into a thundering
  herd.
- 17 new tests in `Tests/SenkaniTests/PaneRefreshSchedulerTests.swift`
  cover `requiresUpdate` for each `cacheType`,
  `scheduleNextUpdate` alignment (duration / onTheHour /
  infinite), squared backoff + cap-by-natural-nextUpdate,
  outcome semantics (success / partial / failure), and worker
  pool bounded concurrency + waiter queueing.
- **Split note:** V.1's full exit criteria require schema
  migration for scheduler-state persistence and three Dashboard
  tile migrations (budget burn, validation queue, repository
  dirty). Following the `phase-t5-audit-chain` precedent, those
  are spinning out as `phase-v1b-pane-refresh-persistence`
  (SessionDatabase + tile migrations) and
  `phase-v1c-pane-refresh-notice-ui` (DashboardView notice
  surface). Round 1 ships the protocol layer + worker pool only.

### April 27 — Paired-numbers section + companion-stack section in README + spec/app.md (`phase-v16-paired-numbers-readme`)
- `README.md` ships a top-level **Paired Performance Numbers**
  section that supersedes the old "Performance" + "About the
  numbers" block. The 80.37× fixture and the pending live-session
  median are cited together as a 2-row table; a "Why a pair"
  paragraph names the rule that 80× never appears unpaired
  outside the testing.md gate's `±4 lines` qualifier window. The
  full caveat link points at `spec/testing.md` Live Session
  Caveat. Adjacent sub-table now also surfaces hot-path SLOs and
  release commitments alongside the savings claim, per V.14
  dependency.
- `README.md` ships a new **Companion Stack (remote-operator
  pattern)** section after Building from Source. Tutorial-shaped
  per Procida: numbered steps for Tailscale (Personal $0) +
  Screens 5 ($179.99 lifetime / $29.99 yr) + Pushover (~$4.99 /
  platform, 10 k msgs/mo free), with the closed-loop narrative
  (Senkani job ends → Pushover push → `screens://<tailnet-host>`
  → Screens 5 opens that Mac's desktop). Disclaims explicitly
  that none of the three is a Senkani feature; names the
  durable contract as "any WireGuard mesh + any VNC client +
  any HTTP-API push service." Links to
  `spec/inspirations/native-app-ux/tailscale-plus-screens-5.md`.
- `spec/app.md` ships a top-level **Paired Performance Numbers**
  section after "Invisible Optimization vs On-Demand Inspection"
  documenting the same pairing rule for the in-spec audience —
  with a note that `tools/check-multiplier-claims.sh` is the
  automated gate enforcing the contract.
- `tools/check-multiplier-claims.sh` continues to pass — every
  80.37× / 80× mention is paired with `fixture` / `live` /
  `synthetic` / `pending` qualifiers within the gate's window.
  Test count unchanged (V.16 is text-only): 1886 green.

### April 27 — Release-commitment SLOs + measure-slos.sh + doctor surface (`phase-v14-slo-commitments`)
- `spec/slos.md` gains a "Release commitments (Phase V.14)" section
  publishing four numbers per release: cold-start (< 250 ms p95),
  idle memory (< 75 MB), install size (< 50 MB), classifier (< 2 ms
  p95, slot pending U.1 TierScorer). p95 not p99 because these are
  cold operations measured at low N.
- `tools/measure-slos.sh` captures all four and appends a JSON row
  to `~/.senkani/slo-history.jsonl` with `git_sha` + `version` for
  trend correlation. Idle-memory and classifier slots emit `null`
  when not measurable (daemon not running, or U.1 not yet shipped).
- `Sources/Core/ReleaseSLO.swift` ships `ReleaseSLOHistory` —
  median-of-5 baseline regression detector that flags any
  measurement ≥10% over baseline as `.regression` and any
  measurement over the published threshold as `.overBudget`.
  Improvements never fail the gate; missing slots are skipped.
- `senkani doctor` Check 15 ("Release commitments (Phase V.14)")
  prints the latest row + per-SLO baseline + percentage delta. The
  fresh-checkout case prints `n/a — run tools/measure-slos.sh to
  populate <path>`.
- 7 new tests in `Tests/SenkaniTests/ReleaseSLOTests.swift`: row
  decode roundtrip, no-history verdict, single-row OK with
  no-baseline, median-of-5 regression flag at ≥10%, improvement
  doesn't regress, over-budget flagged without baseline, malformed
  JSONL line tolerance.

### April 27 — Tamper-evident audit chain on `SessionDatabase` rows (`phase-t5-audit-chain` rounds 1–4)
- Round 1 — `Sources/Core/ChainHasher.swift` ships pure-function
  canonical-bytes + SHA-256 chain primitives. Migration v4 adds
  `prev_hash` / `entry_hash` / `chain_anchor_id` columns to
  `token_events` and a `chain_anchors` table; existing rows are
  anchor-from-now under a `migration-v4` anchor.
- Round 2 — `TokenEventStore.recordTokenEvent` computes and binds
  the chain columns; `Sources/Core/ChainVerifier.swift` walks the
  chain and reports `.ok` / `.brokenAt(table, rowid, expected,
  actual)` / `.noChain`. New `senkani doctor --verify-chain` flag
  exits 0 OK / non-zero on tamper; `senkani doctor` (full mode)
  emits `chain integrity: OK since <ISO-date> / N repairs`.
- Round 3 — `Sources/Core/ChainState.swift` extracted as a shared
  per-table primitive. Migration v5 extends the chain to
  `validation_results`, `sandboxed_results`, `commands`. Verifier
  gains `verifyAll(_:)` returning `[String: Result]` plus
  per-table walkers; `senkani doctor` Check 15 reports per-table
  integrity with one aggregated summary line.
- Round 4 — `Sources/Core/ChainRepairer.swift` ships
  `senkani doctor --repair-chain --table <T> --from-rowid <N>`
  with typed-string double-confirm UX (`REPAIR` then `<table>`),
  tty enforcement (refuses non-tty without `--force`), prior-tip
  hash recorded in the new repair anchor's `operator_note`,
  idempotency guard (refuses second repair against an existing
  repair anchor without `--force`), and a single
  `BEGIN IMMEDIATE` transaction for atomic repair. Verifier walk
  SQL gains `entry_hash IS NOT NULL` filter so anchor-from-now
  rebound rows are skipped during verification.
- `spec/architecture.md` → "Tamper-Evident Audit Chain (Phase T.5)"
  documents the full design + multi-round rollout. Test count
  1843 → 1879 across the four rounds (+36 chain tests).

### April 27 — Uninstall scanner finds project-level hooks at their actual install location (`fix-uninstall-project-hooks`)
- Found during the v0.2.0 release-checklist §A1 walkthrough on a
  real install. Operator's three Senkani-managed projects had hook
  entries at `<projectPath>/.claude/settings.json` (where
  `HookRegistration.registerForProject` writes them today), but
  `senkani uninstall`'s artifact list never mentioned them — the
  scanner was only checking the legacy
  `~/.claude/projects/<encoded>/settings.json` path. Result:
  `--yes` wipes left dead `senkani-hook` references in real
  projects' Claude Code config.
- Scanner now walks `~/.senkani/workspace.json`'s project list,
  checks each project's own `.claude/settings.json` for senkani
  hook entries, and unifies them with the legacy-location scan
  under the same `.projectHooks` artifact category. One approval
  prompt removes both.
- `UninstallSmokeTests` gains explicit
  `discoveryFindsModernHookLocationViaWorkspaceJson` test (the
  fixture seeds the modern location, asserts discovery + removal).
  Existing `seedProjectHooks` fixture extended to seed both
  locations; `seedPerProjectSenkaniDirs` now additively merges
  workspace.json entries instead of clobbering. Suite: 6 → 7 tests.
- This is exactly the kind of finding the manual-validation pass
  in `spec/release-checklist.md` §A is designed to catch — caught
  before v0.3.0 ships.

### April 26 — First GitHub Actions CI workflow lands (`ci-workflow-v1`)
- Bach/Majors/Schneier round. Pre-`v0.2.0` the project had zero CI:
  every PR relied on the operator running `./tools/test-safe.sh`
  locally. This commit adds `.github/workflows/test.yml` — a single
  macOS-pinned job that runs the same `tools/test-safe.sh`
  entrypoint humans run, so CI and local don't diverge.
- Roster P0s (all shipped): single command `./tools/test-safe.sh`,
  `runs-on: macos-14` (pinned, not `latest` — the suite-hang
  fingerprint in `spec/testing.md` is OS-version-sensitive),
  `permissions: contents: read`, `concurrency: cancel-in-progress`.
- P1 (shipped): SwiftPM `.build` + Xcode `DerivedData` cache keyed
  on `hashFiles('Package.resolved')`.
- Deferred to a future round: hard-gating on `tools/perf-gate.sh`
  (need 2–3 weeks of shared-runner baseline data first per Bach),
  multi-OS matrix (project is macOS-only by design), separate
  jobs for build vs. test.
- README adds three badges at the top: tests, license, release.

## v0.2.0 — 2026-04-26

### April 26 — Release checklist gives `senkani uninstall` real-install validation a durable home (`luminary-2026-04-24-15-uninstall-ci`)
- Luminary P3 (Bach/Majors/Grace). The 6 manual uninstall checks
  (real install, `--keep-data`, full wipe + idempotency, no Senkani
  tools in `claude`, app re-launch reversibility, post-wipe sweep
  for missed artifacts) had been parked on `tools/soak/manual-log.md`
  with no owner and no cadence. Synthetic regression coverage in
  `UninstallSmokeTests` (6 tests, fixture HOME) was solid — but the
  real-machine drift surface had no durable validation home.
- Pre-audit: every one of the 6 soak checks **inherently** requires
  state CI cannot reproduce (live MCP/hook registration, GUI
  re-launch, real Claude Code, real `launchctl`, real Keychain).
  Path A (lift to CI) rejected; Path B (formal release checklist)
  shipped.
- New `spec/release-checklist.md` §A — A1–A6 with the "uninstall
  owner" role, per-release sign-off slots, an explicit "why these
  stay manual" section, and a per-release log table appended at
  the bottom (newest at top). Gated to every minor-version bump
  (e.g. `v0.2.0 → v0.3.0`); patch bumps re-run only what changed.
- `spec/cleanup.md` #15 RESOLVED — points at the new checklist as
  the canonical home, retains the historical synthetic-smoke note
  for context.
- `tools/soak/manual-log.md` "uninstall" wave entry now opens with
  a callout pointing at `release-checklist.md §A` as the canonical
  home; the wave entry stays as the rolling diary for ad-hoc runs.
- `spec/roadmap.md` — both the v0.2.0 row for `senkani uninstall`
  and the "Manual test queue" entry updated to reference the new
  checklist.
- `spec/autonomous-manifest.yaml` — added `release:
  spec/release-checklist.md` to `specs.subsystems` so future rounds
  with `affects: [release]` route doc-sync to the right file.
- Suite: 1842 → 1842 (doc-only round, no test delta — synthetic
  surface was already covered).

### April 26 — Tree-sitter grammars are SHA-256 pinned; release SBOM script lands (`luminary-2026-04-24-13-grammar-pinning-sbom`)
- Luminary P2 (Schneier/Meeker/Grace). 25 vendored tree-sitter
  grammars are third-party C code that runs in-process during every
  `senkani index` and every MCP `outline`/`deps`/`repo` call.
  `GrammarManifest.swift` already tracked upstream version + repo,
  but it did not pin a content hash and the project did not emit an
  SBOM — a swapped `parser.c` would have shipped silently.
- `GrammarInfo` gains `contentHash: String` — SHA-256 of
  `parser.c` (concatenated with `scanner.c` when one is present).
  All 25 manifest entries declare a hash; six grammars have no
  external scanner so their hash covers `parser.c` alone.
- New `tools/verify-grammar-hashes.sh` recomputes each hash and
  diffs it against the manifest. Mismatch = exit 1 with the declared
  and computed hashes printed for forensics. `--print` mode emits
  the current-on-disk hash table so a deliberate grammar bump can
  re-pin in one paste. Wired into `tools/test-safe.sh` as a
  pre-flight gate (after the multiplier-claims check) so a tampered
  grammar fails CI before tests can mask the change with an
  unrelated regression. Skip via `SKIP_GRAMMAR_HASH_CHECK=1` for
  local iteration on a known-good tree.
- New `tools/generate-sbom.sh` emits a CycloneDX 1.5 JSON SBOM:
  25 tree-sitter grammars (with their pinned hashes + GitHub
  vcs URL), 4 ML models from `ModelManager.swift` (HuggingFace
  repo + expected size; runtime-downloaded so no content hash yet),
  and 22 Swift packages from `Package.resolved` (with pinned commit
  SHAs; branch-pinned packages get a `git-<short>` synthetic
  version). Components are sorted by name and the serial number is
  derived from the component fingerprint, so two identical builds
  produce byte-identical SBOMs (verified across runs). Honors
  `SOURCE_DATE_EPOCH` for reproducible-build pipelines. Standalone:
  no SwiftPM dependency, runnable from any release workflow as
  `./tools/generate-sbom.sh sbom.json`.
- 5 new tests under `GrammarManifest — Content hashes`: every
  entry declares a hash, format is lowercase hex-64, hashes are
  unique across grammars, on-disk SHA-256 matches the manifest
  for every grammar (catches forgot-to-rerun-verify after a
  re-vendor), and target names follow the `TreeSitter…Parser`
  contract that the verify + SBOM scripts assume.
  `GrammarStalenessTests` updated to pass a placeholder hash —
  staleness logic doesn't consult the field.
- Suite: 1837 → 1842 (+5). `spec/cleanup.md` "Vendored grammars
  not content-pinned + no SBOM" entry added as RESOLVED. Re-audit
  (Schneier/Meeker/Grace): PASS clean.
- Deferred: wiring `generate-sbom.sh` into an actual GitHub
  Actions release job — no `.github/workflows/` exists yet. The
  script header documents the intended integration; this gap is
  owned by `luminary-2026-04-24-14-distribution-packaging`. ML
  model download digests are not pinned (HuggingFace doesn't
  expose them at lookup time without a fetch); the SBOM lists
  repo + expected size as the authoritative-on-paper record.

### April 26 — Published SLOs surface in `senkani doctor` with a CI perf gate (`luminary-2026-04-24-12-slo-pack-with-burn-rate`)
- Luminary P2 (Majors/Carmack/Allspaw). The spec named three p99
  contracts on the hot path (cache hit < 1 ms, pipeline cache-miss
  < 20 ms, hook passthrough < 1 ms) but they were not published, not
  measured, and not gated. This round ships all three (plus
  `hook.active` < 3 ms as the operational ceiling for the same hook
  binary when the relay is engaged) end-to-end.
- New `spec/slos.md` declares the four SLOs, the 24-hour rolling
  window, and the 1% error budget. Burn-rate is intentionally
  simple for v0.2.0 — single window, single threshold,
  green / warn / burn / unknown verdict. Multi-window /
  multi-burn-rate alerting is parked until Senkani ships a daemon
  mode users don't babysit.
- New `Sources/Core/SLO.swift`: `SLOName` enum (with per-SLO
  threshold + description), `SLOSample` (ms + ts), `SLOSampleStore`
  (file-backed bounded ring buffer at `~/.senkani/slo-samples.json`,
  1000-sample cap per SLO, atomic writes), `SLOEvaluation`
  (state + p99 + sample count + over-budget pct), and the math
  helper `SLO.percentile(...)` shared by store + perf gate so doctor
  and CI compute p99 the same way.
- `record(...)` is gated on `SENKANI_SLO_SAMPLES=1` — Carmack-flagged:
  the SLOs measure operations on the order of 1–20 ms, and a
  read-modify-write JSON flush on every hot-path call would dominate
  what we're trying to measure. Recording is opt-in per process;
  the perf gate (and operators who want live samples) flips the
  env var. `recordForced(...)` bypasses the gate for tests + the
  perf gate.
- `FilterPipeline.process` now wraps its body in a timer and calls
  `SLOSampleStore.shared.record(.pipelineMiss, ms:)` once per call
  (no-op unless the env var is set). The same wiring slots in for
  `cache.hit` once any KB / artifact lookup wraps its hit path —
  the harness is generic so additional callsites are one line each.
- `senkani doctor` gains check #14 (after WARP skills): one line per
  SLO, surfacing rolling p99, threshold, sample count, and
  over-budget percentage. Verdict semantics:
  green = p99 ≤ threshold AND ≤ 1% over budget;
  warn = p99 in [80%, 100%) of threshold (early signal — emitted
  as a `✗` so it surfaces in the doctor's failed count and gets
  the operator's attention before it burns);
  burn = p99 > threshold OR > 1% of samples over threshold;
  unknown = fewer than 30 samples in the rolling window
  (Allspaw-flagged: prevents false-green on a fresh install and
  false-burn from a single outlier).
- New `Tests/SenkaniTests/SLOTests.swift` (19 tests) covers
  `SLO.percentile` (5 tests: empty, single, linear interpolation,
  p99 on 0..99 distribution, q-clamping), `SLOSampleStore` (10
  tests: env-gate respect, recordForced bypass, window filter,
  ring-buffer eviction, the four state transitions including
  budget-exceeded → burn at 1.98%, evaluateAll, reset), and the
  perf gate itself (3 tests: cache hit synthesised via Dictionary
  lookup, pipeline miss via real `FilterPipeline.process` on a
  small fixture, hook passthrough via the env-var read + bytes
  encode the relay's cold path does — exec'ing the binary is
  out of scope, the gate catches algorithmic regressions in the
  cold path itself). All thresholds met locally with green
  margins.
- New `tools/perf-gate.sh` is a thin convenience wrapper that runs
  the SLO gate suite alone (`swift test --filter SLOPerfGate`)
  with `SWT_NO_PARALLEL=1` and the multiplier-claim pre-flight
  skipped. The full suite via `tools/test-safe.sh` already
  includes the gate; `perf-gate.sh` is for fast local iteration
  when tuning a hot path.
- 2 new files (`Sources/Core/SLO.swift`, `Tests/SenkaniTests/SLOTests.swift`,
  `spec/slos.md`, `tools/perf-gate.sh`) + 2 modified
  (`Sources/Core/FilterPipeline.swift`,
  `Sources/CLI/DoctorCommand.swift`).
- Tests: 1818 → 1837 (+19). Build clean at 9.98s; full suite green
  at 22.4s. `spec/cleanup.md` "no published SLOs / no perf gate"
  → ✅ RESOLVED.

### April 26 — Typed `IndexError` replaces silent `[]` returns across the Indexer public API (`luminary-2026-04-24-11-indexer-result-errors`)
- Luminary P2 (Schneier/Bach/Torvalds). Indexer leaf functions used
  to return `[]` for every failure mode — binary missing, parse
  failed, unsupported language, file unreadable — making "no
  symbols here" indistinguishable from "the tool is broken." This
  was the single biggest style-drift cost in the codebase per the
  Codex-vs-Claude audit.
- New `Sources/Indexer/IndexError.swift`: `Equatable`, `Sendable`
  enum with four cases — `binaryMissing(String)`,
  `parseFailed(file:reason:)`, `unsupportedLanguage(String)`,
  `ioError(file:underlying:)`. `CustomStringConvertible` for
  legible logs; never includes absolute paths (Schneier).
- Seven public entry points now `throws` instead of silently
  returning `[]`: `CTagsBackend.index`,
  `TreeSitterBackend.index` and `TreeSitterBackend.extractSymbols`,
  `RegexBackend.index`, `IndexEngine.indexFileIncremental`,
  `DependencyExtractor.extractImports` and `extractAllImports`.
  Setup-level failures (missing binary, unknown language, parser
  setup) surface; per-file failures inside batch loops still
  `continue` silently — one bad file shouldn't fail the batch.
- Orchestrators (`IndexEngine.index`, `incrementalUpdate`,
  `buildDependencyGraph`) keep their `SymbolIndex` /
  `DependencyGraph` return types and now log the explicit swallow
  point when a backend throws (e.g. tree-sitter fails for a
  language → log + skip + continue with regex). Replaces five
  invisible silent-fail sites in the orchestration path.
- New `RegexBackend.supports(_:)` and `RegexBackend.supportedLanguages`
  let the orchestrator pick the right backend without invoking and
  catching `unsupportedLanguage`.
- `DependencyExtractor.extractImports` now collapses its public
  switch into the existing `extractForLanguage` private dispatch
  — no behavioral change, just a single place to extend.
- 12 new tests in `IndexErrorTests.swift` cover each `IndexError`
  case at every entry point: `Equatable` and `description` shape,
  `binaryMissing` (via a new `_binaryPathOverride` test hook on
  `CTagsBackend` so we don't need to uninstall ctags),
  `unsupportedLanguage` from each backend, `ioError` from
  `indexFileIncremental` with a missing file, the
  known-but-importless `bash`/`lua` success-with-`[]` contract,
  and the unknown-extension throw on `indexFileIncremental`.
- 1 new file (`IndexError.swift`) + 6 modified Indexer sources +
  21 test files updated to wrap helpers in `(try? f()) ?? []`
  + 1 production caller updated (`MCPSession.processFileEvents`).
  No callers' empty-success behavior changes; the only new
  observable is `try`-clauses can now match on which thing went
  wrong.
- Tests: 1806 → 1818 (+12). `spec/cleanup.md` "Silent error
  swallowing in Indexer" → ✅ RESOLVED.

### April 26 — TreeSitterBackend decomposition complete: Rust / Go / Dart / HTML / CSS migrated, dispatcher trimmed to 178 LOC (`luminary-2026-04-24-10f-treesitterbackend-cleanup`)
- Luminary P2 (Torvalds/Carmack/Bach via parent
  `luminary-2026-04-24-10`). Sixth and final round of the
  per-language backend decomposition. Migrates the last five
  languages and removes the central `walkNode` dispatcher entirely.
- New `Sources/Indexer/Languages/RustBackend.swift` (113 LOC): owns
  `function_item` / `function_signature_item` (via `extractFunction`),
  `struct_item`, `enum_item`, `trait_item` (`.protocol`; body
  recursed with the trait name as container so default fn
  implementations land as methods), `type_item` (.type for
  `type Alias = …`), and `impl_item` (no entry of its own; body
  recursed with the impl'd type as container via the shared
  `extractRustImplType` helper, which strips generics and resolves
  `impl Display for User` to "User").
- New `Sources/Indexer/Languages/GoBackend.swift` (61 LOC): owns
  `function_declaration` (via `extractFunction`), `method_declaration`
  (via `extractGoMethod`, which resolves the receiver type — value
  `(u User)` or pointer `(u *User)` — as the container), and
  `type_declaration` (via `extractGoTypeDeclaration` →
  `extractGoTypeSpec`, which picks `.struct` / `.interface` / `.type`
  from the spec's `type` field).
- New `Sources/Indexer/Languages/DartBackend.swift` (121 LOC): owns
  `class_definition` (via `extractPythonClass` — same node shape as
  Python and Scala), `enum_declaration` (via `extractTSDeclaration`),
  `function_signature` (.method when in a class container, else
  .function), `getter_signature` / `setter_signature` (.property in
  a container, else .variable), `extension_declaration` (.extension
  with literal "extension" fallback for anonymous extensions; body
  recursed with the extension name as container), and
  `mixin_declaration` (.class with body recursion).
- New `Sources/Indexer/Languages/HtmlBackend.swift` (32 LOC): no
  symbol surface — HTML emits no entries today. The backend exists
  to satisfy the dispatcher's "every supported language has a
  backend" invariant. Tests in `TreeSitterHtmlCssTests.swift` only
  verify grammar loading and `FileWalker` mapping.
- New `Sources/Indexer/Languages/CssBackend.swift` (33 LOC): same
  shape as `HtmlBackend` — no symbols, exists for invariant parity.
- `Sources/Indexer/TreeSitterBackend.swift` trimmed from 442 → 178
  LOC. The `walkNode` central switch is gone; the dispatcher is now
  responsible only for (1) `language(for:)` — id → grammar, (2)
  `backend(for:)` — id → `TreeSitterLanguageBackend.Type`, (3)
  `index(...)` — parse files and hand the root node to the backend,
  (4) `extractSymbols(...)` — same dispatch for an already-parsed
  tree (used by `IncrementalParser`).
- `extractSymbols(from:source:language:file:)` simplified: the
  `else { walkNode(...) }` fallback is gone — every supported
  language now has a backend, so an unsupported language returns
  `[]` directly rather than entering a no-op walk.
- 23 backend files now live under `Sources/Indexer/Languages/`
  (one per grammar; `TypeScriptBackend` covers the ts/tsx/javascript
  triple). The protocol is in `TreeSitterLanguageBackend.swift`;
  shared extractors and node helpers in `Helpers.swift`.
- `spec/cleanup.md` "TreeSitterBackend monolith" entry resolved
  (closes the 1,771 → 178 LOC arc that started at
  `luminary-2026-04-24-10`). `spec/tree_sitter.md` "Per-Language
  Backend Protocol" → "Migration status" updated with the five
  10f backends and the final dispatcher shape; "Adding more cases
  to walkNode" trap section flagged as historical.
- 1806/1806 tests green (no new tests — pure refactor, zero
  behavior delta on a 270-test tree-sitter cohort that exercises
  every migrated language end-to-end).

### April 26 — TreeSitterBackend decomposition: Ruby / PHP / Bash / Lua / Elixir / Haskell / Zig migrated (`luminary-2026-04-24-10e-treesitterbackend-script-family`)
- Luminary P2 (Torvalds/Carmack/Bach-flagged via parent
  `luminary-2026-04-24-10`). Fifth round of the per-language backend
  decomposition. Migrates the scripting / functional / systems mixed
  bag — seven backends in one round.
- New `Sources/Indexer/Languages/RubyBackend.swift` (91 LOC): owns
  `class`, `module`, `method`, `singleton_method`. Class/module
  bodies recurse with the declaration name as container; modules
  emit as `.extension` for parity with Swift extensions and PHP
  namespaces.
- New `Sources/Indexer/Languages/PhpBackend.swift` (121 LOC): owns
  `class_declaration`, `trait_declaration` (both `.class`),
  `interface_declaration`, `enum_declaration`, `function_definition`,
  `method_declaration`, `property_declaration` (one `.property` per
  `property_element` child, sharing the parent's start/end lines),
  and `namespace_definition` (`.extension` that recurses into its
  body without setting container — `helpers_boot` inside
  `namespace Acme\Services { … }` stays a top-level `.function`).
- New `Sources/Indexer/Languages/BashBackend.swift` (51 LOC): owns
  `function_definition` via `extractFunction`. No body recursion —
  Bash has no nested function containers in well-formed scripts.
- New `Sources/Indexer/Languages/LuaBackend.swift` (63 LOC): owns
  `function_declaration` via the shared `extractLuaFunctionName`
  helper, which unpacks all three name shapes (`function foo()`,
  `function M.greet()`, `function M:say()`).
- New `Sources/Indexer/Languages/ElixirBackend.swift` (125 LOC):
  owns `call`. Elixir has no dedicated declaration nodes — `defmodule`,
  `def`, `defp`, `defmacro`, and `defmacrop` all parse as `call`
  nodes whose first identifier child is the macro name. Helpers
  `extractModuleName` / `extractFunctionName` (formerly private
  statics on `TreeSitterBackend`) moved into the backend file.
- New `Sources/Indexer/Languages/HaskellBackend.swift` (151 LOC):
  owns `declarations` / `class_declarations` / `instance_declarations`
  with the per-scope dedup pass that handles multi-equation
  functions, signature+definition pairs, and signature-only
  abstract methods inside `class` bodies. The walker function
  (formerly `walkHaskellDeclarations` on `TreeSitterBackend`) moved
  into the backend file as a private static.
- New `Sources/Indexer/Languages/ZigBackend.swift` (158 LOC): owns
  `function_declaration` (identifier-child name extraction —
  Zig's grammar doesn't expose a `name` field), `variable_declaration`
  (type bindings only — `const Foo = struct/enum/union { … }`),
  `container_field` (typed fields only, filtering enum variants),
  and `test_declaration` (quoted-string name, container nil).
  Helpers `walkVariableDeclaration` / `extractTestName` moved into
  the backend file as private statics; struct-body recursion now
  goes through the backend's own walk instead of bouncing back
  through `walkNode`.
- `backend(for:)` registers all seven: Ruby / PHP / Bash / Lua /
  Elixir / Haskell / Zig now skip `walkNode` entirely. Dispatcher
  arms removed: `function_definition`, `class_declaration`,
  `interface_declaration`, `property_declaration`,
  `trait_declaration`, `class`, `module`, `method`,
  `singleton_method`, `declarations` / `class_declarations` /
  `instance_declarations`, `variable_declaration`,
  `container_field`, `test_declaration`, `call`,
  `namespace_definition`. Shared cases (`function_declaration`,
  `method_declaration`, `enum_declaration`) trimmed of their
  ruby / php / bash / lua / elixir / haskell / zig arms.
- Dart's `enum_declaration` was almost lost in the prune: a
  full-suite run caught the regression (Dart's `enum Color { … }`
  parses as `enum_declaration` exactly like PHP did). Restored to
  the dispatcher; routing comment updated to "Dart uses this node
  type for enums".
- Dispatcher dropped 862 → 442 LOC (-420). Languages directory
  now holds 2,488 LOC across 20 files. One round (10f) remains to
  migrate Rust / Go / Dart / HTML / CSS and bring the dispatcher
  under 500 LOC for good.
- Re-audit (Torvalds, Carmack, Bach): PASS clean. 1,806/1,806
  tests green; zero behavior delta as designed for a pure refactor
  (tests target = 0). Full-suite runtime ~21s.

### April 25 — TreeSitterBackend decomposition: C / C++ / C# / Java / Scala migrated (`luminary-2026-04-24-10d-treesitterbackend-c-family`)
- Luminary P2 (Torvalds/Carmack/Bach-flagged via parent
  `luminary-2026-04-24-10`). Fourth round of the per-language backend
  decomposition. Migrates the C-family + Java + Scala — five backends
  in one round.
- New `Sources/Indexer/Languages/CBackend.swift` (111 LOC): owns
  `function_definition` (declarator-chain name extraction),
  `struct_specifier` / `union_specifier`, `enum_specifier`,
  `type_definition`, and `declaration` (function prototypes).
- New `Sources/Indexer/Languages/CppBackend.swift` (183 LOC):
  preserves the three-tier `function_definition` extraction
  (extractFunction → extractCppQualifiedMethod → extractCDeclaratorName),
  plus `class_specifier`, `struct_specifier` / `union_specifier`
  with body recursion, `enum_specifier`, `type_definition`,
  `declaration`, `field_declaration` (in-class methods),
  `namespace_definition` (recurses without setting container), and
  `alias_declaration`.
- New `Sources/Indexer/Languages/CSharpBackend.swift` (147 LOC):
  owns `class_declaration`, `struct_declaration`,
  `record_declaration` (C# 9+), `interface_declaration`,
  `enum_declaration`, `delegate_declaration`, `namespace_declaration`,
  `file_scoped_namespace_declaration`, `method_declaration`,
  `constructor_declaration`, `destructor_declaration`,
  `property_declaration`.
- New `Sources/Indexer/Languages/JavaBackend.swift` (102 LOC):
  uniform `name`-field extraction via `extractTSDeclaration` for
  `class_declaration`, `interface_declaration`, `enum_declaration`,
  `record_declaration` (mapped to .struct), `annotation_type_declaration`
  (mapped to .protocol). Methods + constructors via `extractFunction`.
- New `Sources/Indexer/Languages/ScalaBackend.swift` (121 LOC):
  owns `class_definition` (via `extractPythonClass`),
  `object_definition` (.class with body recursion),
  `trait_definition` (.protocol with body recursion),
  `val_definition` / `var_definition` (.property — name from
  `pattern` field, not `name`), `type_definition`, and
  `function_definition` (`def`).
- `backend(for:)` registers all five: C / C++ / C# / Java / Scala
  now skip `walkNode` entirely. Dispatcher's C-family-only arms
  removed: `class_specifier`, `struct_specifier`/`union_specifier`,
  `enum_specifier`, `field_declaration`, `alias_declaration`,
  `record_declaration`, `annotation_type_declaration`,
  `constructor_declaration`, `destructor_declaration`,
  `struct_declaration`, `delegate_declaration`,
  `namespace_declaration`, `file_scoped_namespace_declaration`,
  `object_definition`, `trait_definition`, `val_definition` /
  `var_definition`. Shared cases (`function_definition`,
  `type_definition`, `declaration`, `namespace_definition`,
  `method_declaration`) trimmed of their cpp / c / csharp / java /
  scala arms.
- **10c-deferred deletion deferred again to 10e.** The 10d
  acceptance asked for `class_declaration` + `interface_declaration`
  + `enum_declaration` case-branch deletions. Pre-audit caught that
  PHP routes through all three (`class Foo`, `interface Greeter`,
  `enum Color` in PHP all parse as those node types). The branches
  stay alive — now serving PHP only — until 10e (when PHP migrates).
  Same for `property_declaration` (PHP property arm) and
  `namespace_definition` (PHP arm). The 10c lesson — enumerate every
  owning language by grep before deleting a walkNode case — paid off
  again here.
- Dart's `class_definition` was almost lost in the prune: a
  full-suite run caught the regression (Dart classes use
  `class_definition` exactly like Python and Scala did). Restored
  to the dispatcher; routing comment updated to "Dart routes through
  here".
- Two test discoveries during the round (both fixed before re-audit):
  C# `record_declaration` was previously served by the dispatcher's
  Java-shared `record_declaration` case — added to `CSharpBackend`
  alongside `struct_declaration`. Scala's `def` parses as
  `function_definition` and was getting recursed-but-not-extracted
  inside `object_definition` bodies — added a `function_definition`
  case to `ScalaBackend`.
- Dispatcher dropped 1,114 → 862 LOC (-252). Languages directory now
  holds 1,830 LOC across 13 files. Two rounds (10e–10f) remain to
  bring the dispatcher under 500 LOC.
- Re-audit (Torvalds, Carmack, Bach): PASS clean. 1,806/1,806 tests
  green; zero behavior delta as designed for a pure refactor (tests
  target = 0). Full-suite runtime ~20s.

### April 25 — TreeSitterBackend decomposition: TypeScript / TSX / JavaScript + Kotlin migrated (`luminary-2026-04-24-10c-treesitterbackend-ts-family`)
- Luminary P2 (Torvalds/Carmack/Bach-flagged via parent
  `luminary-2026-04-24-10`). Third round of the per-language backend
  decomposition. Migrates the TS-family + Kotlin to per-language files.
- New `Sources/Indexer/Languages/TypeScriptBackend.swift` (111 LOC):
  one backend covers `typescript`, `tsx`, and `javascript` because the
  declaration node types and extraction logic are uniform across all
  three grammars. Owns `function_declaration` / `generator_function_declaration`
  / `class_declaration` / `interface_declaration` / `type_alias_declaration`
  / `enum_declaration` / `method_definition`. JSX is handled by the
  parser; the walk is identical.
- New `Sources/Indexer/Languages/KotlinBackend.swift` (139 LOC):
  Kotlin uses positional children rather than named fields, so name
  lookups go via `findChildByType` (`simple_identifier` for functions
  / properties, `type_identifier` for classes / objects / type
  aliases). Owns `function_declaration` / `class_declaration`
  (covers class, sealed, data, interface, inner) /
  `property_declaration` / `object_declaration` / `companion_object`
  (defaults to "Companion" when unnamed) / `type_alias`.
- `backend(for:)` registers both: TypeScript / TSX / JavaScript /
  Kotlin now skip `walkNode` entirely. Dispatcher's TS-only arms
  (`type_alias_declaration`, `method_definition`) and Kotlin-only
  arms (`object_declaration`, `companion_object`, `type_alias`,
  Kotlin branches in `function_declaration` and `property_declaration`)
  deleted.
- **Acceptance #4 deferred:** the original spec said the
  `class_declaration` case branch could be deleted entirely once
  Swift / TS / TSX / Kotlin all migrated. Pre-existing behavior
  proved Java + C# also route through `class_declaration` (and C#
  also through `interface_declaration` + `enum_declaration`), so
  those three branches stay alive — now serving Java + C# only —
  until 10d (Java + C# migration round) when they can be deleted.
  Recorded inline in the dispatcher comments.
- Dispatcher dropped 1,206 → 1,114 LOC (-92). Languages directory
  now holds 1,176 LOC across 8 files. Three rounds (10d–10f) remain
  to bring the dispatcher under 500 LOC.
- Re-audit (Torvalds, Carmack, Bach): PASS with one accepted scope
  adjustment (acceptance #4 above). 1,806/1,806 tests green; zero
  behavior delta as designed for a pure refactor (tests target = 0).
  Full-suite runtime ~21s.

### April 25 — TreeSitterBackend decomposition: Swift + Python migrated to per-language files (`luminary-2026-04-24-10b-treesitterbackend-swift-python`)
- Luminary P2 (Torvalds/Carmack/Bach-flagged via parent
  `luminary-2026-04-24-10`). Second round of the per-language backend
  decomposition started in 10a. Migrates the two languages with the
  most distinctive extraction logic — Swift (class/struct/enum/actor/
  extension via `class_declaration` + `protocol_declaration` +
  `init_declaration` + `property_declaration`/`protocol_property_declaration`)
  and Python (`function_definition` + `class_definition` + decorated-
  definition recursion).
- New `Sources/Indexer/Languages/SwiftBackend.swift` (102 LOC), conforms
  to the protocol; reuses `extractSwiftClassLike` / `extractProtocol` /
  `extractFunction` / `extractProperty` shared helpers.
- New `Sources/Indexer/Languages/PythonBackend.swift` (68 LOC), conforms
  to the protocol; reuses `extractFunction` / `extractPythonClass` and
  recurses via the `default:` arm so `decorated_definition` wrappers
  flow through to inner `function_definition` / `class_definition` nodes.
- `backend(for:)` registers both: Swift / Python now skip `walkNode`
  entirely. Dispatcher's Swift-only arms (`protocol_declaration`,
  `init_declaration`, `protocol_property_declaration`, the Swift arm
  of `class_declaration`, the Swift fallthrough in `property_declaration`)
  removed. `class_definition` kept in `walkNode` because Scala also
  uses it (a one-test fix during the round — the migration spec
  flagged it as Python-only, but pre-audit caught the cross-language
  shape).
- Dispatcher dropped 1,219 → 1,206 LOC (-13). Languages directory
  now holds 923 LOC across 6 files. Four rounds (10c–10f) remain to
  bring the dispatcher under 500 LOC.
- Re-audit (Torvalds, Carmack, Bach): PASS clean. 1,806/1,806 tests
  green; zero behavior delta as designed for a pure refactor (tests
  target = 0). Full-suite runtime ~21s.

### April 25 — TreeSitterBackend decomposition pilot: protocol + Helpers + TOML/GraphQL backends (`luminary-2026-04-24-10a-treesitterbackend-protocol-and-pilot`)
- Luminary P2 (Torvalds/Carmack/Bach-flagged). Pilot round of the
  per-language backend decomposition — `Sources/Indexer/TreeSitterBackend.swift`
  was 1,771 LOC with 80+ case branches and intricate per-language
  sub-dispatch making language No. 26 materially harder than it
  should be.
- New `Sources/Indexer/Languages/TreeSitterLanguageBackend.swift`:
  `internal protocol` with `supports(_:)` + `extractSymbols(...)`. Doc
  comment explains the contract for adding a language and points at
  `TomlBackend.swift` as the worked example.
- New `Sources/Indexer/Languages/Helpers.swift`: 23 shared helpers
  (`nodeText`, `nodeName`, `findChildByType`, `findBody`, `startLine`,
  `endLine`, `signatureText`, `extractFunction`, `extractTSDeclaration`,
  `extractProperty`, `extractProtocol`, `extractPythonClass`,
  `extractSwiftClassLike`, `extractGoMethod`/`extractGoReceiverType`/
  `extractGoTypeDeclaration`/`extractGoTypeSpec`, `extractRustImplType`/
  `extractRustTypeName`, `extractCppQualifiedMethod`/`findQualifiedIdentifier`,
  `extractCDeclaratorName`, `cHasFunctionDeclarator`, `extractLuaFunctionName`,
  `extensionTypeName`, `findFirstIdentifier`) promoted from `private` to
  `internal` via `extension TreeSitterBackend`. No call-site churn —
  existing dispatcher code in `TreeSitterBackend.swift` continues to
  use bare names.
- New `Sources/Indexer/Languages/TomlBackend.swift`: 115 LOC, owns
  `table` / `table_array_element` / `pair` walk + `extractTableName` /
  `extractPairKey` (formerly `extractTomlTableName` / `extractTomlPairKey`).
- New `Sources/Indexer/Languages/GraphQLBackend.swift`: 86 LOC, lifts
  `walkGraphQL` intact + private `extractName` / `definitionKind`
  (formerly `graphqlName` / `graphqlDefinitionKind`).
- `TreeSitterBackend.extractSymbols(...)` and `TreeSitterBackend.index(...)`
  both route to `backend(for: language)` BEFORE calling `walkNode`, so
  TOML / GraphQL never enter the central switch. `walkNode`'s GraphQL
  early-return + TOML cases removed.
- Dispatcher dropped 1,771 → 1,219 LOC (-31%). Languages directory
  now holds 753 LOC across 4 files. Five rounds (10b–10f) remain to
  bring the dispatcher under 500 LOC by migrating the remaining 21
  language branches.
- Re-audit (Torvalds, Carmack, Bach): PASS clean. 1,806/1,806 tests
  green (260 tree-sitter tests unchanged); zero behavior delta as
  designed for a pure refactor (tests target = 0).
- `spec/tree_sitter.md` got an "Adding a language" section pointing
  at the new protocol with `TomlBackend` as the worked example.

### April 25 — Glossary + CLI conventions: pin the ubiquitous language (`luminary-2026-04-24-9-glossary-and-cli-conventions`)
- Luminary P2 (Evans-flagged). Twelve terms drifted across the spec
  tree with three different meanings each in some cases ("hook" was
  Layer 2 enforcement, Layer 3 intercept, *or* a Claude Code shell
  hook; "session" was pane-session, Claude-session, *or* provider-
  session; "rule" was built-in filter rule *or* learned filter rule).
  External contributors had no canonical reference.
- New `spec/glossary.md`: one entry per term (artifact, hook,
  intercept, multiplier, pane, project, rule, score, session,
  sessionDB, tier, tool). Bounded contexts called out explicitly.
- New `docs/cli-conventions.md`: argument naming (`--root`, `--yes`,
  kebab-case, no implicit shorts), verb choice for top-level
  commands, output formats (`--json` vs `--format`), exit codes
  (`0`/`1`/`2` plus child-process passthrough), stdout vs stderr
  policy, confirmation prompts, help text style, subcommand
  grouping, plus an "adding a new subcommand" checklist.
- Every spec file in `spec/` got a `> Glossary:` banner listing the
  terms it actually uses, with each term linked to the matching
  glossary entry. The banner is the file's first use of each term,
  so the cross-link is structural, not per-paragraph.
- `spec/spec.md` TOC gained a `glossary.md` row.
- `Sources/CLI/Senkani.swift` got a top-of-file comment pointing
  contributors at the conventions doc and listing three current
  deviations (type-name suffix is missing on 20/22 commands;
  `WipeCommand` and `UninstallCommand` worded the same `--yes` flag
  differently; `--json` Bool vs `--format <markdown|json>` is not
  a strict rule). Build passes.
- Re-audit (Evans, Grace, Procida, Podmajersky): PASS clean.
- Spec/docs edit + 1-file source comment; zero tests added.

### April 25 — Name Phase F's post-AAAK optimization target with explicit Lesson #17 rationale (`luminary-2026-04-24-8-phase-f-target-post-aaak`)
- Luminary P2 (Evans-flagged). Phase F was reworked April 12 when AAAK
  was dropped, but `spec/roadmap.md` never explicitly named the
  replacement optimization target nor referenced Structural Lesson
  No. 17 (the AAAK debunk). The section header read "(AAAK dropped —
  see below)", leading with the failure rather than the new direction.
- Phase F section in `spec/roadmap.md` re-framed: header now reads
  "Phase F: Smart First-Read Selection + Knowledge Graph". A new
  "Optimization target (post-Lesson #17)" paragraph names the
  replacement target explicitly — *selection over compression* —
  with three components (outline-first read, repo map, knowledge
  graph) framed as the post-AAAK headline.
- New "Why this target replaced AAAK (Lesson #17 rationale)"
  paragraph cites the specific measurements: AAAK's `len(text) // 3`
  token counter, 73 vs 66 tokens on the canonical example, 96.6% →
  84.2% accuracy on LongMemEval (12.4 pp regression), and the BPE
  reasoning for why source code can't be meaningfully abbreviated.
  References Structural Lesson No. 17 by name.
- Exit criteria rewritten to mark each as ✅ where infrastructure has
  shipped (outline-first ✅, repo map ✅, scenario multipliers ≥2x ✅
  via Phase E baseline 80.37x). The runtime "≥20 facts" criterion is
  acknowledged as runtime-not-infrastructure and the live-multiplier
  rollup is delegated to Phase G's tracking gate (no dual ownership).
- Re-audit (Evans/Torvalds/Carmack/Jobs): PASS clean — the
  replacement target is named, the rationale is sourced, and the
  bounded-context split (selection vs compression) is explicit.
- Spec-only edit: zero source files touched, zero tests added.

### April 25 — Rewrite Principle No. 6 to reconcile invisible optimization with the on-demand workspace (`luminary-2026-04-24-7-principle-6-rewrite`)
- Luminary P1 (Jobs-flagged). Principle No. 6 in `spec/spec.md`
  ("The App Disappears") read as "Senkani has no UI" and put every
  observability feature on the back foot — the 18-pane workspace,
  Dashboard, Agent Timeline, Sprint Review, Models pane, Ollama
  launcher, Knowledge Base, Savings Test, and `senkani doctor` were
  all in tension with the principle's "they may never know why" line.
- Principle No. 6 retitled **Invisible Optimization, On-Demand
  Inspection** and rewritten as a dual thesis: the *optimization
  layer* (Layers 1/2/3 — MCP tools, smart hooks, intent interception)
  is invisible and always-on; the *telemetry / inspection surface*
  (the panes, status bar, `doctor`, sprint review, savings test) is
  rich and on-demand. Names both users explicitly — the AI-session
  user (sees optimization invisibly) and the operator (lifts the
  hood deliberately) — and rejects the "Senkani has no UI"
  misreading on the record.
- New section "Invisible Optimization vs On-Demand Inspection" added
  to the top of `spec/app.md`, ahead of the pane catalogue. Links
  back to the principle so every pane below is justified by the
  second half of the contract: optimization does not interrupt, and
  inspection does not run unless asked.
- README.md audited and untouched: line 3's hero already leads with
  the dual thesis ("native multi-pane workspace … and an MCP
  intelligence layer that cuts 50–90% of the tokens your AI spends
  on perception") and never leaned on the old "may never know why"
  phrasing, so the acceptance criterion's "if it currently leans"
  clause was honored by skipping the edit.
- Spec edit only: zero source files touched, zero tests added.
  Re-audit (Jobs/Evans/Torres/Norman): PASS clean — the dual thesis
  is named, the two domain concepts have crisp ubiquitous-language
  labels, both user roles are surfaced, and the workspace's
  complexity is now justified by the principle rather than at war
  with it.

### April 25 — Split `LearnedRulesStore.swift` (844 → 360 LOC façade) into four per-artifact extensions (`luminary-2026-04-24-6-learnedrulesstore-split`)
- Luminary P1. `Sources/Core/LearnedRulesStore.swift` had grown to 844
  LOC mixing four artifact lifecycles (`LearnedFilterRule`,
  `LearnedContextDoc`, `LearnedInstructionPatch`,
  `LearnedWorkflowPlaybook`). The artifact types are the natural seam
  — adapt the SessionDatabase / KnowledgeStore split spirit to this
  JSON-backed substrate.
- Four per-artifact files extracted under `Sources/Core/LearnedRules/`:
  - `FilterRuleStore.swift` — owns the `LearnedFilterRule` type +
    Phase H/H+1/H+2a lifecycle (observe, promoteToStaged, apply,
    applyAll, reject, setEnrichedRationale, loadApplied,
    loadRecurring); also keeps the deprecated `stage(_:)` alias.
  - `ContextDocStore.swift` — Phase H+2b context-doc lifecycle
    (observe/promote/apply/reject/queries, plus the file-private
    `mutateContextDoc` helper).
  - `InstructionPatchStore.swift` — Phase H+2c lifecycle, with the
    Schneier constraint (no auto-apply path) restated in the header.
  - `WorkflowPlaybookStore.swift` — Phase H+2c lifecycle, with the
    "refresh steps + description on re-observation" merge rule.
- Each new file is a Swift `extension LearnedRulesStore { ... }` so
  the public API is byte-identical (`LearnedRulesStore.observe(_:)`,
  `.observeContextDoc(_:)`, etc.). The 20+ caller sites recorded
  pre-split (`grep -rl LearnedRulesStore\\.` across `Sources/` and
  `Tests/`) compile unchanged.
- Façade `LearnedRulesStore.swift` shrinks from 844 → 360 LOC and now
  owns only the cross-cutting types (`LearnedRuleStatus`,
  `LearnedArtifact`, `LearnedRulesFile`) plus shared persistence
  infra (`load`/`save`/`shared` cache, `withPath` test override,
  `reset`).
- New `Sources/Core/Stores/INVARIANTS.md` section "LearnedRulesStore
  invariants" (LRS1–LRS4) documents the single-shared-cache /
  read-modify-write / single-writer assumption, the public-API
  byte-identity contract, and the discriminated-union placement rule
  for adding a fifth artifact type. Calls out the explicit absence of
  a SessionDatabase-style serial queue (today's writers don't
  overlap; a future concurrent writer would need to add one before
  introducing parallelism — Kleppmann's re-audit concern).
- Tests: 25 new under `Tests/SenkaniTests/LearnedRules/` — one
  `*StoreTests.swift` per artifact type, each exercising
  observe/merge/rejected-stickiness/promote/apply/query paths
  directly against the store API (the `CompoundLearningH*` suites
  cover the higher-level generator → store integration; this layer
  was previously only tested transitively).
- Test count: 1781 → 1806 (+25). Full suite green via
  `tools/test-safe.sh`.

### April 25 — Split `KnowledgeStore.swift` (929 → 236 LOC façade) into four sub-stores (`luminary-2026-04-24-5-knowledgestore-split`)
- Luminary P1. `Sources/Core/KnowledgeStore.swift` had grown to 929 LOC —
  the same trajectory that prompted the SessionDatabase P2-11 split. Apply
  the same pattern: keep the public class as a thin façade and move
  table-owned behavior into focused stores under
  `Sources/Core/KnowledgeStore/` that share the parent's connection +
  serial dispatch queue.
- Four sub-stores extracted (each ≤400 LOC):
  - `EntityStore` — owns `knowledge_entities` + `knowledge_fts`
    (FTS5 virtual table + 3 sync triggers); entity CRUD, mention-count
    writes, staleness, FTS5 search.
  - `LinkStore` — owns `entity_links` + 3 indexes; link CRUD,
    backlinks, the post-hoc `target_id` resolver.
  - `DecisionStore` — owns `decision_records` + the `entity_name` index
    + the partial-unique `idx_decisions_commit` (git_commit dedup).
  - `EnrichmentStore` — owns `evidence_timeline` + `co_change_coupling`,
    the two enrichment-pipeline outputs that share an aggregate identity
    despite different lifecycles (rationale documented in the file
    header and INVARIANTS.md K3).
- Public API is byte-identical. Forwarders live in four
  `KnowledgeStore+*API.swift` extension files so callsites keep the
  pre-split shape — `SessionDatabase`'s split precedent in
  `Sources/Core/Stores/` set this convention.
- 24 new tests (6 per sub-store), each focused on store-level
  invariants the legacy aggregate suite doesn't cover: schema
  idempotency under reopen, FK cascade + SET NULL behavior, partial
  unique-index dedup semantics, mention-count batch atomicity,
  coupling-pair canonicalisation under burst writes. Suite total
  1757 → 1781 (+24).
- `Sources/Core/Stores/INVARIANTS.md` extended with a new
  "KnowledgeStore store invariants" section (K1–K5) covering connection
  sharing, the cross-store FK boundaries, the FTS5 trigger contract,
  the EnrichmentStore composition rationale, and the partial-unique
  index contract. The two split-rounds (SessionDatabase + KnowledgeStore)
  now share one invariants doc.

### April 25 — `senkani ml-eval` CLI + per-tier inference adapter (`senkani-ml-eval-cli`)
- Second of two follow-ups to `luminary-2026-04-24-4-gemma-tier-quality-eval`.
  The 20-task harness shipped April 24, the vision fixtures shipped earlier
  on April 25 — this round wires both to a CLI command that drives real
  Gemma inference end-to-end. The harness is no longer dormant: on a real
  machine with installed Gemma tiers, `senkani ml-eval` writes
  `~/.senkani/ml-tier-eval.json` and `senkani doctor` surfaces ratings.
- New `Sources/MCP/MLTierInferenceAdapter.swift` — actor-isolated, loads
  one Gemma 4 VLM at a time via `VLMModelFactory.shared.loadContainer`,
  answers `MLTierEvalTask`s through `MLXInferenceLock.shared`, unloads
  between tiers so the next (often larger or smaller) tier doesn't OOM.
- New `Sources/MCP/MLTierEvalOrchestrator.swift` — pure `plan(...)` helper
  decides per-tier evaluate vs. skip (with explicit `.verified`/`.downloaded`
  allowlist and named reasons for `insufficient RAM` / `not installed` /
  `not in registry`); `run(...)` iterates the plans, drives the adapter,
  and writes the report.
- New `Sources/CLI/MLEvalCommand.swift` — `senkani ml-eval` subcommand.
  Discovers `senkani-mcp` next to its own argv[0], in `.build/{release,
  debug}/`, or on PATH (override via `--mcp-binary`); shells out so the
  everyday `senkani` CLI stays MLX-free. `senkani-mcp` itself gains an
  `eval` argv mode that bypasses the SENKANI_PANE_ID gate and runs the
  orchestrator instead of the MCP server.
- `Package.swift` — MCPServer target gains `Bench` dependency so the
  orchestrator can reach `MLTierEvalTasks` / `MLTierEvalRunner` /
  `MLTierEvalReportStore`. CLI target unchanged (no MLX surface).
- 11 new tests: 6 pin orchestrator planning (RAM gate, install allowlist,
  unknown-tier rejection, downloaded-counts-as-installed, broken/error/
  downloading/verifying all skip with named status), 5 pin the CLI
  subcommand (registered in `Senkani.subcommands`, help message contains
  abstract + flags, MCP discovery finds sibling executable / build output /
  returns nil when absent). Suite total 1746 → 1757 (+11).
- Manual validation now runnable: the four `tools/soak/manual-log.md`
  bullets under "Per-RAM-tier Gemma 4 quality eval" become exercisable
  on the operator's machine — that's the round's final close-out
  step and lives outside CI.

### April 25 — Vision-eval image fixtures (`gemma4-vision-image-fixtures`)
- Follow-up to `luminary-2026-04-24-4-gemma-tier-quality-eval`. The 10
  vision tasks in `MLTierEvalTasks.visionTasks()` referenced PNGs by
  `imageRef` but the files themselves didn't ship — the vision half of
  the per-tier eval couldn't run end-to-end.
- New `Sources/Bench/Resources/MLEvalImages/` with 10 PNGs (5–12 KB
  each) covering each descriptor: terminal error, unified diff, Swift
  function signature, labelled chart axes, test-failure output, build
  log with warning count, UI mockup with primary button, multi-pane
  Senkani window, crash-report stack trace, download progress bar.
- `Sources/Bench/MLTierEvalTask.imageURL` resolves `imageRef` to a real
  `URL` via `Bundle.module`. `Package.swift` adds the directory as a
  `.copy` resource on the Bench target.
- Generator script at `tools/render-ml-eval-fixtures.py` (PIL-based,
  ≤200 KB cap enforced) so future descriptor changes can re-render
  the set deterministically.
- 2 new tests: `testEveryVisionTaskImageRefResolvesToARealFile` pins
  every vision task to a real PNG via `Bundle.module`, and
  `testRationaleTaskImageURLIsNil` pins the negative case. Suite total
  1744 → 1746 (+2).
- Doc fix: `MLTierEvalTask.imageRef` doc-comment claimed SHA-256 but
  the codebase uses stable string IDs; updated to match reality.

### April 24 — Per-RAM-tier Gemma 4 quality eval harness (`luminary-2026-04-24-4-gemma-tier-quality-eval`)
- Luminary P1 from the 2026-04-24 review. Gemma 4 auto-selects an
  install tier by available RAM (APEX 26B at ≥16 GB, E4B at ≥8 GB,
  E2B fallback) but the quality-per-tier story was unpublished —
  8 GB Mac users were silently routed to a materially worse model
  with no warning. This round ships the harness that surfaces the
  cost.
- New `Sources/Bench/MLTierEvalTasks.swift` — 20 tasks (10 rationale
  + 10 vision) probing concrete reasoning the rationale rewriter
  uses in production: terseness, causal reasoning, terminology
  recognition, structured output. Pass criterion is case-insensitive
  any-of substring match so multiple correct phrasings count.
- New `Sources/Bench/MLTierEvalRunner.swift` — runner accepts a
  caller-provided inference closure (Bench has no MLX dependency)
  and aggregates pass rate, median latency, output tokens. Rating
  thresholds: ≥80% excellent, ≥60% acceptable, else degraded; tiers
  the machine can't load report `notEvaluated` with a `skipReason`.
- `MLTierEvalReportStore` persists results at
  `~/.senkani/ml-tier-eval.json` (atomic write, ISO-8601 dates).
- `senkani doctor` reads the cached report and surfaces a per-tier
  line (`ml.tier.<id>: <rating> (passed/total, %, median ms, tokens)`).
  Degraded tiers fail the check with an "upgrade if RAM allows" hint;
  acceptable/excellent pass; absent report → skipped.
- Models pane shows a quality badge on each Gemma card, color-coded
  green (excellent) / blue (acceptable) / orange (degraded), with
  hover tooltip showing pass-count and median latency.
- 13 new tests pin task fixture shape, rating thresholds, runner
  accuracy + median computation, JSON round-trip, and missing-file
  handling. Suite total 1731 → 1744 (+13).
- Deferred to follow-up rounds: (a) the 10 vision-image fixtures and
  (b) the MCP-backed inference adapter that drives a real `senkani
  ml-eval` CLI command. Both are spec'd in
  `tools/soak/manual-log.md` and tracked as new backlog items so
  the eval gets real numbers on machines that have Gemma 4 tiers
  installed.

### April 24 — SessionDatabase store invariants doc (`luminary-2026-04-24-3-store-invariants-doc`)
- Luminary P1 from the 2026-04-24 review. The four-store split
  (`CommandStore`, `TokenEventStore`, `SandboxStore`, `ValidationStore`)
  shipped under `sessiondb-split-2..6` left several invariants
  enforced "by being in one file" with no written contract. Future
  splits (`KnowledgeStore` 929 LOC, `LearnedRulesStore` 844 LOC) need
  the rule-set written down before they begin.
- New `Sources/Core/Stores/INVARIANTS.md` — nine numbered invariants
  (I1–I9) covering the shared connection / serial-queue rule,
  `BEGIN IMMEDIATE` boundary on `recordCommand` (the only multi-
  statement transaction today), public-API byte-identity contract,
  `project_root` filter on every cross-project read (with the named
  asymmetry — `sandboxed_results` and `validation_results` are
  session-scoped and don't carry it), `token_events` single-source-
  of-truth and the inventory of every place it's JOINed, mandatory
  `PersistenceRedaction` on every disk-bound write, the
  `db.<scope>.<outcome>` Logger contract, cache-key conventions
  reserved for the next splits, and migration ownership at the
  façade. Each invariant cites ≥ 1 concrete test that enforces it.
- `spec/architecture.md` SessionDatabase section now links to
  `INVARIANTS.md`.
- `spec/cleanup.md` item 19 records two coverage gaps the audit
  surfaced: `complianceRate` and `lastExecResult` have no direct
  unit tests for project isolation. Closes before the next
  store-extraction round.
- Pure documentation round — no source changes, no test delta.

### April 24 — SecretDetector adversarial corpus + precision/recall harness (`luminary-2026-04-24-2-secretdetector-adversarial-corpus`)
- Luminary P0 from the 2026-04-24 spec-vs-codebase review. The
  shipped "100% redaction" claim was measured against a small
  hand-curated fixture set; against modern adversarial inputs (JWTs,
  PEM blocks, signed URLs, sub-threshold tokens, hyphenated key
  names, multi-secret blobs, structured config, base64/hex obfuscation)
  the same pipeline measured **1.000 precision / 0.894 recall**.
  The round publishes the honest numbers, names the gaps, and adds
  a regression harness so future changes can't drift either way.
- New `Tests/SenkaniTests/Fixtures/secrets-adversarial/` with 53
  labelled fixture files spanning 22 families. Each fixture has a
  `# id / family / expected / match_mode / description` header
  followed by `---\n` and a body. All bodies are synthetic — keys
  marked `FAKE` or split with concatenation tricks dodge GitHub
  push-protection.
- New `Tests/SenkaniTests/SecretDetectorAdversarialTests.swift`
  (~250 LOC). Three `@Test` functions: parameterised
  fixture-level expectation (53 invocations), parameterised
  family-threshold check (22 invocations), and a single summary
  reporter that prints a TP/FP/FN/TN/precision/recall table to
  stdout for each `swift test` run. New schema field
  `documented_gap: true` lets a fixture pin a known recall miss —
  the per-fixture test asserts the gap is still present, so any
  scanner improvement that closes it surfaces with "documented
  gap appears closed" rather than silently flipping coverage.
- Bundled the corpus via `resources: [.copy("Fixtures/secrets-adversarial")]`
  on the SenkaniTests target. Loaded at test time via
  `Bundle.module`.
- Updated `spec/testing.md`: Quality Gates row now reads
  "100% (fixture suite) / 1.000 precision · 0.894 recall (adversarial)".
  New "Secret redaction — fixture suite vs adversarial corpus"
  section names the three documented gaps with mechanical reasons
  and the marketing rule ("don't cite 100% without naming the
  corpus").
- Filed three follow-ups in `spec/cleanup.md` item 18 — sub-threshold
  / Twilio support, URL-aware tokenisation for GCS-style signed
  URLs, hex-charset entropy floor — each ships as a separate small
  round; closing one is verified by flipping `documented_gap:` in
  the corresponding fixture.
- Notable defence-in-depth finding: families whose named regex
  misses the fixture (hyphenated AWS key names, JSON-quoted
  api-secret, PASSWORD-style env vars, multi-line PEM bodies) still
  redact at 1.000 recall because EntropyScanner catches the
  high-entropy value. The pipeline's two-layer design is
  load-bearing — the named regex alone wouldn't hit these numbers.
- Test count: 1728 → 1731 (+3). Full `tools/test-safe.sh` suite
  green at 21.0s. Landing page test counter bumped 1,637 → 1,731.

### April 24 — Core DB log routing (`luminary-2026-04-24-1-unify-core-logging`)
- Luminary P0. Database init and per-store error paths used to write
  `print("[SessionDatabase] …")` / `print("[CommandStore] SQL error: …")`
  to stdout, bypassing the structured `Logger.log` pipeline that
  MCP/SocketServer/retention already use. Failures operators most
  need to see (DB open failure, SQL errors, schema migration drift)
  were invisible to telemetry and JSON-mode log capture.
- Replaced 8 `print(...)` sites in `Sources/Core/SessionDatabase.swift`,
  `Sources/Core/Stores/CommandStore.swift`, `Sources/Core/Stores/SandboxStore.swift`,
  `Sources/Core/Stores/ValidationStore.swift` with `Logger.log`
  emissions following a stable `db.<scope>.<outcome>` vocabulary:
  `db.session.open_failed`, `db.session.migrations_applied`,
  `db.session.migration_failed`, `db.command.sql_error`,
  `db.sandbox.sql_error`, `db.validation.sql_error`. Each event tags
  `outcome=success|error`; open events also tag `mode=default|test`
  and use `.path(...)` so home-dir prefixes are redacted at emit.
- Allowlist (intentional stdout retained, out of scope this round):
  `Sources/Core/ModelManager.swift:628` (security warning), and
  `Sources/Core/Stores/TokenEventStore.swift` `dumpTokenEvents()`
  under `#if DEBUG` (operator debug helper).
- New `Logger._setTestSink(_:)` test-only observation hook (a tee:
  the sink runs alongside the regular stderr write, so production
  behavior is unchanged). Lets tests assert routing without dup2-ing
  fd 2.
- New `Tests/SenkaniTests/LoggerRoutingTests.swift` with 8 cases:
  open-failed-on-bad-path, migrations-applied-on-fresh-DB,
  no-double-fire on already-migrated DB, mode-tag contract,
  per-store no-emit on clean init, regression anchor (no legacy
  `print("[…]")` in scoped files), sink-round-trip, and field-shape
  contract.
- Test count: 1720 → 1728 (+8). Full `tools/test-safe.sh` suite
  green at 20.8s.

### April 24 — Live-session multiplier gate (`luminary-2026-04-24-0-live-session-multiplier-gate`)
- Luminary P0 follow-up from the 2026-04-24 spec-vs-codebase review.
  The 80.37× figure is a fixture-bench ceiling; the live-session
  median is pending Phase G capture. External-facing copy must not
  quote either multiplier without an explicit fixture/live/pending
  qualifier. Round makes the rule automated and gap-closes three
  residual unpaired surfaces.
- New `tools/check-multiplier-claims.sh` (POSIX bash + awk, no deps):
  scans `README.md`, `index.html`, `docs/**/*.html`, `spec/spec.md`,
  `spec/roadmap.md`, `spec/testing.md` for bare multiplier claims
  (`80x`, `80.37`, `5-10x`, `5 to 10x`, `5x-10x`) and fails if any
  are unpaired with a fixture / live / synthetic / pending /
  benchmark / replay / caveat / ceiling qualifier within ±4 lines.
  Zero dependencies; runs in tens of ms.
- Wired into `tools/test-safe.sh` as a pre-flight check. Running the
  safe suite now also enforces the claim gate. Bypass via
  `SKIP_MULTIPLIER_CHECK=1` if a rare edit needs to land without the
  gate (not recommended).
- `index.html` hero stat strip: added a paired **Live-session median
  (pending)** tile next to the 80.37× fixture tile, with a link to
  the Savings Test pane and a 2026-05-31 target date.
- `spec/spec.md` "The Solution" close: rewrote the headline claim
  from `5-10x cost reduction measured, not claimed` to the paired
  framing — 80.37× fixture measured, live pending Phase G (expected
  5-10× range), both reported as a pair. Links to the
  testing.md caveat.
- `spec/testing.md` "Live Session Caveat" section: added owner
  (Chris Kluis), target capture date (2026-05-31), explicit
  "done when" criteria, and an inline description of the automated
  gate.
- New `Tests/SenkaniTests/MultiplierClaimGateTests.swift` with 4
  Swift Testing cases (unpaired fails, fixture-paired passes,
  pending-paired passes, current repo state passes). Full safe
  suite: green.

### April 24 — SessionDatabase split: thin façade + close P2-11 (`sessiondb-split-6-facade-thin`)
- Final round under the `sessiondatabase-split` umbrella (Luminary
  P2-11). `Sources/Core/SessionDatabase.swift` is now the lifecycle
  and composition façade only: connection/WAL setup, store wiring,
  `MigrationRunner`, schema-version diagnostics, retained
  `event_counters`, and the cross-store composition SQL
  (`lastExecResult`, `lastSessionActivity`, `tokenStatsByAgent`,
  `complianceRate`).
- Public forwarding moved into focused extension files:
  `SessionDatabase+CommandAPI.swift`,
  `SessionDatabase+TokenEventAPI.swift`,
  `SessionDatabase+SandboxAPI.swift`, and
  `SessionDatabase+ValidationAPI.swift`. Public callsites still use
  `SessionDatabase.shared.<method>`.
- Command-table-only helper SQL moved behind `CommandStore`
  (`totalStats`, `statsForProject`, `recentStats`,
  `commandBreakdown`, `outputPreviewsForCommand`,
  `costForToday`, `costForWeek`, `recordBudgetDecision`,
  `executeRawSQL`), so the façade no longer owns table-local command
  queries.
- `SessionDatabase.swift` dropped from 1493 → 587 LOC in this round
  (2479 → 587 across the split chain). No new tests were needed; the
  refactor is covered by the existing database surface. Targeted
  database suite passed 105/105; full safe suite passed 1716/1716.

### April 24 — SessionDatabase split: extract ValidationStore (`sessiondb-split-5-validationstore`)
- Round 4 of 5 under the `sessiondatabase-split` umbrella
  (Luminary P2-11). New `Sources/Core/Stores/ValidationStore.swift`
  owns `validation_results` setup, attempt persistence,
  pending-advisory reads, inspection queries, surfaced marking,
  legacy destructive fetch compatibility, and the 24-h prune method.
- `SessionDatabase` keeps the public compatibility boundary and now
  delegates all validation-result APIs. `AutoValidateQueue`,
  `HookRouter`, and `RetentionScheduler` callsites stay unchanged,
  so delivery policy and retention orchestration remain outside the
  store.
- Data-integrity constraints are preserved: `ValidationStore` shares
  the parent SQLite handle and serial queue, migration v3 remains the
  owner of `outcome`, `reason`, and `surfaced_at`, and pending reads
  remain non-destructive until HookRouter appends an advisory to a
  visible response.
- New `Tests/SenkaniTests/ValidationStoreTests.swift` adds 6 tests
  for non-destructive pending reads, surfaced marking, clean/dropped
  inspection, session-scoped 10-row pending limit, prune cutoff
  behavior, and legacy destructive fetch. Targeted validation surface
  is 33/33 green; full suite is 1716/1716 green.

### April 24 — Scheduled presets: day-1 catalogue of installable templates (`schedule-preset-library`)
- Ships five JSON-backed presets (`log-rotation`, `morning-brief`,
  `autoresearch`, `competitive-scan`, `senkani-improve`) as templates
  over the already-shipped scheduling spine. Zero new infrastructure —
  each preset emits the same `ScheduledTask` that
  `senkani schedule create` already accepts.
- New CLI surface: `senkani schedule preset list` /
  `preset show <name>` / `preset install <name> [--topic … |
  --competitor … | --budget … | --cron …]`. The `install` subcommand
  resolves angle-bracket placeholders against the CLI overrides, runs
  the resolved command through `PresetSecretDetector` (which delegates
  to the shared `SecretDetector`), and calls the new reusable
  `PresetInstaller` helper that also backs `senkani schedule create`
  — one launchd plist generator for both paths.
- `PresetPrerequisiteCheck` warns (does NOT block) on missing
  companion surfaces: Ollama daemon reachability for local-LLM
  presets, `senkani brief` / `senkani improve` CLIs, and hook-preset
  IDs (`guard-research`, `guard-autoimprove`) + planned MCP tools
  (`senkani_search_web`, `pushover-notification-sink`) that haven't
  shipped yet. The detector has a `withProbes(_:_:)` test hook so
  suites don't touch the network.
- `PresetDoctor.check(tasks:presets:)` pairs installed schedules
  against shipped preset prerequisites — intended as the Doctor
  integration hook; `senkani doctor` wiring is a follow-up item.
- Schedules pane gains a "Install preset" button in the header that
  opens a sheet listing the shipped + user presets with descriptions,
  engine class (shell / claude / local-LLM), and per-row prerequisite
  readiness. Install button shells out to `senkani schedule preset
  install` so the UI and CLI stay single-sourced.
- 20 new tests across `PresetCatalogTests` (6),
  `PresetInstallCommandTests` (4), `PresetHookPrerequisiteTests` (4),
  `PresetSecretDetectorTests` (4), `PresetDoctorTests` (2). Full suite
  1617 → 1637 in ~20 s under `tools/test-safe.sh`.

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
