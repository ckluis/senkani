# Senkani (閃蟹)

**The app that makes your AI subscription work 5x better.**

Senkani is a native macOS app that intercepts perception tasks -- file reads, command output, code search, image analysis -- and routes them to free local specialists before they hit your AI. The result: 50-90% fewer tokens consumed per session, with no change to your workflow. Your $20/month subscription does more because Senkani stops wasting it on tasks a local tool handles instantly.

<!-- TODO: Add screenshot of savings cards -->

---

## Quick Start

**Double-click:** Download `Senkani.app`, open it, done. It runs as a GUI with a menu bar indicator.

**Build from source:**
```
swift build -c release
```

**CLI (filtered output):**
```
senkani exec -- git status
```

**MCP server:** Auto-registered with Claude Code on first launch. Senkani detects piped stdin and switches to MCP mode automatically -- no flags needed.

---

## The 10 Specialist Tools

| Tool | Replaces | How | Savings |
|------|----------|-----|---------|
| `senkani_read` | File reads | ANSI strip, blank collapse, secret detection, session caching. Re-reads of unchanged files return instantly. | 50-99% |
| `senkani_exec` | Shell commands | 24 command-specific filter rules (git, npm, cargo, docker, etc.). Strips ANSI, deduplicates, truncates. | 60-90% |
| `senkani_search` | Grep/find | Searches a local symbol index by name, kind, file, or container. ~50 tokens vs ~5000 from grepping files. | 99% |
| `senkani_fetch` | Full file reads | Reads only the symbol's lines, not the entire file. | 50-99% |
| `senkani_explore` | Directory listings | Symbol tree grouped by file with type hierarchy. ~500 tokens for a typical project. | 90%+ |
| `senkani_session` | Manual tracking | View stats, toggle features, manage validators, reset cache. | -- |
| `senkani_validate` | AI-based linting | Runs local compilers/linters. 30+ validators across 15+ languages (syntax, type, lint, security, format). | 100% |
| `senkani_parse` | Raw build output | Extracts structured results (pass/fail counts, error locations, stack traces) from build/test/lint output. | ~90% |
| `senkani_embed` | Semantic search via API | Local embeddings on Apple Silicon (MiniLM-L6, ~90MB). Find code by meaning, not text. | $0/call |
| `senkani_vision` | GPT-4o vision calls | Local vision model on Apple Silicon (Qwen2-VL 2B). OCR, UI analysis, screenshot reading. | $0/call |

---

## How It Works

Senkani is a **dual-mode binary**. Double-click it and you get the GUI. Pipe stdin to it (or pass `--mcp-server`) and it becomes an MCP server. Same binary, no configuration.

```
                         ┌──────────────────────┐
                         │    AI Agent (Claude)  │
                         └──────────┬───────────┘
                                    │ MCP call
                                    ▼
                         ┌──────────────────────┐
                         │       Senkani         │
                         │  (route + compress)   │
                         └──────────┬───────────┘
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
     ┌────────────────┐  ┌────────────────┐  ┌────────────────┐
     │  Token Filter   │  │ Symbol Indexer  │  │  MLX Models    │
     │  (24 cmd rules) │  │ (FTS5 search)  │  │ (embed/vision) │
     └────────────────┘  └────────────────┘  └────────────────┘
              │                     │                     │
              └─────────────────────┼─────────────────────┘
                                    ▼
                         ┌──────────────────────┐
                         │   Compressed Result   │
                         │   (50-90% smaller)    │
                         └──────────────────────┘
```

**Feature toggles** control what processing is applied. All on by default:

| Toggle | Env Var | What it does |
|--------|---------|-------------|
| **F**ilter | `SENKANI_FILTER` | Command-specific output rules |
| **S**ecrets | `SENKANI_SECRETS` | Redact secrets before they reach the AI |
| **I**ndexer | `SENKANI_INDEXER` | Symbol index for search/fetch/explore |

---

## Features

- **Real-time savings cards** -- see token and cost savings per session
- **Menu bar indicator** -- lifetime stats, socket server toggle, launch-at-login
- **Model management** -- download, verify, and delete local ML models (MiniLM-L6 for embeddings, Qwen2-VL 2B for vision, Gemma 3 4B for generation)
- **Swift Charts analytics** -- visualize savings trends over time
- **Session history** with FTS5 full-text search
- **Skill browser** -- browse and manage available tool capabilities
- **Markdown/HTML preview panes** in the terminal workspace
- **Unix socket daemon mode** (`--socket-server`) for always-on local service
- **Launch at login** -- stays ready in the menu bar
- **Budget enforcement** (coming)
- **Scheduling** (coming)

---

## Configuration

**Feature toggles** can be set via environment variables, a project config file (`.senkani/config.json`), or at runtime through `senkani_session`. Resolution order: CLI flag > env var > config file > default (all on).

```bash
# Disable filtering for a session
SENKANI_FILTER=off senkani exec -- npm test

# Disable secret redaction
SENKANI_SECRETS=false
```

**Budget limits:** `~/.senkani/budget.json` (coming)

**Model cache:** `~/Library/Caches/dev.senkani/models/` for metadata; models themselves are stored in the HuggingFace cache at `~/Documents/huggingface/models/`.

---

## Building from Source

Prerequisites: macOS 14+, Swift 6.0+, Xcode 15+

```bash
git clone https://github.com/ckluis/senkani.git
cd senkani
swift build
swift test
.build/debug/SenkaniApp
```

The GUI target (`SenkaniApp`) includes SwiftUI, SwiftTerm, and MLX dependencies. The CLI target (`senkani`) is lighter -- no MLX, no SwiftUI.

---

## Architecture

| Module | Dependencies | Role |
|--------|-------------|------|
| **Core** | Filter | Session tracking, feature config, model registry, savings math. No MLX dependency. |
| **Filter** | (none) | Token compression engine. 24 command-specific rules, ANSI stripping, dedup, secret detection. |
| **Indexer** | (none) | Swift symbol indexer with FTS5 search. |
| **MCPServer** | Core, Filter, Indexer, MCP SDK, MLX | MCP protocol handler, 10 tool implementations, embedding and vision inference. |
| **CLI** | Core, Filter, Indexer, ArgumentParser | Standalone command-line interface. |
| **SenkaniApp** | All of the above + SwiftTerm | SwiftUI app: terminal workspace, analytics, model manager, menu bar. |

---

## Contributing

1. Fork the repo
2. Create a feature branch (`git checkout -b my-feature`)
3. Make your changes
4. Run tests (`swift test`)
5. Open a pull request

Tests must pass before merging.

---

## License

<!-- TODO: Choose license -->
