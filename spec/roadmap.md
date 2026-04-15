# Roadmap, Status & Technical Stack

> Source: SPEC.md lines 1122–1584
> Related: [tree_sitter.md](tree_sitter.md) for language expansion, [compound_learning.md](compound_learning.md) for Phase H

---

## Technical Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 6.0 |
| UI | SwiftUI + AppKit (hybrid) |
| Terminal | SwiftTerm via FocusableTerminalView bridge |
| MCP Protocol | modelcontextprotocol/swift-sdk |
| ML Inference | MLX Swift + Ollama (APEX GGUF) |
| Quantization | APEX (mudler/apex-quant) for MoE models |
| Hook Binary | Compiled Swift, zero dependencies, socket relay |
| Charts | Swift Charts (macOS 14+) |
| Previews | WKWebView with CSP sandboxing |
| File Watching | FSEvents via GCD DispatchSource |
| Data | SQLite+FTS5 (sessions), JSONL (live metrics), JSON (config) |
| Distribution | Notarized DMG (direct), Homebrew (CLI) |
| CLI | swift-argument-parser |
| Tests | Swift Testing framework |
| Scheduling | launchd plist generation |

### Build Products

```
SenkaniApp   — GUI + MCP server + daemon (the app)
senkani      — CLI (doctor, init, uninstall, schedule, compare, bench, grammars)
senkani-hook — Compiled hook relay binary (~100KB, zero dependencies)
```

---

## Structural Lessons Learned

1. `NSApplication.setActivationPolicy(.regular)` — without this, a CLI-launched macOS app cannot receive keyboard events
2. `startProcess` must be called after `viewDidMoveToWindow` — the PTY needs a real window
3. `super.mouseDown` not `terminalView.mouseDown` — direct calls bypass the responder chain
4. SwiftTerm needs explicit `NSFont.monospacedSystemFont` or text rendering may not initialize
5. Never write global hooks with empty matchers — they intercept all tools in all projects
6. Atomic writes for config files — write to temp, verify, rename
7. FTS5 queries need sanitization — strip operators to prevent injection
8. WKWebView needs CSP headers — disable JavaScript for markdown, restrict network for HTML
9. Solo agents ship fast but miss security issues — the full team audit found 35 issues
10. ML compression belongs in async background, not the synchronous pipeline — never block a tool call return on inference
11. Actors serialize all calls — use per-resource locks, not a global actor, for concurrent tool processing
12. Hook binaries must have zero dependencies — import nothing, relay everything, fail to passthrough
13. Per-pane token attribution is impossible when the MCP server is a separate process — query by project_root instead. Three debugging sessions proved this. Show per-project metrics in the app status bar, not per-pane footers.
14. Don't build two metrics paths (JSONL file watchers + DB polling) — pick one. The DB is the single source of truth. File watchers add complexity, race conditions, and path-matching bugs for zero benefit.
15. codedb (justrach/codedb) proves that tree-sitter + dependency graphs + structured results dramatically outperform raw grep for code intelligence. Regex-based symbol indexing was a pragmatic start but tree-sitter is the correct foundation. Agent registration (heartbeat, cursor, named sessions) solves per-session attribution at the protocol level.
16. Don't duplicate hook logic across targets — `Sources/Hook/main.swift` (standalone binary) and `Sources/Core/HookMain.swift` (app's `--hook` mode) are functionally identical code. One will drift. Either have the app import the Hook target directly, or have both call a shared function.
17. MemPalace (milla-jovovich/mempalace) proves that structured compression (AAAK dialect) achieves 8-10x lossless compression readable by any LLM without decoders. This STACKS with filtering: filter removes noise (60-90%), then AAAK compresses the clean remainder (8-10x) = 95%+ total. Also: 170-token wake-up context ($0.70/year) beats summarization ($507/year) for cross-session memory. Knowledge graphs with temporal triples and contradiction detection are the right backbone for compound learning.
18. **Tree-sitter internal headers must live OUTSIDE `publicHeadersPath`.** See [tree_sitter.md](tree_sitter.md) for full detail.
19. **Container resolution for symbols falls into three patterns.** See [tree_sitter.md](tree_sitter.md) for full detail.
20. **Vendor tree-sitter grammars rather than depending on SPM packages from grammar repos.** See [tree_sitter.md](tree_sitter.md) for full detail.

---

## Status (as of April 14 2026)

### What's Done and Working

