# Senkani (閃蟹)

**A native macOS terminal workspace with built-in AI intelligence.**

Senkani is two things in one binary: a **multi-pane terminal workspace** (native SwiftUI, Apple Silicon, sub-3ms render latency) and an **MCP intelligence layer** that intercepts perception tasks before they hit your AI — compressing output, indexing symbols, redacting secrets, running validators locally. The result: 50–90% fewer tokens per session, no workflow changes required, and a workspace where your terminal, notes, browser, and analytics live side by side.

---

## What's Built vs What's Coming

| Feature | Status |
|---------|--------|
| **Terminal pane** — SwiftTerm, Apple Silicon native, configurable font size | ✅ Live |
| **Markdown preview pane** — live-rendered from file | ✅ Live |
| **Browser pane** — WKWebView embedded | ✅ Live |
| **Code Editor pane** — pure SwiftUI, tree-sitter syntax highlighting (22 languages), file tree sidebar, symbol navigation (Cmd+click → definition), token intelligence overlays | ✅ Live |
| **Analytics pane** — token/cost savings with charts, persistent across restarts | ✅ Live |
| **Dashboard pane** — multi-project portfolio: hero savings card, project breakdown table, feature charts, auto-generated insights | ✅ Live |
| **Model manager pane** — download/manage local LLMs | ✅ Live |
| **Savings test pane** — fixture benchmark (80.37x) + live per-feature breakdown + session history with paired fixture/live multipliers | ✅ Live |
| **Diff viewer / log viewer / scratchpad panes** | ✅ Live |
| **Agent timeline pane** — tool call history with optimization events | ✅ Live |
| **Knowledge base pane** — entity list (sort/filter/enrichment badge), understanding editor, decision records, co-change couplings, wiki-link `[[completion]]`, canvas relations graph, session brief | ✅ Live |
| **Multi-project workspace** — persistent per-project layout | ✅ Live |
| **Menu bar integration** — lifetime stats, socket toggle, launch-at-login | ✅ Live |
| **⌘K command palette** — search-as-you-type for panes, themes, actions | ✅ Live |
| **MCP intelligence layer** — 17 tools, auto-registers with Claude Code | ✅ Live |
| **Filter pipeline** — 44 command-specific rules, ANSI stripping, dedup | ✅ Live |
| **Secret redaction** — API keys, AWS tokens, GitHub PATs, Bearer tokens | ✅ Live |
| **Terse compression** — algorithmic word/phrase minimization | ✅ Live |
| **Symbol indexer** — 22 languages (incl. HTML/CSS), tree-sitter AST + regex fallback | ✅ Live |
| **Incremental indexing** — re-indexes only changed files, symbol staleness notifications | ✅ Live |
| **Dependency graph** — bidirectional imports, 15+ languages | ✅ Live |
| **Session database** — SQLite + FTS5, token tracking, cost history, metrics persistence | ✅ Live |
| **Hook system** — budget enforcement, tool routing, Layer 3 interception (5 patterns), auto-validate reactions, <5ms latency | ✅ Live |
| **Layer 3 interception** — re-read suppression, command replay, trivial routing, search upgrade, redundant validation | ✅ Live |
| **Auto-validate** — PostToolUse → background syntax/type check → advisory on next tool call | ✅ Live |
| **Model routing** — per-pane presets (Auto/Build/Research/Quick/Local), difficulty scoring, CLAUDE_MODEL env injection | ✅ Live |
| **Local vision** — Gemma on Apple Silicon MLX, no API cost | ✅ Live |
| **Local embeddings** — MLX, no API cost | ✅ Live |
| **`senkani_watch` tool** — FSEvents ring buffer; query changed files by cursor + glob | ✅ Live |
| **`senkani_exec` background mode** — detach long builds, poll stdout, kill on demand | ✅ Live |
| **Process lifecycle controls** — kill/restart buttons in pane header, PID tracking | ✅ Live |
| **Metrics persistence** — all savings data survives app restart via SQLite | ✅ Live |
| **Smart first-read selection** — outline-first reads return symbol structure by default | ✅ Live |
| **Adaptive truncation** — output caps scale with budget remaining | ✅ Live |
| **Broadcast mode** — type once, all terminal panes hear | ✅ Live |
| **Notification rings** — blue ring on panes with unread output | ✅ Live |
| **Sidebar metadata** — git branch per project | ✅ Live |
| **Display settings** — font size slider + presets per pane | ✅ Live |
| **CLI** — 18 commands: exec, search, bench, doctor, grammars, kb, eval, learn, uninstall, … | ✅ Live |
| **Benchmarking suite** — filter, indexer, cache, terse, schemaMin — with reporters | ✅ Live |
| **Pane socket IPC** — instant pane control via Unix socket (<10ms vs 5s polling) | ✅ Live |
| **Socket health check** — senkani doctor verifies daemon responsiveness | ✅ Live |
| IDE pane (LSP completions, inline diagnostics, multi-cursor) | 🔄 Planned |
| Agent runner pane (spawn, observe, interrupt) | 🔄 Planned |
| Workflow builder (pipeline graph UI) | 🔄 Planned |
| SSH / Mosh pane | 🔄 Planned |
| **Session continuity** — context brief injected at session open, agent resumes from prior session | ✅ Live |
| **Prompt injection detection** — scans tool responses for embedded attack strings, 4 categories, anti-evasion normalization | ✅ Live |
| **MCP output compaction** — `knowledge`, `validate`, `explore` compact by default; `detail:'full'` escape hatch; 30% tool description trim | ✅ Live |
| **Agent usage tracking** — tier-1 exact (Claude Code JSONL), tier-2 estimated (hooks), tier-3 partial (MCP-only); per-agent breakdown in `senkani eval` | ✅ Live |
| **Compound learning** — post-session waste analysis, learned filter rule proposals, `senkani learn status/apply/reject` | ✅ Live |
| **Workstream isolation** — git worktree + pane pair, lifecycle hooks | ✅ Live |

