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
| **Analytics pane** — token/cost savings with realtime sparkline | ✅ Live |
| **Model manager pane** — download/manage local LLMs | ✅ Live |
| **Savings test pane** — benchmark runner UI | ✅ Live |
| **Diff viewer / log viewer / scratchpad panes** | ✅ Live |
| **Agent timeline pane** — tool call history | ✅ Live |
| **Multi-project workspace** — persistent per-project layout | ✅ Live |
| **Menu bar integration** — lifetime stats, socket toggle, launch-at-login | ✅ Live |
| **MCP intelligence layer** — 13 tools, auto-registers with Claude Code | ✅ Live |
| **Filter pipeline** — 24+ command-specific rules, ANSI stripping, dedup | ✅ Live |
| **Secret redaction** — API keys, AWS tokens, GitHub PATs, Bearer tokens | ✅ Live |
| **Terse compression** — algorithmic word/phrase minimization | ✅ Live |
| **Symbol indexer** — 20 languages, tree-sitter AST + regex fallback | ✅ Live |
| **Incremental indexing** — re-indexes only changed files | ✅ Live |
| **Dependency graph** — bidirectional imports, 15+ languages | ✅ Live |
| **Session database** — SQLite + FTS5, token tracking, cost history | ✅ Live |
| **Hook system** — budget enforcement, tool routing, 5ms latency | ✅ Live |
| **Local vision** — Gemma on Apple Silicon MLX, no API cost | ✅ Live |
| **Local embeddings** — MLX, no API cost | ✅ Live |
| **CLI** — 13 commands: exec, search, bench, doctor, grammars, … | ✅ Live |
| **Benchmarking suite** — filter, indexer, cache, terse, with reporters | ✅ Live |
| IDE pane (LSP, tree-sitter editor) | 🔄 Planned |
| Knowledge base pane (semantic search UI) | 🔄 Planned |
| Agent runner pane (spawn, observe, interrupt) | 🔄 Planned |
| Workflow builder (pipeline graph UI) | 🔄 Planned |
| Multi-repo git view | 🔄 Planned |
| Command palette (⌘K) | 🔄 Planned |
| SSH / Mosh pane | 🔄 Planned |

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

**MCP server:** Auto-registered with Claude Code on first launch via `senkani init`. The same binary detects piped stdin and switches to MCP server mode — no flags, no config.

---

## The MCP Intelligence Layer

13 tools that sit between Claude and your filesystem, compressing everything before it hits your token budget.

| Tool | What it does | Savings |
|------|-------------|---------|
| `senkani_read` | File reads: ANSI strip, blank collapse, secret detection, session cache | 50–99% |
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
| `senkani_exec` | Shell commands with per-command filter rules applied | 60–90% |
| `senkani_session` | View stats, toggle features, manage panes | — |

**Feature toggles** — all on by default, configurable per-pane or globally:

| Toggle | Env var | Effect |
|--------|---------|--------|
| Filter | `SENKANI_FILTER` | Command-specific output rules |
| Secrets | `SENKANI_SECRETS` | Redact secrets before they reach the AI |
| Indexer | `SENKANI_INDEXER` | Symbol index for search/fetch/explore |
| Terse | `SENKANI_TERSE` | Algorithmic phrase compression |

---

## The Workspace

A horizontal canvas of panes. Each pane is a primitive type; you arrange them however makes sense for what you're doing right now, and Senkani persists the layout per project.

**Pane types available today:**

- **Terminal** — SwiftTerm, Apple Silicon native, sub-3ms render, full color/ligature support
- **Markdown Preview** — live render from file, updates on save
- **Browser** — WKWebView embedded, localhost or any URL
- **Analytics** — token/cost savings per session with sparkline charts
- **Model Manager** — download, verify, and delete local LLMs (Gemma, MiniLM)
- **Savings Test** — run the benchmark suite from the UI
- **Agent Timeline** — timeline of agent tool calls and decisions
- **Diff Viewer** — side-by-side diff
- **Log Viewer** — searchable log output
- **Scratchpad** — rich text notes

**Pane types coming:**

- IDE (LSP completions, tree-sitter highlighting, multi-cursor)
- Knowledge Base (semantic search across code + notes)
- Agent Runner (spawn, observe, interrupt, compose agents)

---

## Symbol Indexer

Tree-sitter AST extraction across 20 languages with incremental updates:

**Languages:** Swift, Python, TypeScript/JavaScript, Go, Rust, Java, C, C++, C#, Ruby, PHP, Kotlin, Bash, Lua, Scala, Elixir, Haskell, Zig + regex fallback for everything else.

**Dependency graph:** Bidirectional import tracking — "what does X import?" and "what imports X?" — across 15+ languages.

**Incremental:** Files are re-indexed only when changed. Parsed trees are cached (TreeCache) for fast re-parses. Projects under 50 files trigger targeted updates; larger projects use full re-index when needed.

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
| **Core** | — | Session DB, feature config, metrics, budget enforcement |
| **Filter** | — | Token compression: 24+ cmd rules, ANSI strip, dedup, secrets, terse |
| **Indexer** | — | Tree-sitter backends, FTS5 search, dependency graph, incremental updates |
| **MCP** | Core, Filter, Indexer, MLX | 13 MCP tools, socket server, vision + embedding inference |
| **Hook** | — | Ultra-lightweight hook binary (zero non-Foundation deps, 5ms budget) |
| **CLI** | Core, Filter, Indexer | 13 commands: exec, search, bench, doctor, grammars, init, … |
| **SenkaniApp** | All + SwiftTerm | SwiftUI workspace: 14 pane types, multi-project, menu bar |

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