| Component | Status | Evidence |
|-----------|--------|----------|
| **AutoRegistration** | ✅ Fixed | Registers MCP globally in `~/.claude/settings.json` with `command` + `args` only (no env block). Defensively removes old hooks on every launch. MCP server access gated by `SENKANI_PANE_ID` env var — only Senkani-spawned shells activate it. |
| **settings.json** | ✅ Fixed | Global MCP registration (no env block). Hooks use specific matchers `"Read\|Bash\|Grep\|Write\|Edit"`. Empty matcher violation (Lesson #5) resolved. |
| **MCPSession.recordMetrics()** | ✅ Writes JSONL + DB | Fallback path computed from project root when env var missing. |
| **MetricsWatcher** | ❌ Deleted | JSONL file watching was architecturally broken. File deleted April 12 (was already a 6-line comment-only stub). MetricsRefresher is the canonical DB-polling path. |
| **MetricsRefresher** | ✅ Active | Replaced MetricsWatcher + MetricsPoller. Polls SessionDatabase on 1-sec timer with 2 indexed queries. |
| **ClaudeSessionWatcher** | ✅ Built | 242 lines. FSEvents directory watching on ~/.claude/projects/ JSONL, tails active file, parses usage fields, writes to token_events via SessionDatabase. |
| **Token counters** | ✅ Working | Counters increment on MCP tool calls. Fixed April 8. |
| **PaneMetrics** | ✅ @Observable | Has totalInputTokens, totalOutputTokens, totalSavedTokens, formattedCostSaved. |
| **App status bar** | 🔄 Rebuilding | Replacing per-pane TokenCounterFooter with app-level status bar. |
| **FCSIT in header** | ✅ Moved | Controls in header. No per-pane footer — metrics in app status bar. |
| **Gear icon + settings panel** | ✅ Built | List→detail pattern: Optimization, Model, Display, Sizing, Advanced. |
| **SessionDatabase isolation** | ✅ Schema correct | project_root column, createSession accepts it, statsForProject filters by it. |
| **Terminal input** | ✅ Fixed | FocusableTerminalView + viewDidMoveToWindow + setActivationPolicy. |
| **13 MCP tools** | ✅ All working | Read, Exec, Search, Fetch, Explore, Outline, Deps, Validate, Parse, Embed, Vision, Session, Pane verified via protocol. |
| **Budget enforcement** | ✅ Built | BudgetConfig + ToolRouter gate. Per-session/daily/weekly limits. |
| **Theme engine** | ✅ 20 themes | VS Code format, hot-reload, persisted selection. |
| **16 pane types** | ✅ All routed | Terminal, Browser, Diff, Log, Scratchpad, Analytics, Dashboard, Skills, Knowledge, Models, Schedules, SavingsTest, AgentTimeline, CodeEditor, plus settings overlay. Sidebar "Add Pane" menu, ⌘K command palette. |
| **Code Editor pane** | ✅ Built | File tree sidebar (auto-opens project root), pure SwiftUI text rendering with tree-sitter syntax highlighting (22 languages), line numbers, token cost gutter annotations, file bar intelligence badges (token count, deps, AI access), symbol navigation via Cmd+click, multi-line text selection, 30K character cap for large files. |
| **22 tree-sitter languages** | ✅ Built | Original 20 + HTML + CSS. Grammar vendoring, highlight queries, FileWalker mappings, GrammarManifest entries. 8 HTML/CSS tests. |
| **626 unit tests** | ✅ Passing | Tree-sitter: ~230 across 22 languages. Layer 3: ReReadSuppression (8), CommandReplay (8), TrivialRouting (15), SearchUpgrade (8). Phase D: ModelRouter (24). Phase J: AutoValidate (21). MCP: WatchTool (8), BackgroundExec (8), PaneSocket (6). UI: CommandPalette (6), Dashboard (6). Cleanup: AdaptiveTruncation (6), SymbolStaleness (4), DaemonHealth (3). Plus: DependencyGraph (14), GrammarManifest (13), OutputSandbox (11), SavingsTestRunner (14), AgentTimeline (8), FeatureSavings (6), ScenarioSimulator (7), RepoMap (6), OutlineFirstRead (5), HTML/CSS (8), TreeCache+IncrementalParser (12), FileWatcher (9), and more. |
| **Output sandboxing in ExecTool** | ✅ Built | Large command outputs stored in `sandboxed_results` DB table, returned as compact summary with `result_id`. Retrieval via `senkani_session action="result"`. Modes: auto (default, sandbox if >20 lines), always, never. 24h prune on session start. 11 unit tests. Addresses the spec's #1 waste pattern. |
| **Token Savings Test Suite (Phase E)** | ✅ Built | `senkani bench` CLI + `Bench` library target. 10 tasks × 7 configs. **All 9 active quality gates pass. Overall multiplier: 80.37x** (spec target: ≥5x). Full run in ~25ms. JSON export via `--json`, category filter via `--categories`, CI mode via `--strict`. See [testing.md](testing.md) for deviations and deferred tasks (vision, embedding, validate, model-selection). |
| **Tree-sitter indexer** | ✅ Built | **20 languages**: Swift, Python, TypeScript, TSX, JavaScript, Go, Rust, Java, C, C++, C#, Ruby, PHP, Kotlin, Bash, Lua, Scala, Elixir, Haskell, Zig. ~230 tests. |
| **Grammar versioning system** | ✅ Built | `Sources/Indexer/GrammarManifest.swift` is the central registry. `senkani grammars list/check` CLI. `senkani doctor` integration. GitHub version checking with 24h cache. |
| **`senkani_outline` tool** | ✅ Built | File structure tool — returns symbols with line numbers. ~90% savings vs full file read. |
| **`senkani_deps` tool** | ✅ Built | Dependency graph queries: what imports what, which files import a symbol, direction: imports/importedBy/both. ~95% savings vs tracing manually. |
| **File-level incremental indexing** | ✅ Built | `IndexEngine` uses git blob hashing — detects changed/added/deleted files, re-parses only those. >50 files changed → full re-index fallback. |
| **Sub-file tree-sitter incremental parsing** | ✅ Built | `TreeCache` + `IncrementalParser` — stores parsed trees per file keyed by SHA-256, computes edit ranges via UTF-8 prefix/suffix diffing, feeds edited old tree back to `parser.parse(tree:string:)`. Warm re-parse <2ms. Measured ≥5x speedup vs cold parse. 12 unit tests. |
| **FSEvents auto-trigger** | ✅ Built | `FileWatcher` wraps `FSEventStreamCreate` on the project root. 150ms debounce collapses editor-save bursts. Filters by `FileWalker.languageMap` + `FileWalker.skipDirs`. Triggers `indexFileIncremental` per changed file and atomically updates the session's in-memory symbol index. Started in `warmIndex()`, stopped in `shutdown()`. 9 unit tests. |
| **Eager index warmup** | ✅ Built | `MCPSession.warmIndex()` loads cached index (<50ms) then incremental-updates in background. Non-blocking. |
| **Agent Timeline pane** | ✅ Built | Live feed of optimization events. 500ms polling from `token_events`. Pause button, expandable rows, color-coded savings tiers, footer stats. 8 unit tests. |
| **HookRelay consolidation** | ✅ Built | Zero-dep `HookRelay` library target shares canonical implementation between standalone `senkani-hook` binary and app's `--hook` mode. `Sources/Core/HookMain.swift` deleted (Lesson #16 resolved, Lesson #12 preserved). |
| **Re-read suppression (Phase I wedge)** | ✅ Built | HookRouter detects when a file was recently served by `senkani_read` and hasn't changed (mtime check). Returns a smart deny: "this file was already read Ns ago and hasn't changed" — eliminates the tool call entirely instead of redirecting to senkani_read. Events logged with `source="intercept"`, `feature="reread_suppression"`. 8 unit tests + 7 E2E scenarios verified through live daemon. |
| **MCP registration model** | ✅ Rebuilt | Global registration in `~/.claude/settings.json` (command + args, no env block). `SENKANI_PANE_ID` env-var access gate in MCPMain.swift — MCP server exits immediately if absent. Only Senkani-spawned shells (which inject the env var via execve) activate the MCP server. Non-Senkani terminals never see Senkani tools, even after crashes. One-time `cleanupStaleMCPFiles()` migration removes stale per-project `.mcp.json` files via Spotlight. |
| **Sidebar pane picker** | ✅ Consolidated | Hand-rolled 9-button Menu replaced with 2-item Menu: "Claude Code..." (ClaudeLaunchSheet) and "New Pane..." (AddPaneSheet). Single source of truth for pane types — new types auto-appear. |
| **Phase D: Model routing** | ✅ Built | ModelRouter with difficulty scoring (heuristic, <0.1ms), 5 presets (Auto/Build/Research/Quick/Local), per-pane dropdown in header, CLAUDE_MODEL env injection, 24 tests. |
| **Phase J: Auto-validate** | ✅ Built | PostToolUse → AutoValidateQueue (debounced) → AutoValidateWorker (niced subprocess, 5s timeout) → DiagnosticRewriter (table-driven) → validation_results DB → PreToolUse advisory injection. 21 tests. |
| **⌘K Command Palette** | ✅ Built | Floating search-as-you-type overlay. 16 pane types + themes + actions. NSEvent monitor for ⌘K. CommandEntryBuilder in Core for testability. 6 tests. |
| **Dashboard pane** | ✅ Built | Hero savings card (48pt green $), summary cards, project breakdown table, savings-over-time line chart, feature bar chart, auto-generated insights. 6 tests. |
| **senkani_watch tool** | ✅ Built | FSEvents ring buffer (500 entries) on MCPSession, cursor+glob query, 8 tests. |
| **senkani_exec background mode** | ✅ Built | BackgroundJob registry, detach/poll/kill, 10min auto-kill, 1MB output cap, 8 tests. |
| **Pane socket migration** | ✅ Built | pane.sock Unix socket replaces JSONL file polling (<10ms vs 5s). PaneControlTool rewritten as socket client. 6 tests. |
| **Adaptive truncation** | ✅ Built | Output caps scale with budget remaining (1MB → 512KB → 256KB → 64KB). 6 tests. |
| **Symbol staleness notifications** | ✅ Built | Track queried symbols, detect changes via FileWatcher, prepend notice to next tool response. 4 tests. |
| **Socket health check** | ✅ Built | senkani doctor check #10: connect to hook.sock/pane.sock with 1s timeout. 3 tests. |
| **Broadcast mode** | ✅ Built | Type in broadcast bar → sends to all terminal panes via NotificationCenter. |
| **Notification rings** | ✅ Built | Blue ring on pane status dot when unread output + pane not focused. |
| **Sidebar metadata** | ✅ Built | Git branch per project (cyan capsule badge). |
| **Display settings** | ✅ Built | Font size slider (8-24pt) + presets in pane settings panel. Applied via TerminalViewRepresentable. |
| **Prompt injection detection** | ✅ Built | InjectionGuard: 4 categories (instruction override, tool call injection, context manipulation, exfiltration), 13 regex patterns, anti-evasion (homoglyphs, zero-width, whitespace collapse). Stage 4 in FilterPipeline. Default OFF via SENKANI_INJECTION_GUARD. 14 tests. |
| **ML verification** | ✅ Fixed | Stale model IDs fixed (qwen2-vl-2b → gemma4 tiers). verifyInference() added. Doctor checks all registered models dynamically. Hot files pre-cache wired. 14 tests. |
| **Session continuity** | ✅ Built | SessionBriefGenerator: ~150-token context brief injected at session open. Reconstructs last session activity from DB (hot files, search queries, last command, duration, savings %). Default ON. 14 tests. |

### What's Broken

| Issue | Severity | Root Cause | Status |
|-------|----------|-----------|--------|
| **Hook binary was bash wrapper** | ~~HIGH~~ FIXED | `AutoRegistration.installHookWrapper()` now checks magic bytes and prefers compiled Mach-O. Falls back to bash wrapper only if binary missing. | ✅ Fixed — compiled binary preferred on every launch. |
| **Empty hook matchers** | ~~HIGH~~ FIXED | `.claude/settings.json` now has `"matcher": "Read\|Bash\|Grep\|Write\|Edit"` on both PreToolUse and PostToolUse. | ✅ Fixed. |
| **Two projects show same numbers** | MEDIUM | Now likely resolved — MCP registration model rebuilt (global + env-var gating). SENKANI_PROJECT_ROOT propagates via execve → claude → MCP server. | Needs verification with two simultaneous sessions to close. |
| **HookMain.swift duplication** | ~~LOW~~ FIXED | `HookRelay` library target consolidates the code. `Sources/Core/HookMain.swift` deleted April 12. | ✅ Fixed. |

### What's Not Built Yet

| Feature | Priority | Notes |
|---------|----------|-------|
| ~~**SavingsTest Mode 2: Live Session Replay**~~ | ~~HIGH~~ ✅ DONE | Built April 12. `SavingsTestView` has Fixture + Live tabs. Live tab: `tokenStatsByFeature` query, per-feature savings bars, session multiplier, top events. 2-sec refresh. 6 unit tests. |
| ~~**SavingsTest Mode 3: Scenario Simulator**~~ | ~~HIGH~~ ✅ DONE | Built April 12. 6 scenarios (explore 2.4x, debug 5.0x, refactor 4.8x, add feature 3.6x, code review 1.9x, CI 10.8x). Updated to reflect outline-first read savings. |
| **Additional fixture bench tasks** | MEDIUM | Current bench runs 10 tasks. Target from spec is 21. Remaining tasks need underlying features first: vision (Gemma 4), embedding (MiniLM-L6), AAAK compression, validate (live compiler), model selection, combined end-to-end. Each comes online as its feature ships. |
| **Full usage tracking** | HIGH | ClaudeSessionWatcher built (Tier 1). Remaining: Tier 2 hooks for other agents (~90%), Tier 3 MCP-only (~40%). |
| ~~**Per-pane model routing**~~ | ~~HIGH~~ ✅ DONE | Built April 14. ModelRouter + 5 presets + header dropdown + CLAUDE_MODEL injection. 24 tests. |
| ~~**ML model download + real inference**~~ | ~~HIGH~~ ✅ DONE | Stale model IDs fixed (qwen2-vl-2b → gemma4 tiers). ModelManager.verifyInference() added. Download handler uses ModelManager.visionModelIds.contains(). Doctor checks all registered models dynamically. 14 ML pipeline tests. |
| ~~**Outline-first read**~~ | ~~HIGH~~ ✅ DONE | Built April 13. `senkani_read` returns outline by default, full content via `full: true`. |
| ~~**Repo map in MCP instructions**~~ | ~~HIGH~~ ✅ DONE | Built April 13. `SymbolIndex.repoMap(maxTokens:)` generates compact TOC, injected into MCP instructions at session start. Cached on MCPSession, invalidated on index update. |
| **Live-session replay harness** | HIGH | Record 5-10 representative Claude Code sessions, replay through optimization stack, publish paired fixture/live multiplier numbers. Gates any marketing use of the 80x figure. See [testing.md](testing.md) Live Session Caveat. |
| ~~**Dashboard pane**~~ | ~~MEDIUM~~ ✅ DONE | Built April 14. Hero card, project table, charts, insights. 6 tests. |
| **FCSIT detail drawer** | MEDIUM | Click toggle → per-feature breakdown with top commands, sparkline. |
| **Metrics persistence on restart** | MEDIUM | Per-feature and time-series data may not all survive restart. |
| **Process lifecycle** | MEDIUM | No kill/restart buttons. No PID tracking. |
| ~~**`senkani uninstall`**~~ | ~~LOW~~ ✅ DONE | Built April 13. Scans 7 artifact types, confirmation prompt, --yes and --keep-data flags. Needs manual testing (see cleanup.md #15). |
| ~~**`senkani_watch` tool**~~ | ~~MEDIUM~~ ✅ DONE | Built April 14. Ring buffer (500 entries), cursor+glob query. 8 tests. |
| ~~**`senkani_exec` background mode**~~ | ~~MEDIUM~~ ✅ DONE | Built April 14. BackgroundJob registry, detach/poll/kill, 10min auto-kill. 8 tests. |
| ~~**Hot files ranking**~~ | ~~MEDIUM~~ ✅ DONE | hotFiles() query + preCacheHotFiles() in MCPSession. Pre-populates ReadCache with top 20 files on session start. 500KB per-file cap, utility queue. |
| **Agent registration** | MEDIUM | Named agent with heartbeat, cursor, named sessions. Solves per-session attribution at protocol level. |
| **Compound learning** | Phase H | Analyze→Propose→Evaluate→Apply loop. Start with wedge: detect repeated file reads → auto-generate pre-cache list. |
| **Knowledge graph** | MEDIUM | Temporal entity-relationship triples. |
| **Decision Records** | MEDIUM | `get_why(symbol)` knowledge tool. Mine git history + annotations + CLI for architectural rationale. Freshness-scored (stale flag when source changes). Co-change coupling matrix as workflow signal. |
| **L0/L1/L2 tiered context** | MEDIUM | Tier files by 7-day access frequency. Pre-warm L0/L1 on session start. ~15-25% cache hit improvement over cold-start. |
| ~~**Repo map wake-up context**~~ | ~~MEDIUM~~ ✅ DONE | Same as "Repo map in MCP instructions" above. |
| ~~**Layer 3 remaining patterns**~~ | ~~Phase I~~ ✅ DONE | All 5 patterns shipped April 12–14: re-read suppression, command replay, trivial routing, search upgrade, redundant validation (via command replay). 39 tests. |
| ~~**Auto-validate reactions**~~ | ~~MEDIUM~~ ✅ DONE | Built April 14. PostToolUse → debounced queue → niced subprocess → diagnostic rewriter → advisory. 21 tests. |
| ~~**⌘K command palette**~~ | ~~MEDIUM~~ ✅ DONE | Built April 14. Search-as-you-type overlay, 16 pane types + themes + actions. 6 tests. |
| **Workstream isolation** | MEDIUM | "New Workstream" button: auto-creates git worktree + pane pair. See [app.md](app.md). |
| **Entropy-based secret detection** | MEDIUM | Layer entropy scoring on top of existing `SecretDetector` pattern matching. Current 7 regex patterns catch named formats (Anthropic, OpenAI, AWS, GitHub, bearer tokens). Entropy scoring catches unnamed secrets — any high-entropy string (random base64/hex blobs) that don't match a known format. Add `EntropyScanner.swift` alongside `SecretDetector.swift`; both run in Stage 2 of `FilterPipeline`. Do not replace pattern matching — union of both. |
| **JS-rendered fetch + AXTree extraction** | MEDIUM | `senkani_fetch` currently issues raw HTTP, failing silently on SPAs. Build JS-rendering and AXTree extraction directly into `FetchTool` — inspired by Lightpanda's approach (AGPL-3.0, not bundleable). AXTree extraction converts live DOM to an accessibility tree — near-zero-token page representation — piped through the compression layer before sending to Claude. Implementation: WKWebView for JS rendering (already available in the app sandbox), accessibility tree traversal via AX APIs. No third-party code incorporated. |
| **BM25 + RRF search fusion** | MEDIUM | `senkani_search` is currently file-level grep. The tree-sitter symbol index is already built — upgrade the query layer to a BM25 corpus over token-indexed symbol-level snippets, then fuse with semantic results via Reciprocal Rank Fusion (1/(k+rank_bm25) + 1/(k+rank_vec), k=60). Surfaces rank-fused symbol-level context instead of raw grep matches. Directly improves the quality of every search-before-read pattern in Layer 2. |
| **Specialist pane diaries** | FUTURE | Per-pane cross-session memory. |
| **Codebase snapshot** (`senkani_bundle`) | FUTURE | Full codebase as one structured document. |
| **Remote repo queries** | FUTURE | Query any public GitHub repo without cloning. |
| **iPhone companion** | FUTURE | Session monitoring, budget alerts. |

---

## Strategic Considerations (April 11)

External review of the spec (ironically, conducted through a Claude Code session running on Senkani's own MCP server — Layer 2 hooks correctly intercepted the Read calls and redirected them through `senkani_read`) surfaced four ordering questions worth naming explicitly before committing to Phase F:

### 1. Phase F vs Phase G ordering

**Current order:** D (remainder) → E (done) → F (AAAK + knowledge graph) → G (polish + ship).

**The question:** AAAK is flagged as the "highest-ROI unbuilt feature" because it stacks multiplicatively with filter. If it delivers 8-10x on top of the existing stack, it compounds everything downstream. But it's also the most speculative work in the roadmap — the format needs design, every tool needs integration, and every LLM needs validation. Phase G (polish + ship) is lower-ceiling but far lower-risk.

**Competing frames:**
- **"Ship first" frame:** Phase G before F. Users validate the *current* 5-10x claim on live sessions first. Phase F lands as v2 once the moat (Phase I) is demonstrably real. This matches the spec's "Structure Before Features" principle — don't stack unproven optimization on top of unvalidated numbers.
- **"Compound first" frame:** Phase F before G. AAAK multiplies everything the test suite already measures, so polish lands on top of a 30-50x product instead of a 5-10x one. Matches the spec's "Measure Everything" principle because the test suite already exists to validate the multiplication.

**Status:** Open. No decision yet. Flagging here so future choices are deliberate, not path-dependent.

### 2. The 80.37x headline is a fixture number, not a live-session number

The Phase E benchmark shows 80.37x overall cost reduction across 10 synthetic tasks. This is a *real measurement* of the optimization math, not a marketing number — the filter pipeline, cache, indexer, sandboxing, secrets, and parse tool genuinely produce those reductions on those inputs.

But the fixtures maximize reuse and cache hits by design. Real sessions have:
- More novel file reads (cache hit rate drops)
- Cold symbol indexes on first tool call (warmup cost that fixtures skip)
- Variable command outputs — not every `git clone` has 200 "Receiving objects" lines to collapse
- Agent-driven tool ordering that the benchmark doesn't simulate

**What the spec should NOT do:** Show "80x" in the README without a live-session caveat. That anchors user expectations badly and sets the product up for a credibility loss.

**What the spec SHOULD do:** Run the bench suite against live transcripts once Phase G ships. Publish both numbers: "fixture bench 80x" and "live session median Nx". The live number is the one users will quote.

**Action item:** Add a "live session validation" task to Phase G exit criteria — record 5-10 representative Claude Code sessions, replay them through the optimization stack, publish the resulting multiplier alongside the fixture number. Don't let the fixture number leak into marketing before that lands.

### 3. Layer 3 is the moat but entirely unbuilt

Phase I's preemptive intent interception (REDIRECT response type, re-read suppression, command replay, search upgrade) is what makes Senkani **categorically different** from a good MCP wrapper. It's the only layer that works on closed-source agents that can't cooperate via MCP. Everything else in the spec is "a better version of things the agent already wanted to do."

Currently: nothing built. Designed in [hooks.md](hooks.md), dependency on Phase C (compiled hook binary ✅) and Phase H (compound learning) — so the blocker is H, not C.

**The strategic implication:** Until Phase I ships, a skeptical observer is correct to call Senkani "a good MCP wrapper, not something categorically different." The product's defensibility story rests on Phase I being real. The roadmap should probably reflect Phase I's strategic weight — it's not just another optimization, it's the moat.

**Action item (not decided yet):** Consider building a minimal Phase I wedge — just re-read suppression — before Phase H. Re-read suppression doesn't need compound learning; it just needs the hook binary (✅) + a cache lookup. Shipping that in isolation would prove the Layer 3 approach is viable and give the README a credible "works with agents that don't cooperate" claim.

### 4. Cleanup items 1, 5, and 10 before new feature work

From [cleanup.md](cleanup.md):
- **#1 HookMain.swift duplication** — 5-minute fix, high drift risk. Do it.
- **#5 MetricsWatcher dead code** — 30-minute fix, makes the architecture story honest. Do it.
- **#10 senkani_pane file-based IPC with 5-second poll** — not urgent today, but it's a hard blocker for workstream isolation and the ⌘K command palette (both in `What's Not Built Yet`). Migrate to the socket path BEFORE building either feature.

These are 30-minute tasks that reduce the surface area for future bugs and architectural contradictions. The spec already catalogs them; the question is whether to do them before or after the next feature prompt. Recommendation: before.

---

## Roadmap (Phased)

### Phase A: Make the Numbers Move (MOSTLY DONE)

Token counters increment (fixed April 8). Core metrics pipeline works.

```
MCP tool → INSERT token_events (project_root, saved_tokens) → DB
Claude JSONL → ClaudeSessionWatcher → INSERT token_events (exact input/output) → DB
StatusBarView → 1-sec timer → query DB by project_root → display
```

Remaining: Verify two projects show different numbers. Delete deprecated MetricsWatcher.swift.

### Phase B: Per-Project Isolation

Two projects must show different numbers. Fix the projectRoot flow and verify with two simultaneous Claude sessions.

**Exit criteria:** Project A shows $1.20 saved, Project B shows $0.40 saved. Different numbers, same app.

### Phase C: Deploy Hook Binary + Full Usage Tracking

Deploy `senkani-hook` release binary and fix hook registration.

Three capabilities this enables:
1. **Budget enforcement** on ALL tool calls
2. **Compliance tracking** — what % of calls go through senkani tools
3. **Full usage tracking** (Claudoscope-level)

Hook events to handle:
- **PreToolUse** → log tool name + input size → estimate input tokens consumed
- **PostToolUse** → log output size → estimate output tokens consumed
- **Stop** → capture conversation usage stats → reconcile estimates with actuals

Also: **Agent Registration**. Each Claude session registers as a named agent with the MCP server via handshake on first tool call. Agent gets unique ID, heartbeat tracking, and cursor position. Solves per-session attribution at the protocol level.

**Exit criteria:** Budget limit blocks a tool call. Compliance tracking shows % optimized. For Claude Code: exact token counts from session JSONL (100% match with Anthropic billing).

### Phase D: Model Routing + ML Verification + Code Intelligence

**Status (April 11):** Code intelligence half is **complete**. Tree-sitter backend at 20 languages. Grammar versioning complete. `senkani_outline`, `senkani_deps`, eager index warmup, sub-file tree-sitter incremental parsing (TreeCache + IncrementalParser), and FSEvents auto-trigger (FileWatcher) all built. The symbol index now self-updates during active editing without any manual re-index call.

Remaining (ML + routing half):
- Per-pane model routing (Auto/Build/Research/Quick/Local) — UI exists, routing not wired
- ML inference verification (download + test Gemma 4 E4B + MiniLM-L6 with real prompts)
- Hot files ranking (data exists in token_events, pre-cache logic not built)

**Exit criteria:** "Quick" pane uses Haiku. "Local" pane uses Gemma 4. Auto mode routes correctly. `senkani_deps` returns import graph ✅. Eager index warmup works with tree-sitter backend ✅. Incremental tree-sitter re-parsing <2ms per file ✅.

### Phase E: Token Savings Test Suite (✅ DONE — April 11)

**Status:** Complete. `senkani bench` CLI ships, `Bench` library target shipped, 14 unit tests passing, quality gate framework operational.

**Measured result:** Overall cost multiplier **80.37x** against the ≥5x spec target. All 9 active quality gates pass (Filter 98.5%, Cache 80%, Indexer 100%, Terse 91.5%, Secrets 100%, Sandbox 97%, Parse 99.6%, plus no-regression and overall-multiplier gates).

**Scope shipped:** 10 tasks × 7 configurations = 70 runs in ~25ms. Runs through `swift test` (unit tests) and `swift run senkani bench` (CLI). JSON export via `--json`, category filter via `--categories`, strict CI mode via `--strict`.

**Scope deferred to Phase G (UI) and downstream features:** SavingsTest pane wiring, vision/embedding/AAAK/validate/model-selection tasks (each comes online when its underlying feature ships). See [testing.md](testing.md) for the full deviation list.

**Exit criteria (all met):** Test suite shows ≥5x cost reduction across the standard workload ✅. All active quality gates pass ✅. Reproducible — deterministic fixtures, no live commands ✅. CI-friendly — `senkani bench --strict --json out.json` for automated runs ✅.

### Phase F: Smart First-Read Selection + Knowledge Graph (AAAK dropped — see below)

**AAAK was dropped April 12.** Independent analysis debunked the 8-10x claim — AAAK uses more tokens than plain text, regresses accuracy by 12.4%, and source code can't be meaningfully abbreviated (BPE tokenizers already compress code keywords into single tokens). See [optimization_layers.md](optimization_layers.md) Layer 6 for full rationale.

**Replacement: Outline-first read + repo map.** These attack the actual bottleneck (first-reads of source files produce zero savings) using selection instead of compression:

- **Outline-first read** — `senkani_read` returns an outline (symbols + line numbers) on first read instead of full content. Agent calls `senkani_fetch` for specific symbols. ~80-90% savings on every first read.
- **Repo map** (Aider's approach) — inject a compressed symbol map of the entire project into MCP instructions at session start. Agent starts every session knowing every file/class/function. 4.2x fewer tokens than Claude Code on equivalent tasks (proven by Aider).
- **Knowledge graph** — temporal entity-relationship triples in SQLite (unchanged from original spec). Cross-session project memory, contradiction detection, wake-up context.

**Exit criteria:** Outline-first read default on `senkani_read`. All scenario multipliers improve by ≥2x from current values. Repo map loads in <5ms and fits within 2000 tokens. Knowledge graph has ≥20 facts for an active project.

### Phase G: Polish + Ship

**Code polish (prompt-able):**
- ✅ SavingsTest pane UI (Mode 1: fixture bench with results, gates, export)
- ✅ SavingsTest Mode 2: Live Session Replay — per-feature breakdown + session multiplier from real `token_events`
- ⬜ SavingsTest Mode 3: Scenario Simulator (6 built-in task templates with estimated multipliers) — see [testing.md](testing.md)
- ⬜ FCSIT detail drawer (click toggle → per-feature breakdown with top commands, sparkline)
- ⬜ `senkani uninstall` CLI command (clean removal of all config entries)
- ⬜ Metrics persistence on restart (per-feature + time-series data survives app restart)
- ⬜ Process lifecycle controls (kill/restart buttons in pane header, PID tracking)
- ⬜ Live-session replay harness (record 5-10 real sessions, publish paired fixture/live multiplier numbers)

**Distribution (manual/ops):**
- ⬜ Apple Developer ID + code signing
- ⬜ Notarized DMG packaging
- ⬜ Homebrew formula for CLI tools (`brew install senkani`)
- ⬜ README with real comparison screenshots (before/after token counts on a representative session)

**Exit criteria:** App is shippable to non-developers. SavingsTest pane shows all three modes. `senkani uninstall` works. README has honest paired numbers (fixture + live). Binary is signed and notarized. Homebrew formula installs the CLI.

### Phase H: Compound Learning

Session analysis → propose → evaluate → apply loop. Gemma 4 analyzes `token_events` + knowledge graph on session close. Proposes new filter rules, pre-cache lists, AAAK templates, routing suggestions. Runs Token Savings Test Suite as quality gate.

See [compound_learning.md](compound_learning.md) for full detail.

**Exit criteria:** After 10 sessions, Senkani has generated ≥3 custom filter rules AND ≥3 AAAK templates specific to the user's workflow. Savings improved by ≥15% over static baseline.

### Phase J: Auto-Validate Reactions (Layer 2 Reactive)

Wire PostToolUse → background validator runs → advisory feedback on next turn.

See [hooks.md](hooks.md) for full detail.

**Depends on:** Phase C (compiled hook binary deployed; PostToolUse matchers fixed).

**Exit criteria:** Auto-validate fires on ≥95% of Edit/Write events. p99 PostToolUse hook latency stays <1ms. Dogfood criterion: catches ≥1 real typecheck error on Senkani's own code.

### Phase I: Preemptive Intent Interception (Layer 3) — ✅ ALL PATTERNS SHIPPED

**Protocol limitation discovered April 12:** Claude Code's hook protocol does NOT support a REDIRECT response type. The available `permissionDecision` values are `allow`, `deny`, `ask`, `defer`. See [hooks.md](hooks.md) for full detail. All five interception patterns use `deny` + smart messaging as the implementation strategy.

**All five interception patterns shipped (April 12–14):**

| Pattern | Shipped | Tests | How it works |
|---------|---------|-------|-------------|
| **Re-read suppression** | April 12 | 8 | File already served + unchanged → deny with "already read" |
| **Command replay** | April 13 | 8 | Replayable command (test/build/lint) + no file changes → deny with cached result |
| **Trivial routing** | April 14 | 15 | ls/pwd/echo/whoami/date/hostname → deny with answer embedded (saves full round-trip) |
| **Search upgrade** | April 14 | 8 | 3+ sequential Read denials on distinct files → append hint to use senkani_search |
| **Redundant validation** | April 13 | — | Covered by command replay — swift build, cargo check, tsc --noEmit all in replayable list |

**Architecture:** `ReadDenialTracker` (NSLock-protected, 30s window, distinct path counting) tracks Read denials for search upgrade. Trivial routing answers 6 command families locally via FileManager/ProcessInfo. Both features follow the established `deny`-based pattern with `source="intercept"` event recording.

**Depends on:** Phase C (compiled hook binary) ✅. Phase H dependency REMOVED — all patterns work without compound learning.

**Exit criteria:** Re-read suppression saves ≥80% on repeated file reads ✅. Command replay eliminates redundant test/build runs ✅. Trivial routing eliminates round-trips for 6 command families ✅. Search upgrade hints after 3+ sequential reads ✅. Zero false positives on deterministic patterns ✅. 39 unit tests across 4 test suites ✅.

---

## Future

- Multi-agent orchestration (per-agent budgets, task queues)
- Specialist pane diaries (cross-session per-pane memory)
- iPhone companion (monitoring, alerts)
- Cross-platform (Linux server deployments)

---

## Why This Wins

1. **Three layers, complete coverage.** Tools optimize willing agents. Hooks enforce across unwilling agents. Intercepts redirect agents that *can't* cooperate.

2. **Measurably better.** The savings bar proves it in real-time. The test suite proves it with numbers. The analytics pane proves it with charts.

3. **Structurally sound.** Every feature tested. Every optimization measured. Every security concern audited.

4. **Works with everything.** Claude Code, Cursor, Codex, Ollama, claw-code, any MCP-compatible agent.

5. **Two models, not ten.** Gemma 4 (auto-selected by RAM via APEX) plus MiniLM-L6.

6. **Private.** All optimization happens locally. The frontier model sees less, not more.

7. **Faster than raw.** The cache makes Senkani faster than not having it.

8. **Self-proving.** The app contains its own benchmark. Run the savings test. See the numbers. Decide for yourself.