---

## Quick Start

**Build and run:**
```bash
git clone https://github.com/ckluis/senkani.git
cd senkani
swift build -c release
.build/release/SenkaniApp
```

**CLI:**
```bash
# Run a command with token-compressed output
senkani exec -- git status

# Search your codebase by symbol
senkani search MyViewController

# Run the benchmark suite
senkani bench

# Check your setup
senkani doctor
```

**MCP server:** Auto-registered globally in `~/.claude/settings.json` on first app launch — no `senkani init` needed. The MCP server only activates in Senkani-managed terminal panes (gated by `SENKANI_PANE_ID` env var). Non-Senkani terminals never see Senkani tools, even if the app is running.

---

## The MCP Intelligence Layer

17 tools that sit between Claude and your filesystem, compressing everything before it hits your token budget.

| Tool | What it does | Savings |
|------|-------------|---------|
| `senkani_read` | File reads: returns outline by default (symbols + line numbers), full content via `full: true`. Cache, secrets, filter on full reads. | 80–99% |
| `senkani_exec` | Shell commands: 24+ filter rules. Background mode for long builds (poll, kill). Adaptive truncation. | 60–90% |
| `senkani_search` | Symbol lookup: BM25 FTS5-ranked results + optional RRF fusion with MiniLM file embeddings. ~50 tokens vs ~5000 for grepping. | 99% |
| `senkani_fetch` | Read only a symbol's lines, not the entire file | 50–99% |
| `senkani_explore` | Navigate codebase via import/dependency graph | 90%+ |
| `senkani_deps` | Query bidirectional dependency graph (what imports X, what X imports) | — |
| `senkani_outline` | File-level structure: top-level functions, classes, types | — |
| `senkani_validate` | Local syntax validation across 20 languages | 100% |
| `senkani_parse` | AST dump via tree-sitter | — |
| `senkani_embed` | Text embeddings on Apple Silicon (no API cost) | $0/call |
| `senkani_vision` | Vision model on Apple Silicon (no API cost) | $0/call |
| `senkani_watch` | FSEvents ring buffer — query changed files by cursor + glob | near-zero |
| `senkani_web` | Render `http://`/`https://` page with full JS, return AXTree markdown. DNS-resolved SSRF guard + redirect re-validation; `file://` not accepted (use `senkani_read`). | ~99% vs raw HTML |
| `senkani_pane` | Control workspace panes — open, close, focus, resize (via Unix socket) | — |
| `senkani_session` | View stats, toggle features, pin/unpin symbol context (`pin`/`unpin`/`pins`) | — |
| `senkani_knowledge` | Query/update the project knowledge graph — entities, links, decisions, FTS5 search | near-zero |
| `senkani_version` | Version negotiation: `server_version`, `tool_schemas_version`, `schema_db_version`, list of exposed tools. Cache client schemas keyed on `tool_schemas_version`. | — |

---

## The Workspace

A horizontal canvas of panes. Each pane is a primitive type; you arrange them however makes sense for what you're doing right now, and Senkani persists the layout per project.

**16 pane types:**

