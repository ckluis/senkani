# Senkani (閃蟹) Charter

**Flash Crab — The native macOS + iPhone workspace that makes AI agents actually usable.**

---

## The Problem

Today, getting good results from AI agents requires duct-taping together 18+ separate tools:

- A terminal multiplexer to run multiple agents (Flock, tmux)
- A compression tool to stop token waste (RTK, Wren)
- A context manager to prevent sessions from dying (context-mode)
- A code indexer for token-efficient navigation (codemunch)
- An analytics dashboard to track costs (Claudoscope)
- A skill manager to organize prompts across tools (Chops)
- A skill registry to discover community skills (skills.sh)
- Specialist skill packs for role-based workflows (gstack, Agency Agents)
- A search engine for your knowledge base (qmd)
- A scheduler for recurring tasks (cron, launchd)
- An optimization loop for self-improving workflows (pi-autoresearch)
- A learning system for cross-session memory (Hermes Agent)
- A task loop runner for large projects (Chief)
- An orchestration layer for multi-agent teams (Ruflo, Paperclip)
- A structured workflow methodology (Compound Engineering)
- A research automation tool (pi-autoresearch)

Each of these exists as a separate CLI tool, MCP server, or GitHub project. Each requires config files, terminal commands, and developer knowledge to set up. Non-developers are locked out entirely.

**Senkani unifies all of this into one native app.** No terminal. No config files. No duct tape.

---

## The Vision

A native macOS app (with iPhone companion) where you:

1. Open a project tab
2. Spin up agent terminals in tiling panes
3. See live previews of what agents produce (markdown, HTML, browser)
4. Watch token savings happen automatically in real-time
5. Browse and manage skills across all your AI tools
6. Search your knowledge base semantically
7. Schedule agents to run on autopilot
8. Let agents self-improve through optimization loops
9. Monitor and control everything from your iPhone

**Tabs for projects. Panes for windows. Intelligence everywhere.**

```
+--------------------------------------------------------------+
|  [Project A]  [Project B]  [+]                         TABS  |
+--------+-----------------------------------------------------+
|        |  +---------------+ +---------------+                |
|  Side  |  |  Terminal     | |  Markdown     |      PANES    |
|  bar   |  |  (any agent)  | |  Preview      |                |
|        |  +---------------+ +---------------+                |
| Files  |  +---------------+ +---------------+                |
| Skills |  |  HTML         | |  Browser      |                |
| Search |  |  Preview      | |               |                |
| Agents |  +---------------+ +---------------+                |
+--------+-----------------------------------------------------+
|  閃 847K tokens saved (72%) | Next scheduled: 2h | 3 active  |
+--------------------------------------------------------------+
```

---

## Inspirations

Every major capability in Senkani is proven by an existing open-source project. We're not inventing — we're unifying.

