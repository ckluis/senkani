# Senkani (閃蟹)

[![tests](https://github.com/ckluis/senkani/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/ckluis/senkani/actions/workflows/test.yml)
[![license](https://img.shields.io/github/license/ckluis/senkani)](LICENSE)
[![release](https://img.shields.io/github/v/release/ckluis/senkani)](https://github.com/ckluis/senkani/releases)

One macOS binary, two jobs: a **native multi-pane workspace** (SwiftUI, sub-3ms renders, 18 pane types) and an **MCP intelligence layer** that cuts 50–90% of the tokens your AI spends on perception. Compression, symbol indexing, secret redaction, local validators, and Layer-3 hook interception run before the request ever leaves your machine. No workflow changes — point Claude Code at it and your session just costs less.

## Quick Start

```bash
git clone https://github.com/ckluis/senkani.git && cd senkani
swift build -c release
.build/release/SenkaniApp           # launch the workspace
.build/release/senkani doctor       # verify setup + MCP registration
```

The MCP server auto-registers globally in `~/.claude/settings.json` on first
launch and only activates inside Senkani-managed terminal panes (gated by the
`SENKANI_PANE_ID` env var). Non-Senkani terminals never see the tools even if
the app is running. See [CHANGELOG.md](CHANGELOG.md) for the full shipped
feature list and roadmap.

---

## The MCP Intelligence Layer

20 tools that sit between Claude and your filesystem, compressing everything before it hits your token budget.

| Tool | What it does | Savings |
|------|-------------|---------|
| `senkani_read` | File reads: returns outline by default (symbols + line numbers), full content via `full: true`. Cache, secrets, filter on full reads. | 80–99% |
| `senkani_exec` | Shell commands: 24+ filter rules. Background mode for long builds (poll, kill). Adaptive truncation. | 60–90% |
| `senkani_search` | Symbol lookup: BM25 FTS5-ranked results + optional RRF fusion with MiniLM file embeddings. ~50 tokens vs ~5000 for grepping. | 99% |
| `senkani_fetch` | Read only a symbol's lines, not the entire file | 50–99% |
| `senkani_explore` | Navigate codebase via import/dependency graph | 90%+ |
| `senkani_deps` | Query bidirectional dependency graph (what imports X, what X imports) | — |
| `senkani_outline` | File-level structure: top-level functions, classes, types | — |
| `senkani_validate` | Local syntax validation across 20 languages. `full: true` for complete output (summary is default). | 100% |
| `senkani_parse` | AST dump via tree-sitter | — |
| `senkani_embed` | Text embeddings on Apple Silicon (no API cost) | $0/call |
| `senkani_vision` | Vision model on Apple Silicon (no API cost) | $0/call |
| `senkani_watch` | FSEvents ring buffer — query changed files by cursor + glob | near-zero |
| `senkani_web` | Render `http://`/`https://` page with full JS, return AXTree markdown. DNS-resolved SSRF guard + redirect re-validation; `file://` not accepted (use `senkani_read`). The W.2 `MarkdownFirstFetcher` gives a three-tier ladder (`Accept: text/markdown` → HTML→markdown transform → headless render) with caller-forceable `method`; tier wired into the tool path is W.2-bis. | ~99% vs raw HTML |
| `senkani_pane` | Control workspace panes — open, close, focus, resize (via Unix socket) | — |
| `senkani_session` | View stats, toggle features, pin/unpin symbol context (`pin`/`unpin`/`pins`) | — |
| `senkani_knowledge` | Query/update the project knowledge graph — entities, links, decisions, FTS5 search. `full: true` for complete entity detail (summary is default). | near-zero |
| `senkani_version` | Version negotiation: `server_version`, `tool_schemas_version`, `schema_db_version`, list of exposed tools. Cache client schemas keyed on `tool_schemas_version`. | — |
| `senkani_bundle` | Budget-bounded repo snapshot. Local mode composes symbol outlines + dep graph + KB entities + README in a canonical truncation-robust order. Remote mode (`remote: "owner/name"`) snapshots any public GitHub repo via `senkani_repo` — same host allowlist + `SecretDetector`. Emits `format: "markdown"` (default) or stable-schema `format: "json"` (`BundleDocument`). Path-validated. | repo-level |
| `senkani_repo` | Query any public GitHub repo without cloning. Actions: tree / file / readme / search. Host-allowlisted (api.github.com + raw.githubusercontent.com), anonymous by default (60 req/h); `GITHUB_TOKEN` env raises the limit. All responses SecretDetector-scanned. TTL+LRU cache. | query-level |
| `senkani_search_web` | Web search via DuckDuckGo Lite (no key, no quota). Returns `{title, url, snippet}` triples. Host-pinned to `lite.duckduckgo.com`, SSRF-guarded, redirect-pinned, every snippet + title scanned by `SecretDetector`. `guard-research` denies queries containing absolute paths, globs, or secret-shaped tokens. Snippets are adversarial third-party text — pass URLs through `senkani_web` before acting. | query-level |

**Compound learning** (Phase K) — the system learns your workflow across sessions. Proposals go `.recurring → .staged → .applied` with a lazy session-start sweep (`recurrence ≥ 3 + confidence ≥ 0.7`). Four artifact types:
- **Filter rules** (H, H+1) — `head(50)` + substring `stripMatching(...)` from the post-session waste analyzer. Regression-gated on real `commands.output_preview` samples. Laplace-smoothed confidence.
- **Context docs** (H+2b) — files read across ≥3 distinct sessions become priming documents at `.senkani/context/<title>.md`, injected into the next session's brief as a one-line "Learned:" section. Body is `SecretDetector`-scanned on every read/write.
- **Instruction patches** (H+2c) — tool hints derived from per-session retry patterns. **Never auto-apply from the daily sweep** — Schneier constraint forces explicit `senkani learn apply <id>`.
- **Workflow playbooks** (H+2c) — named multi-step recipes mined from ordered tool-call pairs within 60 s. Applied at `.senkani/playbooks/learned/<title>.md` — namespace-isolated from shipped skills.

Thresholds are operator-tunable via `~/.senkani/compound-learning.json` or `SENKANI_COMPOUND_*` env vars. CLI: `senkani learn status --type <filter|context>` · `apply` · `reject` · `sweep` · `enrich` · `config {show,set}` · `review [--days N]` (sprint cadence) · `audit [--idle D]` (quarterly currency review).

Gemma 4 optionally enriches rationale strings (H+2a) — contained to a dedicated `enrichedRationale` field, never enters `FilterPipeline`.

**Knowledge base** (Phase F + F+1..F+5) integrates with compound learning: `.senkani/knowledge/*.md` is the source of truth, SQLite is a rebuilt index (`KBLayer1Coordinator` detects staleness + corrupt-DB recovery), entities mentioned ≥5× per session get queued for Gemma enrichment, `EnrichmentValidator` flags information loss / contradiction / excessive rewrite before commit, `senkani kb rollback / history / timeline` wrap the append-only evidence + history archive. `KBCompoundBridge` knits the two systems: high-mention entities boost compound-learning confidence; applied context docs seed KB entity stubs; rolling back a KB entity cascades to invalidate derived context docs.

**Plain-md vault** (Phase V.7) makes the markdown vault portable. Set `kb_vault_path` in `~/.senkani/config.json` (or pass `senkani kb migrate --to <path>`) to relocate the vault out of the project tree — useful for keeping it next to existing Obsidian vaults. The resolver appends `<project-slug>` per-project so multi-project vaults don't collide. `senkani kb migrate` and `senkani kb unmigrate` move files in either direction; both are content-hash idempotent and surface conflicts rather than silently overwriting. `WikiLinkResolver` provides click-through resolution for `[[Name]]` with folder-hint disambiguation.

**Authorship tags** (Phase V.5) carry explicit provenance — `ai-authored` / `human-authored` / `mixed` / `unset` — on every KB entity. The save path prompts before persisting an ambiguous row (V.5b), `senkani authorship backfill` heals legacy NULL rows under a chain-participating audit row (V.5c), and the KB / Timeline / Skills panes render typographic badges that surface "Untagged" rather than silently inferring a tag (V.5d). Cavoukian's contract: provenance metadata, never policy.

**`HandManifest` skills** (Phase U.5 round 1) are a portable canonical capability-package shape: one JSON manifest carries `tools`, `settings`, `metrics`, multi-phase `system_prompt`, `skill_md`, `guardrails` (`requires_confirm` / `egress_allow` / `secret_scope`), `cadence` (HookRouter triggers + cron), `sandbox`, and declared `capabilities`. `senkani skill lint <path>` enforces 12 schema invariants (kebab-case names, `requires_confirm` ⊆ `tools[]`, known cadence triggers); `senkani skill export --target claude-code|cursor|codex|opencode|senkani <path>` round-trips one source into per-harness output (claude-code SKILL.md and senkani WARP.md are first-class; cursor/codex/opencode emit canonical envelopes pending V.10/V.11 hardening). Schema v1 is frozen at `spec/skills.md`.

**Session continuity** (Phase W.4) — `ContextSaturationGate` is a pure decision (`.ok / .warn / .block`) that reads `tokens_in + tokens_out` from `agent_trace_event` and compares against a configurable budget (defaults: warn 65 %, block 80 %, 200 000-token active window). When the gate blocks, `PreCompactHandoffWriter` lands a structured handoff card under `~/.senkani/handoffs/<sessionId>.json` — `openFiles`, `currentIntent`, `lastValidation` (pulled from `validation_results`), `nextActionHint`, `recentTraceKeys` — atomically (temp+rename, <1 s SLO). `PreCompactHandoffLoader.load(...)` / `loadLatest(...)` reads the card on the next session start and returns nil for missing / corrupt / future-schema files. HookRouter PreCompact wiring + a status-bar saturation chip + `senkani doctor --handoff` are W.4-bis (operator-decision pending).

**Annotation evidence** (Phase V.6 round 1) lets the operator mark working/failing portions of a skill or KB entity. Each row is append-only — `target_kind` (skill / kb-entity), inclusive byte range, verdict (`works` / `fails` / `note`), free-text notes, an `authored_by` handle, and a V.5 `AuthorshipTag` (explicit by construction). `renameAnnotationTarget` rewrites `target_id` so the lineage survives an artifact rename or fork. `AnnotationSignalGenerator` rolls up evidence per `(kind, target)` and feeds it into `CompoundLearning.runPostSession` — read-only in round 1: each evidence row bumps `compound_learning.annotation.observed` plus a `failing` / `working` / `mixed` counter. Future rounds (V.6 round 3) can wire annotations into the Propose pathway; round 1 stops at evidence so an operator's `fails` call is never silently mutated into a learned rule.

---

## The Workspace

A horizontal canvas of panes. Each pane is a primitive type; you arrange them however makes sense for what you're doing right now, and Senkani persists the layout per project.

**18 pane types:**

- **Terminal** — SwiftTerm, configurable font size, kill/restart buttons, broadcast mode
- **Dashboard** — multi-project portfolio: total savings, project table, feature charts, insights
- **Code Editor** — tree-sitter syntax highlighting (25 languages, incl. Dart/TOML/GraphQL), symbol navigation, file tree
- **Browser** — WKWebView embedded, localhost or any URL. Optional click-to-capture Design Mode (env-gate `SENKANI_BROWSER_DESIGN=on`, ⌥⇧D toggles) — click an element, get a fixed-schema Markdown block on the clipboard.
- **Markdown Preview** — live render from file, updates on save
- **Analytics** — token/cost savings with charts, persistent across restarts
- **Model Manager** — install → verify → ready state machine for local ML (MiniLM-L6 embeddings + Gemma 4 vision tiers). One-click **Install** drives `Available → Installing N% → Installed → Verifying… → Ready`; verification loads the model into an MLX container (real fixture) and flips to `Ready` or `Verification failed` with a one-click **Re-verify**. Per-tier output quality is measured by `senkani ml-eval` — runs the 20-task harness against each installed Gemma tier, writes `~/.senkani/ml-tier-eval.json`, and `senkani doctor` then surfaces the rating (excellent / acceptable / degraded) so 8 GB Mac users learn the smaller tier's quality cost up-front.
- **Savings Test** — fixture bench + live session replay + scenario simulator
- **Agent Timeline** — timeline of optimization events, interactive tool calls, and scheduled-task runs (start/end/blocked)
- **Knowledge Base** — project knowledge entities, freshness indicators
- **Diff Viewer** — side-by-side LCS diff (correct insertions, deletions, replacements)
- **Log Viewer** — searchable log output
- **Scratchpad** — auto-saving markdown notepad
- **Schedules** — manage recurring tasks via launchd. Ships with five day-1 presets (`log-rotation`, `morning-brief`, `autoresearch`, `competitive-scan`, `senkani-improve`) installable from the pane or via `senkani schedule preset install <name>`; each preset's resolved command is secret-scanned before install, and missing companion prerequisites (Ollama daemon, `guard-research` hook preset, `senkani brief` CLI, …) surface as warnings, not blockers.
- **Skill Library** — browse, install, and manage AI agent skills
- **Sprint Review** — GUI counterpart to `senkani learn review`: accept/reject staged compound-learning proposals (filter rules, context docs, instruction patches, workflow playbooks) plus a stale-applied section mirroring the quarterly audit
- **Ollama** — first-class local-LLM launcher: availability-gated, per-pane default-model selector, same MCP env injection terminal panes get. Header **download** button opens a curated-catalog drawer: pick from 5 LLMs (llama3.1:8b, qwen2.5-coder:7b, deepseek-r1:7b, mistral:7b, gemma2:2b), each row discloses size before the pull click and streams `ollama pull` progress into the UI. Install CTA when the daemon isn't running.

**⌘K command palette** opens everything: new panes, themes, actions. Search-as-you-type with category grouping.

---

## Security Defaults (v0.2.0)

Senkani is a trust boundary for LLM-driven tool calls. Security-sensitive features default to **on**; opt-outs are explicit env vars, not hidden flags.

- **Prompt injection guard — on by default.** `InjectionGuard` scans every MCP tool response for instruction-override, tool-call injection, context-manipulation, and exfiltration patterns, with anti-evasion normalization (lowercase, zero-width strip, Cyrillic→Latin homoglyphs). Runs in a single linear pass. Override: `SENKANI_INJECTION_GUARD=off`.
- **Web fetch SSRF hardening.** `senkani_web` resolves the target host via `getaddrinfo` before fetch and blocks any address in private/link-local/CGNAT/multicast ranges (including IPv4-mapped IPv6, octal/hex IPv4, and IPv4-compatible IPv6). Redirects are re-validated via `WKNavigationDelegate.decidePolicyFor` — a 3xx Location header to `10.x`/`169.254.169.254`/`::ffff:…` is cancelled. `file://` scheme is not accepted — read local files with `senkani_read`. **Subresource filter (F2):** a `WKContentRuleList` blocks `<img>`/`<script>`/`<xhr>`/etc. requests to the same private ranges — a hostile HTML page embedding `<img src="http://169.254.169.254/…">` cannot reach cloud metadata through WebKit's auto-rendering. Override for internal docs servers: `SENKANI_WEB_ALLOW_PRIVATE=on`.
- **Secret redaction — on by default.** `SecretDetector` now short-circuits with `firstMatch` so no-match inputs don't pay the full regex cost (1 MB benign input scans in ~25 ms).
- **Schema migrations — versioned + crash-safe.** Session DB uses `PRAGMA user_version` + a `schema_migrations` audit log. Cross-process coordination via `flock` sidecar. On failed migration, a kill-switch lockfile is written and subsequent boots refuse to run migrations until the operator inspects the DB.
- **Retention — scheduled.** `RetentionScheduler` prunes `token_events` (90 d), `sandboxed_results` (24 h), and `validation_results` (24 h) on an hourly tick. Tune via `~/.senkani/config.json` → `"retention": { "token_events_days": 30, ... }`.
- **Instruction-payload byte cap.** The `instructions` string injected at MCP server start (repo map + session brief + skills) is capped at 2 KB by default. Tune via `SENKANI_INSTRUCTIONS_BUDGET_BYTES`. Prevents the per-session-start token tax from growing with project size.
- **Socket authentication — opt-in.** Setting `SENKANI_SOCKET_AUTH=on` generates a 32-byte random token at `~/.senkani/.token` (mode 0600), rotated on every server start. Every connection to `mcp.sock`/`hook.sock`/`pane.sock` must send a length-prefixed handshake frame matching the token before normal protocol begins. Raises the bar from ambient same-UID socket access to must-read-token-file — blocks prompt-injected subagents and postinstall scripts that don't parse dot-files. Default off this release for backward compat; flipping to on next release.
- **Structured logging — opt-in + sink-redacted.** `SENKANI_LOG_JSON=1` emits one JSON object per critical event to stderr. Every `.string(_)` log field passes through `SecretDetector.scan` at emit time (Cavoukian C5), so a stray API key / bearer token / AWS / Slack / Stripe / GCP / npm / HuggingFace / GitHub token in a log field is automatically `[REDACTED:…]`'d. Use `LogValue.path(_)` for filesystem paths — `/Users/<name>` collapses to `~` (current user) or `/Users/***` (foreign). Default is backward-compatible `[event] key=value` format.
- **Observability counters — surfaced via CLI + MCP tool.** Every security-defense site increments an `event_counters` row (migration v2): injection detections, SSRF blocks, socket handshake rejections, schema migrations, retention prunes, command redactions. Read them via `senkani stats --security` (Gelman rate annotation: `count/total (pct%)`) or `senkani_session action:"stats"`. Per-project paths are redacted (Cavoukian C2).
- **Published SLOs — surfaced via `senkani doctor`.** Four latency contracts on the hot path (cache hit p99 < 1 ms, pipeline cache-miss p99 < 20 ms, hook passthrough p99 < 1 ms, hook active p99 < 3 ms). 24-hour rolling window with a 1% error budget. `senkani doctor` shows green / warn / burn / unknown per SLO with the rolling p99 and sample count. The CI perf gate (`tools/perf-gate.sh` and `Tests/SenkaniTests/SLOTests.swift`) synthesises a representative workload for each SLO and fails the build if any p99 crosses its ceiling. See [`spec/slos.md`](spec/slos.md).
- **Release commitments — four shape numbers per release.** Beyond the runtime SLOs above, every release reports cold-start (< 250 ms p95), idle memory (< 75 MB), install size (< 50 MB), and classifier latency (< 2 ms p95, slot pending U.1 TierScorer). Capture is `tools/measure-slos.sh`, which appends a row to `~/.senkani/slo-history.jsonl` with `git_sha` + `version` for trend correlation. `senkani doctor` reads the latest row and runs a median-of-5 baseline regression check — anything ≥10% over baseline fails the gate. Improvements never fail.
- **Data portability (GDPR-adjacent).** `senkani export --output <file> [--since DATE] [--redact]` streams sessions + commands + token_events as JSONL via a read-only SQLite connection — doesn't block the live MCP server.
- **Tamper-evident audit chain (Phase T.5).** Every row in `token_events`, `validation_results`, `sandboxed_results`, and `commands` carries `prev_hash` + `entry_hash` + `chain_anchor_id`. `entry_hash = SHA-256(prev_hash || canonical_row_bytes)` — a single-byte tamper at row N invalidates row N's hash and every subsequent row's hash. `senkani doctor --verify-chain` walks all four chains and reports OK or names the first broken `(table, rowid)`; the integrity line surfaces in `senkani doctor` as `chain integrity: OK since <ISO-date> / N repairs`. Recovery via `senkani doctor --repair-chain --table <T> --from-rowid <N>` opens a fresh chain segment with typed-string double-confirm, tty enforcement, and prior-tip linkage in the new anchor's `operator_note`.

Call `senkani_version` (tool) or `senkani doctor` to confirm the active security posture.

---

## Three-Layer Optimization

**Layer 1 — MCP Tools:** The agent calls `senkani_read` instead of `Read`. Cached, compressed, secret-redacted.

**Layer 2 — Smart Hooks:** Budget enforcement, metrics, compliance tracking, auto-validate reactions. PostToolUse triggers background syntax/type checking.

**Layer 3 — Preemptive Interception:** 5 patterns that work with agents that can't cooperate:
- Re-read suppression (file already served + unchanged → deny)
- Command replay (deterministic test/build + no file changes → deny with cached result)
- Trivial routing (ls/pwd/echo → answer in deny reason, saves round-trip)
- Search upgrade (3+ sequential reads → hint to use senkani_search)
- Redundant validation (covered by command replay for build/lint/check commands)

---

## Model Routing

Per-pane model presets control which Claude model handles tasks:

| Preset | Model | Est. Cost |
|--------|-------|-----------|
| **Auto** | Difficulty-scored routing | ~$0.30/hr |
| **Build** | Sonnet 4 | ~$0.45/hr |
| **Research** | Opus 4 | ~$2.25/hr |
| **Quick** | Haiku 3.5 | ~$0.12/hr |
| **Local** | Gemma 4 on-device | $0/hr |

**TaskTier + FallbackLadder + BudgetGate (Phase U.1a, internal API).** A second routing surface alongside the prompt-scored heuristic: callers who already have a `TaskTier` (`simple` / `standard` / `complex` / `reasoning`) hand it to `ModelRouter.resolve(taskTier:budget:...)`, which clamps the desired tier against the configured budget (daily-equivalent ceiling) and walks a 3-rung-capped `FallbackLadder` to a concrete `ModelTier`. `TaskTier` names *the work*; `ModelTier` (`local` / `quick` / `balanced` / `frontier`) names *the engine* — the separation lets the budget gate floor what kind of task can run without reshaping the model bins. The 3-rung cap is a deliberate undercut against ladder-bloat anti-patterns. Labeled corpus, accuracy gate, and the Analytics chart land in U.1b + U.1c.

---

## Paired Performance Numbers

Senkani publishes its savings claim as a **pair of numbers**, never one alone. The fixture multiplier measures the optimization math under controlled conditions; the live-session multiplier measures the same stack on real Claude Code sessions. Both are legitimate, and the *pairing* is the differentiator — citing only the ceiling sets the product up for a credibility loss when real-world performance lands lower.

| Number | Value | What it measures |
|--------|-------|------------------|
| **Fixture bench multiplier** | **80.37×** (synthetic, controlled) | 10-task × 7-config bench in `Sources/Bench/BenchmarkFixtures.swift`. Maximizes cache reuse, picks commands with aggressive filter rules. The optimization math's ceiling. |
| **Live-session multiplier** | **pending** (target capture: 2026-05-31) | Median of 5–10 representative Claude Code sessions replayed through `SessionDatabase.liveSessionMultiplier(projectRoot:since:)`. Lower than the fixture by design — the floor. |

**Why a pair, not a point estimate.** Real sessions read mostly-novel files (cache hit rate drops), pay symbol-index cold-start costs, vary in command output shape, and don't follow the bench's linear permutation. The fixture number is the honest *ceiling*; the live number is the honest *floor*. We report both so operators can pre-calibrate expectations before the first session, then reconcile against their own workflow once they've run it. Hard rule for the README and any marketing surface: **80×** never appears without its paired live-session number (or the explicit `pending` placeholder while Phase G capture is in flight).

The full caveat — including the action item, owner, and the `tools/check-multiplier-claims.sh` automated gate that fails the build on bare claims — lives at [`spec/testing.md` → Live Session Caveat](https://github.com/ckluis/senkani/blob/main/spec/testing.md#live-session-caveat-important).

**Other published numbers (see `senkani doctor` for current values):**

| Metric | Value |
|--------|-------|
| Hot-path SLOs | cache hit p99 < 1 ms · pipeline cache-miss p99 < 20 ms · hook passthrough p99 < 1 ms · hook active p99 < 3 ms |
| Release commitments | cold-start < 250 ms p95 · idle memory < 75 MB · install size < 50 MB · classifier latency < 2 ms p95 (slot pending U.1) |
| Terminal render | p50 ~2 ms, p99 ~3.4 ms |
| Filter throughput | > 10 k lines/sec |
| Symbol search | < 5 ms cold, < 1 ms cached |
| Secret scan | < 2 ms / KB |
| Unit tests | **2311 passing** |
| Binary size | ~28 MB universal |

---

## Architecture

| Module | Deps | Role |
|--------|------|------|
| **Core** | Filter | Session DB (incl. canonical trace rows), feature config, metrics, budget, hook routing, model routing, auto-validate, adaptive truncation |
| **Filter** | — | Token compression: 44 cmd rules, ANSI strip, dedup, secrets, terse |
| **Indexer** | SwiftTreeSitter | 25 tree-sitter backends, FTS5 search, dependency graph, incremental parsing, FSEvents |
| **Bench** | Core, Filter, Indexer | Token savings test suite: 10 tasks × 7 configs, quality gates, JSON export |
| **MCP** | Core, Filter, Indexer, Bundle, MLX | 20 MCP tools, socket server (mcp + hook + pane), vision + embedding inference, Gemma 4 rationale adapter |
| **Bundle** | Core, Filter, Indexer | `BundleComposer` — budget-bounded repo-snapshot composition for `senkani_bundle` |
| **HookRelay** | — | Zero-dep hook relay library shared by senkani-hook binary and app's --hook mode |
| **CLI** | Core, Filter, Indexer, Bench | 23 commands: exec, search, bench, doctor, grammars, kb, eval, learn, init, authorship, … |
| **SenkaniApp** | All + SwiftTerm | SwiftUI workspace: 18 pane types, multi-project, ⌘K palette, dashboard, menu bar |

---

## Building from Source

Prerequisites: macOS 14+, Swift 6.0+, Xcode 15+

```bash
swift build          # debug
swift build -c release
swift test           # parallel run (fast; see caveat below)
./tools/test-safe.sh # deterministic full-suite run (slower but always terminates)
senkani doctor       # verify grammar and database setup
```

> **Test harness caveat:** default `swift test` can hang during
> parallel startup on some machines due to Swift concurrency
> pool starvation in a handful of NSLock-wrapped test helpers.
> See [spec/testing.md](spec/testing.md) — "Full-suite hang" for
> root cause + workaround. `./tools/test-safe.sh` is the
> documented deterministic path until the underlying helpers are
> migrated off cooperative-pool blocking primitives.

The GUI target (`SenkaniApp`) includes SwiftUI, SwiftTerm, and MLX. The CLI (`senkani`) and hook (`senkani-hook`) targets are lean — no MLX, no SwiftUI.

---

## Companion Stack (remote-operator pattern)

Senkani runs locally on a Mac. When the operator wants to drive a headless Mac mini from a phone or laptop on the road, the documented pattern is three off-the-shelf tools — **not Senkani features**, just the stack we recommend:

1. **Tailscale (Personal tier, free).** WireGuard mesh that gives every device a stable hostname inside your tailnet without exposing any port to the public internet. The Personal tier covers up to 6 users and unlimited devices — comfortably above any solo operator's needs. Install Tailscale on the Senkani Mac and on the operator's phone/laptop; both sign into the same tailnet.
2. **Screens 5 (one-time $179.99 lifetime, or $29.99/year subscription).** Native VNC client on iOS and macOS. Tap a saved Mac on the iPhone, get the actual Senkani desktop over the WireGuard tunnel. Use the `screens://<saved-name>` URL scheme — on macOS, `vnc://` and `ssh://` may be intercepted by Screen Sharing or Terminal. The lifetime tier is the right fit for the Senkani audience; if that flinches, take the annual subscription, not a fork-and-self-host alternative.
3. **Pushover (one-time ~$4.99 per platform, 10 k messages/mo free tier).** Simple HTTPS push API — `POST https://api.pushover.net/1/messages.json` with `token` + `user` + `message`. Senkani's `NotificationSink` adapter populates the `url` field with `screens://<tailnet-host>` so the notification itself becomes the deep link.

**The closed loop:** a Senkani job finishes → Pushover fires a push to the operator's phone → the notification's `url` field is `screens://<tailnet-host>` → tap → Screens 5 opens that exact Mac's desktop over the tunnel. No Senkani-side daemon ever listened on the public internet.

Macs go to sleep — set **System Settings → Battery → Power Adapter → Wake for network access** so the headless Mac mini answers when Tailscale pokes it. Tailscale Personal-tier policy and Screens pricing have shifted before; treat the named products as the *current* recommendation and the *pattern* — any WireGuard mesh + any VNC client + any HTTP-API push service — as the durable contract. See [`spec/inspirations/native-app-ux/tailscale-plus-screens-5.md`](spec/inspirations/native-app-ux/tailscale-plus-screens-5.md) for the full design analysis.

---

## License

MIT (core). See LICENSE.