- **Terminal** — SwiftTerm, configurable font size, kill/restart buttons, broadcast mode
- **Dashboard** — multi-project portfolio: total savings, project table, feature charts, insights
- **Code Editor** — tree-sitter syntax highlighting (22 languages), symbol navigation, file tree
- **Browser** — WKWebView embedded, localhost or any URL
- **Markdown Preview** — live render from file, updates on save
- **Analytics** — token/cost savings with charts, persistent across restarts
- **Model Manager** — download, verify, and delete local LLMs (Gemma, MiniLM)
- **Savings Test** — fixture bench + live session replay + scenario simulator
- **Agent Timeline** — timeline of optimization events
- **Knowledge Base** — project knowledge entities, freshness indicators
- **Diff Viewer** — side-by-side diff
- **Log Viewer** — searchable log output
- **Scratchpad** — auto-saving markdown notepad
- **Schedules** — manage recurring tasks via launchd
- **Skill Library** — browse, install, and manage AI agent skills

**⌘K command palette** opens everything: new panes, themes, actions. Search-as-you-type with category grouping.

---

## Security Defaults (v0.2.0)

Senkani is a trust boundary for LLM-driven tool calls. Security-sensitive features default to **on**; opt-outs are explicit env vars, not hidden flags.

- **Prompt injection guard — on by default.** `InjectionGuard` scans every MCP tool response for instruction-override, tool-call injection, context-manipulation, and exfiltration patterns, with anti-evasion normalization (lowercase, zero-width strip, Cyrillic→Latin homoglyphs). Runs in a single linear pass. Override: `SENKANI_INJECTION_GUARD=off`.
- **Web fetch SSRF hardening.** `senkani_web` resolves the target host via `getaddrinfo` before fetch and blocks any address in private/link-local/CGNAT/multicast ranges (including IPv4-mapped IPv6, octal/hex IPv4, and IPv4-compatible IPv6). Redirects are re-validated via `WKNavigationDelegate.decidePolicyFor` — a 3xx Location header to `10.x`/`169.254.169.254`/`::ffff:…` is cancelled. `file://` scheme is not accepted — read local files with `senkani_read`. Override for internal docs servers: `SENKANI_WEB_ALLOW_PRIVATE=on`.
- **Secret redaction — on by default.** `SecretDetector` now short-circuits with `firstMatch` so no-match inputs don't pay the full regex cost (1 MB benign input scans in ~25 ms).
- **Schema migrations — versioned + crash-safe.** Session DB uses `PRAGMA user_version` + a `schema_migrations` audit log. Cross-process coordination via `flock` sidecar. On failed migration, a kill-switch lockfile is written and subsequent boots refuse to run migrations until the operator inspects the DB.
- **Retention — scheduled.** `RetentionScheduler` prunes `token_events` (90 d), `sandboxed_results` (24 h), and `validation_results` (24 h) on an hourly tick. Tune via `~/.senkani/config.json` → `"retention": { "token_events_days": 30, ... }`.
- **Instruction-payload byte cap.** The `instructions` string injected at MCP server start (repo map + session brief + skills) is capped at 2 KB by default. Tune via `SENKANI_INSTRUCTIONS_BUDGET_BYTES`. Prevents the per-session-start token tax from growing with project size.

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
| Unit tests | **915 passing** |
| Binary size | ~28 MB universal |

**About the numbers:** The 80.37x figure is from the fixture benchmark — synthetic tasks designed to exercise each optimization layer. Real sessions produce a lower multiplier. The Savings Test pane shows both numbers side by side: fixture ceiling and live floor. The live number is the honest one.

---

## Architecture

| Module | Deps | Role |
|--------|------|------|
| **Core** | Filter | Session DB, feature config, metrics, budget, hook routing, model routing, auto-validate, adaptive truncation |
| **Filter** | — | Token compression: 44 cmd rules, ANSI strip, dedup, secrets, terse |
| **Indexer** | SwiftTreeSitter | 22 tree-sitter backends, FTS5 search, dependency graph, incremental parsing, FSEvents |
| **Bench** | Core, Filter, Indexer | Token savings test suite: 10 tasks × 7 configs, quality gates, JSON export |
| **MCP** | Core, Filter, Indexer, MLX | 17 MCP tools, socket server (mcp + hook + pane), vision + embedding inference |
| **HookRelay** | — | Zero-dep hook relay library shared by senkani-hook binary and app's --hook mode |
| **CLI** | Core, Filter, Indexer, Bench | 18 commands: exec, search, bench, doctor, grammars, kb, eval, learn, init, … |
| **SenkaniApp** | All + SwiftTerm | SwiftUI workspace: 16 pane types, multi-project, ⌘K palette, dashboard, menu bar |

---

## Building from Source

Prerequisites: macOS 14+, Swift 6.0+, Xcode 15+

```bash
swift build          # debug
swift build -c release
swift test           # 915 tests
senkani doctor       # verify grammar and database setup
```

The GUI target (`SenkaniApp`) includes SwiftUI, SwiftTerm, and MLX. The CLI (`senkani`) and hook (`senkani-hook`) targets are lean — no MLX, no SwiftUI.

---

## License

MIT (core). See LICENSE.
