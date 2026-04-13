# Senkani (閃蟹)

**A native macOS terminal workspace with built-in AI intelligence.**

Senkani is two things in one binary: a **multi-pane terminal workspace** (native SwiftUI, Apple Silicon, sub-3ms render latency) and an **MCP intelligence layer** that intercepts perception tasks before they hit your AI — compressing output, indexing symbols, redacting secrets, running validators locally. The result: 50–90% fewer tokens per session, no workflow changes required, and a workspace where your terminal, notes, browser, and analytics live side by side.

---

## What's Built vs What's Coming

| Feature | Status |
|---------|--------|
| **Terminal pane** — SwiftTerm, Apple Silicon native | ✅ Live |
| **Markdown preview pane** — live-rendered from file | ✅ Live |
| **Browser pane** — WKWebView embedded | ✅ Live |
| **Code Editor pane** — pure SwiftUI, tree-sitter syntax highlighting (22 languages), file tree sidebar, symbol navigation (Cmd+click → definition), token intelligence overlays | ✅ Live |
| **Analytics pane** — token/cost savings with realtime sparkline | ✅ Live |
| **Model manager pane** — download/manage local LLMs | ✅ Live |
| **Savings test pane** — fixture benchmark (80.37x) + live per-feature savings breakdown | ✅ Live |
| **Diff viewer / log viewer / scratchpad panes** | ✅ Live |
| **Agent timeline pane** — tool call history | ✅ Live |
| **Multi-project workspace** — persistent per-project layout | ✅ Live |
| **Menu bar integration** — lifetime stats, socket toggle, launch-at-login | ✅ Live |
| **MCP intelligence layer** — 13 tools, auto-registers with Claude Code | ✅ Live |
| **Filter pipeline** — 24+ command-specific rules, ANSI stripping, dedup | ✅ Live |
| **Secret redaction** — API keys, AWS tokens, GitHub PATs, Bearer tokens | ✅ Live |
| **Terse compression** — algorithmic word/phrase minimization | ✅ Live |
| **Symbol indexer** — 22 languages (incl. HTML/CSS), tree-sitter AST + regex fallback | ✅ Live |
| **Incremental indexing** — re-indexes only changed files | ✅ Live |
| **Dependency graph** — bidirectional imports, 15+ languages | ✅ Live |
| **Session database** — SQLite + FTS5, token tracking, cost history | ✅ Live |
| **Hook system** — budget enforcement, tool routing, Layer 3 re-read suppression, <5ms latency | ✅ Live |
| **Local vision** — Gemma on Apple Silicon MLX, no API cost | ✅ Live |
| **Local embeddings** — MLX, no API cost | ✅ Live |
| **CLI** — 13 commands: exec, search, bench, doctor, grammars, … | ✅ Live |
| **Benchmarking suite** — filter, indexer, cache, terse, with reporters | ✅ Live |
| **Knowledge base pane** — project knowledge entities, freshness indicators, decision records | ✅ Live |
| IDE pane (LSP completions, inline diagnostics, multi-cursor) | 🔄 Planned |
| Agent runner pane (spawn, observe, interrupt) | 🔄 Planned |
| Workflow builder (pipeline graph UI) | 🔄 Planned |
| Multi-repo git view | 🔄 Planned |
| Command palette (⌘K) | 🔄 Planned |
| SSH / Mosh pane | 🔄 Planned |
| **Session continuity** — session context brief injected at session open, agent knows where it left off without re-reading files | 🔄 Planned |
| **Prompt injection detection** — scan MCP tool responses for embedded attack strings before they reach Claude | 🔄 Planned |
| **Smart first-read selection** — outline-first reads return symbol structure by default, full content on demand | ✅ Live |
| **`senkani_watch` tool** — FSEvents ring buffer exposed as MCP tool; eliminates re-read polling after builds/edits | 🔄 Planned |
| **`senkani_exec` background mode** — detach long-running builds/servers, poll stdout, kill on demand; lifts 30s timeout | 🔄 Planned |
| **Layer 3 command replay** — hook detects repeated Bash commands with no file changes, denies and re-uses prior output | ✅ Live |

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

13 tools that sit between Claude and your filesystem, compressing everything before it hits your token budget.

| Tool | What it does | Savings |
|------|-------------|---------|
| `senkani_read` | File reads: returns outline by default (symbols + line numbers), full content via `full: true`. Cache, secrets, filter on full reads. | 80–99% |
| `senkani_exec` | Shell commands: 24+ command-specific filter rules (git, npm, cargo, docker…) | 60–90% |
| `senkani_search` | Symbol lookup from local index: ~50 tokens vs ~5000 from grep | 99% |
| `senkani_fetch` | Read only a symbol's lines, not the entire file | 50–99% |
| `senkani_explore` | Navigate codebase via import/dependency graph | 90%+ |
| `senkani_deps` | Query bidirectional dependency graph (what imports X, what X imports) | — |
| `senkani_outline` | File-level structure: top-level functions, classes, types | — |
| `senkani_validate` | Local syntax validation across 20 languages | 100% |
| `senkani_parse` | AST dump via tree-sitter | — |
| `senkani_embed` | Text embeddings on Apple Silicon (no API cost) | $0/call |
| `senkani_vision` | Vision model on Apple Silicon (no API cost) | $0/call |
| `senkani_pane` | Control workspace panes — open, close, focus, resize | — |
| `senkani_session` | View stats, toggle features, manage panes | — |

