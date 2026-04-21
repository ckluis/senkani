# Senkani (閃蟹)

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

19 tools that sit between Claude and your filesystem, compressing everything before it hits your token budget.

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
| `senkani_web` | Render `http://`/`https://` page with full JS, return AXTree markdown. DNS-resolved SSRF guard + redirect re-validation; `file://` not accepted (use `senkani_read`). | ~99% vs raw HTML |
| `senkani_pane` | Control workspace panes — open, close, focus, resize (via Unix socket) | — |
| `senkani_session` | View stats, toggle features, pin/unpin symbol context (`pin`/`unpin`/`pins`) | — |
| `senkani_knowledge` | Query/update the project knowledge graph — entities, links, decisions, FTS5 search. `full: true` for complete entity detail (summary is default). | near-zero |
| `senkani_version` | Version negotiation: `server_version`, `tool_schemas_version`, `schema_db_version`, list of exposed tools. Cache client schemas keyed on `tool_schemas_version`. | — |
| `senkani_bundle` | Budget-bounded repo snapshot. Local mode composes symbol outlines + dep graph + KB entities + README in a canonical truncation-robust order. Remote mode (`remote: "owner/name"`) snapshots any public GitHub repo via `senkani_repo` — same host allowlist + `SecretDetector`. Emits `format: "markdown"` (default) or stable-schema `format: "json"` (`BundleDocument`). Path-validated. | repo-level |
| `senkani_repo` | Query any public GitHub repo without cloning. Actions: tree / file / readme / search. Host-allowlisted (api.github.com + raw.githubusercontent.com), anonymous by default (60 req/h); `GITHUB_TOKEN` env raises the limit. All responses SecretDetector-scanned. TTL+LRU cache. | query-level |

**Compound learning** (Phase K) — the system learns your workflow across sessions. Proposals go `.recurring → .staged → .applied` with a lazy session-start sweep (`recurrence ≥ 3 + confidence ≥ 0.7`). Four artifact types:
- **Filter rules** (H, H+1) — `head(50)` + substring `stripMatching(...)` from the post-session waste analyzer. Regression-gated on real `commands.output_preview` samples. Laplace-smoothed confidence.
- **Context docs** (H+2b) — files read across ≥3 distinct sessions become priming documents at `.senkani/context/<title>.md`, injected into the next session's brief as a one-line "Learned:" section. Body is `SecretDetector`-scanned on every read/write.
- **Instruction patches** (H+2c) — tool hints derived from per-session retry patterns. **Never auto-apply from the daily sweep** — Schneier constraint forces explicit `senkani learn apply <id>`.
- **Workflow playbooks** (H+2c) — named multi-step recipes mined from ordered tool-call pairs within 60 s. Applied at `.senkani/playbooks/learned/<title>.md` — namespace-isolated from shipped skills.

Thresholds are operator-tunable via `~/.senkani/compound-learning.json` or `SENKANI_COMPOUND_*` env vars. CLI: `senkani learn status --type <filter|context>` · `apply` · `reject` · `sweep` · `enrich` · `config {show,set}` · `review [--days N]` (sprint cadence) · `audit [--idle D]` (quarterly currency review).

Gemma 4 optionally enriches rationale strings (H+2a) — contained to a dedicated `enrichedRationale` field, never enters `FilterPipeline`.

**Knowledge base** (Phase F + F+1..F+5) integrates with compound learning: `.senkani/knowledge/*.md` is the source of truth, SQLite is a rebuilt index (`KBLayer1Coordinator` detects staleness + corrupt-DB recovery), entities mentioned ≥5× per session get queued for Gemma enrichment, `EnrichmentValidator` flags information loss / contradiction / excessive rewrite before commit, `senkani kb rollback / history / timeline` wrap the append-only evidence + history archive. `KBCompoundBridge` knits the two systems: high-mention entities boost compound-learning confidence; applied context docs seed KB entity stubs; rolling back a KB entity cascades to invalidate derived context docs.

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
- **Model Manager** — install → verify → ready state machine for local ML (MiniLM-L6 embeddings + Gemma 4 vision tiers). One-click **Install** drives `Available → Installing N% → Installed → Verifying… → Ready`; verification loads the model into an MLX container (real fixture) and flips to `Ready` or `Verification failed` with a one-click **Re-verify**.
- **Savings Test** — fixture bench + live session replay + scenario simulator
- **Agent Timeline** — timeline of optimization events, interactive tool calls, and scheduled-task runs (start/end/blocked)
- **Knowledge Base** — project knowledge entities, freshness indicators
- **Diff Viewer** — side-by-side LCS diff (correct insertions, deletions, replacements)
- **Log Viewer** — searchable log output
- **Scratchpad** — auto-saving markdown notepad
- **Schedules** — manage recurring tasks via launchd
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
- **Data portability (GDPR-adjacent).** `senkani export --output <file> [--since DATE] [--redact]` streams sessions + commands + token_events as JSONL via a read-only SQLite connection — doesn't block the live MCP server.

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

---

## Performance

Numbers from the built-in benchmark suite (`senkani bench`):

| Metric | Value |
|--------|-------|
| Fixture bench multiplier | **80.37x** (synthetic, controlled conditions) |
| Live session multiplier | **Varies by workflow** — see Savings Test pane |
| Terminal render latency | p50 ~2ms, p99 ~3.4ms |
| Filter throughput | >10k lines/sec |
| Symbol search | <5ms cold, <1ms cached |
| Secret scan | <2ms per KB |
| Hook latency | <5ms active, <1ms passthrough |
| Unit tests | **1433 passing** |
| Binary size | ~28 MB universal |

**About the numbers:** The 80.37x figure is from the fixture benchmark — synthetic tasks designed to exercise each optimization layer. Real sessions produce a lower multiplier. The Savings Test pane shows both numbers side by side: fixture ceiling and live floor. The live number is the honest one.

---

## Architecture

| Module | Deps | Role |
|--------|------|------|
| **Core** | Filter | Session DB, feature config, metrics, budget, hook routing, model routing, auto-validate, adaptive truncation |
| **Filter** | — | Token compression: 44 cmd rules, ANSI strip, dedup, secrets, terse |
| **Indexer** | SwiftTreeSitter | 25 tree-sitter backends, FTS5 search, dependency graph, incremental parsing, FSEvents |
| **Bench** | Core, Filter, Indexer | Token savings test suite: 10 tasks × 7 configs, quality gates, JSON export |
| **MCP** | Core, Filter, Indexer, Bundle, MLX | 18 MCP tools, socket server (mcp + hook + pane), vision + embedding inference, Gemma 4 rationale adapter |
| **Bundle** | Core, Filter, Indexer | `BundleComposer` — budget-bounded repo-snapshot composition for `senkani_bundle` |
| **HookRelay** | — | Zero-dep hook relay library shared by senkani-hook binary and app's --hook mode |
| **CLI** | Core, Filter, Indexer, Bench | 18 commands: exec, search, bench, doctor, grammars, kb, eval, learn, init, … |
| **SenkaniApp** | All + SwiftTerm | SwiftUI workspace: 18 pane types, multi-project, ⌘K palette, dashboard, menu bar |

---

## Building from Source

Prerequisites: macOS 14+, Swift 6.0+, Xcode 15+

```bash
swift build          # debug
swift build -c release
swift test           # 1433 tests
senkani doctor       # verify grammar and database setup
```

The GUI target (`SenkaniApp`) includes SwiftUI, SwiftTerm, and MLX. The CLI (`senkani`) and hook (`senkani-hook`) targets are lean — no MLX, no SwiftUI.

---

## License

MIT (core). See LICENSE.