### Terminal & Multiplexing
| Project | What we take | Link |
|---------|-------------|------|
| **Flock** | Tiling pane terminal multiplexer for Claude Code. Agent timelines, broadcast mode, session persistence. Swift + SwiftTerm + AppKit. | [divagation.github.io/flock](https://divagation.github.io/flock) |
| **SwiftTerm** | Native Swift terminal emulator library. PTY management, ANSI rendering, Apple Silicon native. | [github.com/migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) |

### Token Intelligence & Context Management
| Project | What we take | Link |
|---------|-------------|------|
| **RTK** | Command-aware output filtering (60-90% token reduction). 50+ built-in command handlers, declarative filter rules, analytics tracking. | [github.com/rtk-ai/rtk](https://github.com/rtk-ai/rtk) |
| **Wren** | 1.5B parameter compression model for Apple Silicon. Compresses verbose prompts/outputs while preserving task-critical info (line numbers, errors, negations). Runs as MCP server. | [github.com/Divagation/wren](https://github.com/Divagation/wren) |
| **context-mode** | MCP context virtualization layer. Sandboxes tool outputs, SQLite persistence with FTS indexing, BM25 retrieval. 98% reduction (315KB to 5.4KB). Sessions extend from 30min to 3hr. | [github.com/mksglu/context-mode](https://github.com/mksglu/context-mode) |
| **codemunch** | Token-efficient code exploration via symbol indexing. LSP/ctags/ripgrep fallback. Fetch one function instead of reading 800 lines (99.6% reduction). | [github.com/benmarte/codemunch](https://github.com/benmarte/codemunch) |

### Analytics & Observability
| Project | What we take | Link |
|---------|-------------|------|
| **Claudoscope** | macOS menu bar analytics for Claude Code. Session history, token/cost breakdown, secret detection, config linting. 100% local. | [claudoscope.com](https://claudoscope.com/) |

### Knowledge & Search
| Project | What we take | Link |
|---------|-------------|------|
| **Chops** | Skill discovery and management across AI tools (Claude Code, Cursor, Codex, etc.). Three-column browser, FSEvents monitoring, SwiftUI + SwiftData. | [github.com/Shpigford/chops](https://github.com/Shpigford/chops) |
| **qmd** | On-device search engine for knowledge bases. Hybrid BM25 + vector search with local LLM reranking. SQLite indexed, MCP integration. | [github.com/tobi/qmd](https://github.com/tobi/qmd) |

### Skills Ecosystem & Distribution
| Project | What we take | Link |
|---------|-------------|------|
| **skills.sh** | The "npm for AI agent skills." Open registry with 1,200+ skills in SKILL.md format. Works with 30+ agents. CLI install via `npx skills add`. Senkani integrates as a first-class skills.sh client — browse, install, and publish skills from the GUI. | [skills.sh](https://skills.sh/) |
| **gstack** | Garry Tan's 23+ specialist skills for Claude Code: CEO, Designer, Eng Manager, QA Lead, Security Officer, Release Engineer. Sequential workflow: Think -> Plan -> Build -> Review -> Test -> Ship -> Reflect. Shipped 600K+ lines in 60 days. SKILL.md format — directly installable. | [github.com/garrytan/gstack](https://github.com/garrytan/gstack) |

### Agent Orchestration & Coordination
| Project | What we take | Link |
|---------|-------------|------|
| **Ruflo** | Enterprise multi-agent orchestration. Q-Learning router assigns tasks to 100+ specialized agents. Swarm coordination (queen/worker hierarchies). Self-learning via 9 RL algorithms. Vector-based knowledge persistence (HNSW). Token compression (30-50% cost reduction). Concepts to adapt natively in Swift: intelligent routing, vector memory, consensus coordination. | [github.com/ruvnet/ruflo](https://github.com/ruvnet/ruflo) |
| **Paperclip** | Company OS for AI agents. Treats agents as employees in an org chart with roles, reporting lines, goals, and budgets. Heartbeat-based execution, atomic budget enforcement, immutable audit trails. Agent-agnostic (adapters for Claude, Codex, Gemini, Ollama, HTTP webhooks). Multi-tenant. Integration target — Senkani can talk to Paperclip's REST API for team orchestration. | [paperclip.ing](https://paperclip.ing/) |
| **Agency Agents** | 112+ specialized agent personas across 11 divisions (Engineering, Design, Marketing, Sales, QA, Spatial Computing, etc.). Structured markdown definitions with personality, deliverables, success metrics. Persona-driven execution — not generic prompts. Directly usable as SKILL.md-compatible agent definitions. | [github.com/msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents) |
| **Chief** | Autonomous task loop for large projects. Breaks work into discrete tasks (prd.json), runs agents in a loop with fresh context per iteration, one commit per task. The "Ralph Loop": read state -> select story -> prompt agent -> capture completion -> repeat. Resumable, zero-dependency. Concepts to adapt: task-based execution loops, PRD-driven project management, atomic commits per task. | [chiefloop.com](https://chiefloop.com/) |

### Workflow Methodology
| Project | What we take | Link |
|---------|-------------|------|
| **Compound Engineering** | The 80/20 inversion: 80% planning/review/knowledge capture, 20% execution. Six-command cycle: Ideate -> Brainstorm -> Plan -> Work -> Review -> Compound. 35+ specialized review agents (API contract, security, performance, architecture). Knowledge compounding — each cycle documents patterns that make the next cycle faster. Multi-platform (Claude Code, Cursor, 10+ others). | [github.com/EveryInc/compound-engineering-plugin](https://github.com/EveryInc/compound-engineering-plugin) |

### Learning & Automation
| Project | What we take | Link |
|---------|-------------|------|
| **Hermes Agent** | Self-improving agent with closed learning loop. Autonomous skill development, cross-session memory, dialectic user modeling. | [github.com/nousresearch/hermes-agent](https://github.com/nousresearch/hermes-agent) |
| **pi-autoresearch** | Autonomous optimization loops. Propose changes, benchmark, keep/discard automatically. Metric-driven self-improvement without human intervention. | [github.com/davebcn87/pi-autoresearch](https://github.com/davebcn87/pi-autoresearch) |

### Editor & UI
| Project | What we take | Link |
|---------|-------------|------|
| **CodeEdit** | Native macOS code editor. Project navigation, pane management, extension architecture. 100% Swift/SwiftUI. | [github.com/CodeEditApp/CodeEdit](https://github.com/CodeEditApp/CodeEdit) |

---

## Core Systems

### 1. Workspace (Tabs + Panes)

Every project gets a tab. Within each tab, a tiling pane grid holds any combination of:

| Pane Type | Source Inspiration | What It Does |
|-----------|-------------------|-------------|
| **Terminal** | Flock + SwiftTerm | PTY-based agent session. Runs any CLI agent (Claude Code, Codex, Gemini CLI, Ollama). Live agent timeline shows file reads/edits/commands. |
| **Markdown Preview** | CodeEdit | Live-renders .md files. Auto-refreshes via FSEvents when agent edits files. |
| **HTML Preview** | CodeEdit | Live-renders HTML/CSS/JS output. For static sites, generated pages. |
| **Browser** | WKWebView | Embedded web browser for docs, localhost previews, deployed sites. |
| **Analytics** | Claudoscope | Token savings dashboard, cost tracking, session history, per-command breakdown. |
| **Skills** | Chops | Three-column skill browser. Search, filter, edit skills across all AI tools. |
| **Search** | qmd | Semantic search across knowledge base, notes, docs, past conversations. |
| **Optimizer** | pi-autoresearch | Visual optimization loop dashboard. Set a metric, watch the agent iterate. |
| **Orchestrator** | Chief + Ruflo + Paperclip | Task board for project loops. Kanban view, agent assignment, progress timeline, budget tracking. |

Panes tile automatically (1 fills screen, 2 split, 4 make grid). Drag to resize. Keyboard shortcuts to navigate (Flock-style).

### 2. Token Intelligence Pipeline

The core differentiator. Every piece of output that flows between tools and LLMs passes through a multi-stage compression pipeline:

```
Raw Output (tool execution, file read, web fetch, etc.)
    |
    v
[Stage 1] RTK-style Command Filtering
    Smart per-command rules: strip ANSI, dedup lines,
    group similar output, head/tail truncation.
    50+ built-in command handlers.
    |
    v
[Stage 2] Wren Semantic Compression
    Local 1.5B model on Apple Silicon.
    Compresses verbose text while preserving:
    line numbers, error messages, negations, step ordering.
    50-80% reduction on top of Stage 1.
    |
    v
[Stage 3] context-mode Session Management
    SQLite + FTS5 indexed session state.
    Tool outputs sandboxed — only summaries enter context.
    BM25 retrieval on compaction — agent remembers everything.
    Sessions extend from 30min to 3hr.
    |
    v
[Stage 4] codemunch Symbol Extraction
    For code-related outputs: index symbols, fetch only
    what's needed. 99.6% reduction for code navigation.
    |
    v
Optimized Context --> LLM
```

**The terminal shows full, unfiltered output.** The user never loses information. Only the LLM context gets compressed.

**Visual feedback**: The status bar shows real-time savings. The analytics pane shows historical trends, per-command breakdowns, and cost projections.

### 3. Knowledge & Search

Unified search across everything the user has accumulated:

| Source | Indexed By | Search Method |
|--------|-----------|--------------|
| Markdown notes | qmd | BM25 + vector + rerank |
| Past conversations | context-mode | FTS5 full-text |
| Code symbols | codemunch | Symbol name/kind/file |
| Skills/prompts | Chops discovery | Keyword + tag filter |
| Agent memory | Hermes | Full-text + LLM summary |

All search is **local, on-device**. No cloud calls. SQLite + local embeddings (via node-llama-cpp or Core ML).

The sidebar has a unified search bar that queries all sources simultaneously and returns ranked results.

### 4. Skill Management & Ecosystem

From Chops + skills.sh + gstack + Agency Agents:

**Local Discovery** (Chops): Scans dotfile directories for:
- `~/.claude/commands/` and project `.claude/commands/`
- `~/.cursor/rules/`
- `~/.codex/`
- Other tool-specific locations

**Registry Integration** (skills.sh): First-class client for the skills.sh ecosystem:
- Browse 1,200+ community skills from the GUI
- One-click install into any supported agent
- Publish your own skills to the registry
- Skill popularity/ratings visible inline

**Curated Specialist Packs** (gstack + Agency Agents):
- Pre-bundled role-based skill packs: CEO, Designer, QA, Security, etc.
- 112+ agent personas available as installable profiles
- Each persona brings its own workflow, deliverables, and success metrics
- Not generic prompts — structured expertise with personality

**Browser**: Three-column layout:
- Left: Collections, filters, tool badges, registry search
- Center: Skill list (local + registry combined)
- Right: Markdown+YAML editor with live preview

**Sync**: FSEvents watches for external changes. If you edit a skill in the terminal, Senkani updates instantly.

### 5. Learning & Self-Improvement

From Hermes Agent + pi-autoresearch + Compound Engineering:

**Skill Development** (Hermes concept):
- After an agent completes a complex task successfully, Senkani can capture the approach as a reusable skill
- Skills improve over time as agents encounter variations
- Cross-session memory means agents get better at recurring tasks

**Knowledge Compounding** (Compound Engineering concept):
- Every completed cycle documents patterns, decisions, and solutions
- Structured workflow: Ideate -> Brainstorm -> Plan -> Work -> Review -> Compound
- The "Compound" phase explicitly captures what was learned — making the next cycle faster
- 80/20 inversion: invest in planning/review/capture, not just raw execution
- Multi-perspective review via specialized agents (security, performance, architecture, API)

**Optimization Loops** (Autoresearch concept):
- User sets: "Optimize [metric] by changing [files] using [benchmark command]"
- Agent loops autonomously: edit -> benchmark -> keep/revert -> repeat
- Visual dashboard shows improvement curve over time
- Works for: test speed, bundle size, build times, Lighthouse scores, anything measurable

**User Modeling** (Hermes concept):
- Track user preferences across sessions
- Agent adapts communication style, tool choices, and approach
- Non-invasive — user can view and edit what the system has learned

### 6. Agent Orchestration & Project Loops

From Ruflo + Paperclip + Chief:

**Task-Based Project Loops** (Chief concept):
- Define a project as a set of stories/tasks (PRD)
- Agent runs in a loop: pick next task -> execute with fresh context -> commit -> repeat
- One commit per task — clean, reviewable diffs
- Resumable: pause anytime, state lives on disk
- Visual progress: see which stories are done, in-progress, pending
- Set iteration limits to prevent runaways

**Intelligent Routing** (Ruflo concept):
- When multiple agents are available, route tasks to the best-fit agent
- Q-Learning inspired selection: learn which agent performs best for which task type
- Vector-based pattern memory: recall successful approaches from past sessions
- Specialized agent roles (from Agency Agents personas) matched to task requirements

**Team Orchestration** (Paperclip concept):
- For advanced users: organize agents into teams with roles and reporting lines
- Budget enforcement per agent (monthly spend caps with warnings)
- Heartbeat-based execution: agents wake on schedule, check task queue, work, sleep
- Integration with Paperclip's REST API for users who want full org-chart orchestration
- Audit trail: every tool call, decision, and conversation logged

**UI**: The Orchestrator pane shows:
- Task board (kanban-style: To Do / In Progress / Done)
- Agent assignment per task
- Progress timeline
- Budget/cost per agent
- One-click "run this project" to start the loop

### 7. Scheduling & Automation

For agents that should run on autopilot:

| Backend | When to Use |
|---------|------------|
| **launchd** | macOS native. Best for scheduled tasks that should survive reboots. |
| **cron** | Unix standard. Simple recurring schedules. |
| **In-app scheduler** | Senkani's own scheduler for agent-specific tasks. |

**Agent backends for scheduled runs**:
- **Claude API** (via subscription or API key) — cloud, most capable
- **Ollama** (local LLMs) — free, private, runs on Apple Silicon
- **Any OpenAI-compatible API** — flexibility

**Use cases**:
- "Every morning at 9am, check my repo for new issues and summarize them"
- "Every hour, run the test suite and notify me if anything breaks"
- "Weekly: optimize the build and create a PR with improvements"

**UI**: Schedule manager pane. Create/edit/delete schedules. View run history. Toggle on/off. iPhone companion shows schedule status and can trigger runs manually.

### 8. iPhone Companion

Both **monitoring** and **control**:

**Dashboard**:
- Active sessions with status indicators
- Token savings (today, this week, all-time)
- Scheduled task timeline
- Cost tracking

**Control**:
- Approve/deny destructive agent actions (push notifications)
- Send text input to active agent sessions
- Start/stop scheduled tasks
- Trigger ad-hoc agent runs

**Pairing**:
- **Local**: MultipeerConnectivity (same WiFi, zero config)
- **Remote**: CloudKit (iCloud-synced, works anywhere)
- **Handoff**: Start on Mac, continue on iPhone

---

## Technical Architecture

### Frameworks

| Component | Technology | Why |
|-----------|-----------|-----|
| UI (both platforms) | SwiftUI | Shared codebase, native feel |
| Terminal emulator | SwiftTerm (AppKit) | Proven, fast, Apple Silicon native |
| Browser panes | WKWebView | System WebKit, no bundle bloat |
| Markdown rendering | swift-markdown + WKWebView | Apple's own parser + rich render |
| Data persistence | SwiftData | Native, automatic CloudKit sync |
| File watching | FSEvents / DispatchSource | OS-level efficiency |
| Mac-iPhone sync | MultipeerConnectivity + CloudKit | Local + remote covered |
| Agent subprocess | Foundation.Process + PTY | Full terminal emulation |
| Notifications | UserNotifications + APNs | System-native push |
| Local LLM (Wren) | Core ML or llama.cpp | Apple Silicon optimized |
| Search embeddings | Core ML or node-llama-cpp | On-device vector generation |
| Search index | SQLite + FTS5 | Proven, fast, zero-dep |
| Symbol indexing | Tree-sitter or ctags | Language-aware code parsing |

### Project Layout

```
Senkani/
+-- Shared/                          # Mac + iPhone shared code
|   +-- Models/
|   |   +-- Project.swift            # Project = tab
|   |   +-- AgentSession.swift       # Session state, history, config
|   |   +-- TokenStats.swift         # Analytics data model
|   |   +-- Skill.swift              # Skill file model (Chops)
|   |   +-- Schedule.swift           # Scheduled task model
|   |   +-- SearchResult.swift       # Unified search result
|   |   +-- OptimizationRun.swift    # Autoresearch run state
|   +-- TokenFilter/                 # RTK-style filtering engine
|   |   +-- FilterEngine.swift       # Ordered pipeline: apply rules to output
|   |   +-- FilterRule.swift         # Rule + operation definitions
|   |   +-- BuiltinRules.swift       # 50+ command handlers
|   |   +-- ANSIStripper.swift       # ANSI escape removal
|   |   +-- LineOperations.swift     # Head/tail/dedup/group/strip
|   |   +-- CommandMatcher.swift     # Command recognition + subcommand detection
|   +-- Compression/                 # Wren-style semantic compression
|   |   +-- WrenEngine.swift         # Core ML model wrapper
|   |   +-- CompressionPipeline.swift # Multi-stage: filter -> compress -> index
|   +-- ContextManager/             # context-mode session management
|   |   +-- SessionStore.swift       # SQLite + FTS5 session persistence
|   |   +-- ContextSandbox.swift     # Tool output sandboxing
|   |   +-- BM25Retrieval.swift      # Smart retrieval on compaction
|   +-- CodeIndex/                   # codemunch-style symbol indexing
|   |   +-- SymbolIndex.swift        # Build/query symbol index
|   |   +-- SymbolExtractor.swift    # Tree-sitter / ctags extraction
|   |   +-- IncrementalUpdate.swift  # Git blob hash change detection
|   +-- Search/                      # qmd-style unified search
|   |   +-- SearchEngine.swift       # Hybrid BM25 + vector
|   |   +-- EmbeddingProvider.swift  # Local embedding generation
|   |   +-- Reranker.swift           # Local LLM reranking
|   +-- Skills/                      # Chops + skills.sh + gstack + Agency Agents
|   |   +-- SkillDiscovery.swift     # Scan dotfiles across AI tools
|   |   +-- SkillStore.swift         # SwiftData persistence
|   |   +-- RegistryClient.swift     # skills.sh API client: browse, install, publish
|   |   +-- SpecialistPacks.swift    # Bundled role packs (gstack, Agency Agents)
|   +-- Learning/                    # Hermes + Compound Engineering
|   |   +-- SkillCapture.swift       # Auto-generate skills from successful tasks
|   |   +-- UserModel.swift          # Preference tracking across sessions
|   |   +-- CompoundCycle.swift      # Ideate->Brainstorm->Plan->Work->Review->Compound
|   |   +-- KnowledgeStore.swift     # Documented patterns from completed cycles
|   +-- Orchestration/              # Chief + Ruflo + Paperclip concepts
|   |   +-- TaskBoard.swift          # PRD-based task management (kanban)
|   |   +-- ProjectLoop.swift        # Chief-style: pick task -> agent -> commit -> repeat
|   |   +-- AgentRouter.swift        # Intelligent routing: match task to best agent
|   |   +-- TeamManager.swift        # Org-chart style agent teams (Paperclip concept)
|   |   +-- PaperclipClient.swift    # Optional REST API integration with Paperclip
|   +-- Automation/                  # Scheduling + autoresearch
|   |   +-- ScheduleManager.swift    # launchd / cron / in-app scheduler
|   |   +-- OptimizationLoop.swift   # Autoresearch: edit->benchmark->keep/revert
|   +-- Sync/
|   |   +-- PeerManager.swift        # MultipeerConnectivity
|   |   +-- CloudSync.swift          # CloudKit
|   +-- Services/
|       +-- FileWatcher.swift        # FSEvents wrapper
|       +-- Analytics.swift          # Token savings + cost tracking
|       +-- SecretDetector.swift     # Claudoscope-style credential scanning
+-- Mac/
|   +-- SenkaniApp.swift             # Mac entry point
|   +-- Views/
|   |   +-- WorkspaceView.swift      # Main window: tab bar + pane grid
|   |   +-- PaneGrid.swift           # Tiling layout manager
|   |   +-- TerminalPane.swift       # SwiftTerm wrapper + agent timeline
|   |   +-- MarkdownPane.swift       # Live markdown preview
|   |   +-- HTMLPane.swift           # Live HTML preview
|   |   +-- BrowserPane.swift        # WKWebView wrapper
|   |   +-- SidebarView.swift        # Files / skills / search / agents
|   |   +-- SkillBrowser.swift       # Three-column Chops-style
|   |   +-- AnalyticsPane.swift      # Claudoscope-style dashboard
|   |   +-- SearchPane.swift         # Unified search UI
|   |   +-- OptimizerPane.swift      # Autoresearch dashboard
|   |   +-- OrchestratorPane.swift   # Task board / project loop / agent routing
|   |   +-- SchedulePane.swift       # Schedule manager UI
|   |   +-- AgentTimeline.swift      # Live agent activity feed
|   |   +-- FilterRuleEditor.swift   # GUI filter rule config
|   +-- Terminal/
|       +-- PTYManager.swift         # Pseudo-terminal lifecycle
|       +-- OutputInterceptor.swift  # Split: full->terminal, filtered->LLM
+-- iPhone/
|   +-- SenkaniCompanionApp.swift    # iPhone entry point
|   +-- Views/
|       +-- DashboardView.swift      # Savings + sessions + schedules
|       +-- SessionListView.swift    # Active sessions with status
|       +-- ApprovalView.swift       # Approve/deny + text input
|       +-- ScheduleView.swift       # View/trigger scheduled tasks
|       +-- NotificationHandler.swift
+-- Package.swift                    # SPM dependencies
```

---

## Implementation Phases

### Phase 1: Foundation (Week 1-3)
**Goal**: A working app that runs an agent in a terminal with basic token filtering.

- Xcode project with Mac + iPhone targets
- `WorkspaceView` with project tab bar
- `PaneGrid` with single terminal pane
- `PTYManager` + SwiftTerm integration — run any CLI agent as PTY subprocess
- `OutputInterceptor` — split output (full to terminal, filtered for LLM tracking)
- `FilterEngine` with `ANSIStripper` + 10 built-in command rules (git, npm, cargo, docker, pip, make, go, kubectl, pytest, brew)
- Token counter in status bar
- **Verify**: Open project, run `claude` or `ollama`, see terminal output + token savings counter

### Phase 2: Multi-Pane Workspace (Week 4-5)
**Goal**: Full pane system with live previews.

- `PaneGrid` tiling: add/remove/resize, auto-layout (1/2/4 pane arrangements)
- `MarkdownPane` with swift-markdown + FSEvents auto-refresh
- `HTMLPane` with WKWebView + FSEvents auto-refresh
- `BrowserPane` (general WKWebView)
- Pane type picker (+ button)
- Multiple terminal panes per project (Flock-style grid)
- Broadcast mode: type once, all terminals receive
- **Verify**: 4-pane grid with terminal + markdown + HTML + browser. Agent edits a .md file, preview updates live.

### Phase 3: Knowledge Layer (Week 6-8)
**Goal**: Unified search and skill management.

- `SidebarView` with file tree, skill browser, search, agent list
- `SkillDiscovery` scans dotfiles (Claude Code, Cursor, Codex, Windsurf, Amp)
- `SkillBrowser` three-column layout with search/filter/edit
- `SearchEngine` with SQLite FTS5 for full-text search
- `EmbeddingProvider` using Core ML for vector search
- Unified search bar in sidebar querying skills + notes + code + conversations
- **Verify**: Install Claude Code skills, open skill browser, search finds them. Search knowledge base returns ranked results.

### Phase 4: Deep Token Intelligence (Week 9-11)
**Goal**: Full compression pipeline + analytics.

- Complete `BuiltinRules` (50+ commands, matching RTK's coverage)
- `WrenEngine` — integrate compression model via Core ML
- `CompressionPipeline` — multi-stage: filter -> compress -> index
- `SessionStore` + `ContextSandbox` (context-mode concepts)
- `BM25Retrieval` for smart context recovery on compaction
- `SymbolIndex` + `SymbolExtractor` (codemunch concepts)
- `AnalyticsPane` — full Claudoscope-style dashboard: sessions, costs, savings, trends
- `SecretDetector` — scan for leaked credentials
- `FilterRuleEditor` — GUI for custom filter rules
- **Verify**: Run `git clone` + `npm install` in terminal, see multi-stage compression in analytics. Session survives context compaction with memory intact.

### Phase 5: Automation & Learning (Week 12-14)
**Goal**: Scheduling, optimization loops, skill learning.

- `ScheduleManager` — create schedules via GUI, backed by launchd
- Support for Claude API, Ollama, any OpenAI-compatible backend
- `SchedulePane` — visual schedule manager with run history
- `OptimizationLoop` — autoresearch: set metric + files + benchmark, agent iterates
- `OptimizerPane` — visual improvement curve
- `SkillCapture` — after successful complex tasks, offer to save as reusable skill
- `UserModel` — track preferences across sessions
- **Verify**: Schedule "run tests every hour". Set up optimization loop for build time. See agent iterate and improve metric.

### Phase 6: iPhone + Polish (Week 15-17)
**Goal**: iPhone companion + production readiness.

- `DashboardView` — savings, sessions, schedules at a glance
- `ApprovalView` — approve/deny actions with push notifications
- `ScheduleView` — view and trigger schedules
- Text input to active sessions
- `PeerManager` for local pairing
- `CloudSync` for remote access
- Session persistence across app restarts
- Agent timeline visualization
- App icon (閃蟹)
- App Store preparation
- **Verify**: Pair iPhone, run agent on Mac, approve action from iPhone, see savings on both devices.

---

## What This Replaces

| Before (duct tape) | After (Senkani) |
|---------------------|-----------------|
| tmux/screen for multiple terminals | Tiling pane grid with agent timelines |
| RTK CLI for token filtering | Built-in multi-stage compression pipeline |
| Claudoscope menu bar for analytics | Integrated analytics pane + iPhone dashboard |
| Chops app for skill management | Built-in skill browser in sidebar |
| context-mode MCP server for session mgmt | Native session persistence + smart retrieval |
| codemunch plugin for code navigation | Built-in symbol indexing |
| qmd CLI for knowledge search | Unified search bar across all sources |
| cron/launchd manual config for scheduling | Visual schedule manager |
| pi-autoresearch skill for optimization | Visual optimization loop dashboard |
| Hermes concepts for learning | Automatic skill capture + user modeling |
| Chief CLI for project task loops | Visual orchestrator pane with kanban board |
| Ruflo swarm setup for multi-agent routing | Built-in intelligent agent routing |
| Paperclip server for agent team management | Native team orchestration (or Paperclip API integration) |
| Browsing skills.sh in a browser | Built-in registry client in skill browser |
| Installing gstack skills manually | Pre-bundled specialist packs, one-click install |
| Compound Engineering CLI workflow | Built-in Ideate->Plan->Work->Review->Compound cycle |
| Separate iPhone monitoring app | Built-in companion app |

**One app. Everything connected. No config files.**

---

## Integration Strategy

Not everything should be reimplemented natively. The right approach for each inspiration:

| Project | Strategy | Rationale |
|---------|----------|-----------|
| **Flock / SwiftTerm** | Reimplement natively | Core UI — must be native Swift |
| **RTK** | Reimplement natively | Filter engine is core differentiator, simple string ops |
| **Wren** | Integrate (Core ML) | Run the model locally, don't rewrite it |
| **context-mode** | Reimplement natively | SQLite + FTS5 is straightforward in Swift |
| **codemunch** | Reimplement natively | Tree-sitter/ctags wrapping is feasible |
| **Claudoscope** | Reimplement natively | Analytics UI is core to the app |
| **Chops** | Reimplement natively | Skill browser is core UI |
| **skills.sh** | Integrate (API client) | It's a shared ecosystem — consume it, don't replace it |
| **gstack** | Integrate (install SKILL.md files) | Pre-bundle the skills, they're SKILL.md format |
| **Agency Agents** | Integrate (install persona files) | Pre-bundle as persona packs |
| **qmd** | Reimplement natively | Search engine should be embedded, not external |
| **Hermes Agent** | Adapt concepts | Learning loop + user modeling in Swift |
| **pi-autoresearch** | Adapt concepts | Optimization loop logic in Swift |
| **Ruflo** | Adapt concepts | Intelligent routing, not full swarm infra |
| **Paperclip** | Integrate (REST API client) | For team orchestration, talk to Paperclip server |
| **Chief** | Adapt concepts | Task loop runner natively in Swift |
| **Compound Engineering** | Adapt concepts | Workflow methodology as built-in cycle |
| **CodeEdit** | Reference patterns | UI patterns for project nav and pane management |

---

## Open Questions

1. **Licensing**: Several inspirations have different licenses (MIT, CC BY-NC, Apache). Senkani should be its own clean implementation inspired by concepts, not copying code.

2. **Wren model size**: 1.5B parameters may be large for bundling. Consider: download on first use, or use a smaller distilled model for v1.

3. **MCP integration**: Should Senkani expose its own MCP server so external tools can use its compression/search? Or stay self-contained for v1?

4. **Agent protocol**: Flock intercepts Claude Code specifically. For "any CLI agent" support, we need a generic PTY interception approach — which means token filtering works on raw terminal output rather than structured tool calls. This is the RTK approach and works well.

5. **App Store sandbox**: Some features (FSEvents on dotfiles, launchd management, PTY spawning) may conflict with App Store sandboxing. May need to distribute outside App Store initially, or use a non-sandboxed helper.

6. **Paperclip dependency**: Should Paperclip integration be optional (for power users who run their own Paperclip server) or should we reimplement team orchestration natively? Recommendation: optional integration for v1, native later.

7. **skills.sh API stability**: skills.sh is new (launched 2025). Need to assess API stability before building a deep integration. Fallback: direct GitHub-based skill installation.

8. **Compound Engineering scope**: The full 6-command cycle + 35 review agents is ambitious. Start with a simplified version (Plan -> Work -> Review -> Compound) and expand.