**Feature toggles** — all on by default, configurable per-pane or globally:

| Toggle | Env var | Effect |
|--------|---------|--------|
| Filter | `SENKANI_FILTER` | Command-specific output rules |
| Secrets | `SENKANI_SECRETS` | Redact secrets before they reach the AI |
| Indexer | `SENKANI_INDEXER` | Symbol index for search/fetch/explore |
| Terse | `SENKANI_TERSE` | Algorithmic phrase compression |
| Injection guard | `SENKANI_INJECTION_GUARD` | Scan tool responses for embedded prompt attacks |
| Session continuity | `SENKANI_CONTINUITY` | Inject prior-session brief at session open |

---

## The Workspace

A horizontal canvas of panes. Each pane is a primitive type; you arrange them however makes sense for what you're doing right now, and Senkani persists the layout per project.

**Pane types available today:**

- **Terminal** — SwiftTerm, Apple Silicon native, sub-3ms render, full color/ligature support
- **Code Editor** — tree-sitter syntax highlighting (20 languages), symbol navigation (Cmd+click → definition), token intelligence overlays
- **Browser** — WKWebView embedded, localhost or any URL
- **Markdown Preview** — live render from file, updates on save
- **Analytics** — token/cost savings per session with sparkline charts
- **Model Manager** — download, verify, and delete local LLMs (Gemma, MiniLM)
- **Savings Test** — run the benchmark suite from the UI
- **Agent Timeline** — timeline of agent tool calls and decisions
- **Knowledge Base** — project knowledge entities, freshness indicators, decision records
- **Diff Viewer** — side-by-side diff
- **Log Viewer** — searchable log output
- **Scratchpad** — auto-saving markdown notepad

**Pane types coming:**

- IDE (LSP completions, inline diagnostics, multi-cursor)
- Agent Runner (spawn, observe, interrupt, compose agents)

---

## Symbol Indexer

Tree-sitter AST extraction across 22 languages with incremental updates:

**Languages:** Swift, Python, TypeScript/JavaScript, Go, Rust, Java, C, C++, C#, Ruby, PHP, Kotlin, Bash, Lua, Scala, Elixir, Haskell, Zig, HTML, CSS + regex fallback for everything else.

**Dependency graph:** Bidirectional import tracking — "what does X import?" and "what imports X?" — across 15+ languages.

**Incremental:** Files are re-indexed only when changed. Parsed trees are cached (TreeCache) for fast re-parses. Projects under 50 files trigger targeted updates; larger projects use full re-index when needed.

**Outline-first:** `senkani_read` returns a file's symbol outline (~300 bytes) by default instead of full content (~3-20KB). Call `senkani_fetch` for specific symbols, or pass `full: true` for the complete file. First reads of code files save ~80-90%.

---

## Performance

Numbers from the built-in benchmark suite (`senkani bench`):

| Metric | Value |
|--------|-------|
| Terminal render latency | p50 ~2ms, p99 ~3.4ms |
| Filter throughput (git clone output) | >10k lines/sec |
| Symbol search | <5ms cold, <1ms cached |
| Secret scan | <2ms per KB |
| Binary size | ~28 MB universal |
| RAM (10 panes open) | ~180 MB |

---

## Architecture

| Module | Deps | Role |
|--------|------|------|
| **Core** | Filter | Session DB, feature config, metrics, budget enforcement, hook routing |
| **Filter** | — | Token compression: 44 cmd rules, ANSI strip, dedup, secrets, terse |
| **Indexer** | SwiftTreeSitter | 20 tree-sitter backends, FTS5 search, dependency graph, incremental parsing |
| **Bench** | Core, Filter, Indexer | Token savings test suite: 10 tasks × 7 configs, quality gates, JSON export |
| **MCP** | Core, Filter, Indexer, MLX | 13 MCP tools, socket server, vision + embedding inference |
| **HookRelay** | — | Zero-dep hook relay library shared by senkani-hook binary and app's --hook mode |
| **CLI** | Core, Filter, Indexer, Bench | 14 commands: exec, search, bench, doctor, grammars, init, … |
| **SenkaniApp** | All + SwiftTerm | SwiftUI workspace: 14 pane types, multi-project, menu bar, agent timeline |

---

## Building from Source

Prerequisites: macOS 14+, Swift 6.0+, Xcode 15+

```bash
swift build          # debug
swift build -c release
swift test
senkani doctor       # verify grammar and database setup
```

The GUI target (`SenkaniApp`) includes SwiftUI, SwiftTerm, and MLX. The CLI (`senkani`) and hook (`senkani-hook`) targets are lean — no MLX, no SwiftUI.

---

## License

MIT (core). See LICENSE.
