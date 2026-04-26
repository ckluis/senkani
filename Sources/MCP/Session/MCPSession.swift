import Foundation
import Core
import Filter
import Indexer

/// Shared session state for the MCP server.
/// Holds read cache, symbol index, feature config, and running metrics.
///
/// In socket-server (daemon) mode, ``MCPSession/shared`` is the process-global
/// singleton so all connections share one cache, index, and metrics store.
///
/// TODO: Phase 5 — For socket server, this session must be shareable across
/// multiple client connections. Key changes needed:
/// - Per-connection metrics vs. aggregate metrics (add connection ID tracking)
/// - ReadCache is already thread-safe (NSLock), but consider per-connection
///   cache partitioning for isolation if connections serve different projects
/// - The `projectRoot` is currently fixed at init — for multi-project socket
///   server, either create one MCPSession per project root or make it dynamic
/// - Feature toggles (filterEnabled etc.) are session-wide — decide whether
///   per-connection overrides are needed
final class MCPSession: @unchecked Sendable {
    /// Process-global shared session for daemon / socket-server mode.
    /// Lazily initialized on first access.
    // TODO: Phase 5 — Consider a session registry (keyed by project root)
    // instead of a single global singleton for multi-project socket server.
    static let shared: MCPSession = MCPSession.resolve()

    let projectRoot: String
    let readCache: ReadCache
    let pipeline: FilterPipeline
    let validatorRegistry: ValidatorRegistry
    let knowledgeStore: KnowledgeStore
    let entityTracker: EntityTracker
    let knowledgeLayer: KnowledgeFileLayer?
    let metricsFilePath: String?
    let sessionId: String?
    let paneId: String?
    let agentType: AgentType
    private let lock = NSLock()

    /// P2-10: one-warning-per-session tracking for deprecated argument names.
    /// Guarded by `lock`. Keys are stable shim-provided identifiers like
    /// "knowledge.detail". First sight returns true; subsequent sightings return false.
    private var emittedDeprecations: Set<String> = []

    /// Record a deprecation fire for this session. Returns true the FIRST time
    /// `key` is observed per session, false thereafter — so the router can append
    /// a single warning block to the tool result without spamming every call.
    func noteDeprecation(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return emittedDeprecations.insert(key).inserted
    }

    // Feature toggles (mutable at runtime — refreshed from config file on each tool call)
    private(set) var filterEnabled: Bool
    private(set) var secretsEnabled: Bool
    private(set) var indexerEnabled: Bool
    private(set) var cacheEnabled: Bool
    private(set) var terseEnabled: Bool
    private(set) var injectionGuardEnabled: Bool
    private let configFilePath: String?

    // Tree cache for incremental re-parsing
    let treeCache = TreeCache()

    // Symbol index (eagerly warmed in background)
    private var _symbolIndex: SymbolIndex?
    private var _indexBuilding = false

    // FSEvents file watcher for auto re-indexing
    private var fileWatcher: FileWatcher?

    // Cached repo map for MCP instruction injection (invalidated on index change)
    private var _repoMap: String?

    // Cached session continuity brief (generated once per session)
    private var _sessionBrief: String?

    // Phase S.1 — resolved manifest effective-set (lazy; guarded by `lock`).
    // Resolves team manifest + user overrides on first read; cached for the
    // session. Absence of `.senkani/senkani.json` yields an
    // `EffectiveSet` with `manifestPresent: false`, which signals backwards-
    // compat (all tools enabled) to ToolRouter.
    private var _effectiveSet: EffectiveSet?
    var effectiveSet: EffectiveSet {
        lock.lock(); defer { lock.unlock() }
        if let cached = _effectiveSet { return cached }
        let set = ManifestLoader.load(projectRoot: projectRoot)
        _effectiveSet = set
        return set
    }

    // Dependency graph (lazily built on first use)
    private var _dependencyGraph: DependencyGraph?

    // Symbol staleness tracking
    private var queriedSymbols: Set<String> = []
    private var staleNotices: [String] = []

    // Pinned context: @-mention entries prepended to subsequent tool results
    let pinnedContextStore = PinnedContextStore()
    private(set) var autoPinEnabled: Bool = false

    // Lazy-cached skills prompt (WARP.md injection). Populated on first call to skillsPrompt().
    private var _skillsContent: String?
    private var _loadedSkillNames: [String]?

    // Per-pane budget cap (in cents). Nil = no pane-level cap.
    // Read from SENKANI_PANE_BUDGET_SESSION in the per-pane config file via refreshConfig().
    // Settable at runtime via updateConfig(budgetSessionCents:).
    private(set) var paneBudgetSessionLimitCents: Int? = nil
    // Last IPC status sent to GUI — deduplicates fire-and-forget IPC pushes.
    private var lastBudgetIPCStatus: String = "none"

    // Running metrics
    private(set) var totalRawBytes = 0
    private(set) var totalCompressedBytes = 0
    private(set) var totalCacheSavedBytes = 0
    private(set) var toolCallCount = 0
    private(set) var perFeatureSaved: [String: Int] = [:]  // feature name -> bytes saved

    init(projectRoot: String, filterEnabled: Bool = true, secretsEnabled: Bool = true,
         indexerEnabled: Bool = true, cacheEnabled: Bool = true, terseEnabled: Bool = false,
         injectionGuardEnabled: Bool = false,
         readCache: ReadCache? = nil,
         metricsFilePath: String? = nil, sessionId: String? = nil, paneId: String? = nil,
         configFilePath: String? = nil, agentType: AgentType = .unknownMCP) {
        self.projectRoot = projectRoot
        self.filterEnabled = filterEnabled
        self.secretsEnabled = secretsEnabled
        self.indexerEnabled = indexerEnabled
        self.cacheEnabled = cacheEnabled
        self.terseEnabled = terseEnabled
        self.injectionGuardEnabled = injectionGuardEnabled
        self.readCache = readCache ?? ReadCache()
        self.metricsFilePath = metricsFilePath
        self.sessionId = sessionId
        self.paneId = paneId
        self.agentType = agentType
        self.configFilePath = configFilePath

        let config = FeatureConfig(filter: filterEnabled, secrets: secretsEnabled, indexer: indexerEnabled, terse: terseEnabled)
        self.pipeline = FilterPipeline(config: config)
        self.validatorRegistry = ValidatorRegistry.load(projectRoot: projectRoot)
        let ks = KnowledgeStore(projectRoot: projectRoot)
        self.knowledgeStore = ks
        self.entityTracker = EntityTracker(store: ks)
        self.knowledgeLayer = try? KnowledgeFileLayer(projectRoot: projectRoot, store: ks)

        // Start background index warmup so first tool call doesn't block
        if indexerEnabled {
            warmIndex()
        }
        // Pre-cache hot files from prior sessions (non-blocking)
        preCacheHotFiles()
        // Pre-warm WebFetchEngine: spawns WebKit XPC subprocess once AND compiles
        // the F2 subresource blocklist (~50 ms one-time) before the first
        // senkani_web call so the engine is ready with full SSRF defense.
        Task {
            await WebFetchEngine.shared.warmUp()
        }
        // Mine co-change coupling in background (idempotent; no-op if not a git repo)
        let _pr = projectRoot
        let _ks = knowledgeStore
        Task.detached(priority: .background) {
            ChangeSetMiner.mine(projectRoot: _pr, store: _ks)
        }
    }

    /// Defensive teardown for callers that don't drive the full `shutdown()`
    /// path (notably tests, which construct ad-hoc sessions). Without this,
    /// a session's `FileWatcher` could outlive its owner and the FSEvents
    /// dispatch queue could fire a callback into a half-deinitialized
    /// instance — observed in soak as
    /// "Object … of class FileWatcher deallocated with non-zero retain
    /// count 2" followed by SIGSEGV at process teardown. `stopFileWatcher`
    /// is idempotent and synchronously drains any in-flight callback.
    deinit {
        stopFileWatcher()
    }

    /// Resolve session config from environment.
    static func resolve() -> MCPSession {
        let rawRoot = ProcessInfo.processInfo.environment["SENKANI_PROJECT_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        // Normalize path for consistent DB storage/querying
        let root = URL(fileURLWithPath: rawRoot).standardized.path
        let mode = ProcessInfo.processInfo.environment["SENKANI_MODE"]?.lowercased()
        let passthrough = mode == "passthrough"

        func envBool(_ key: String, fallback: Bool) -> Bool {
            guard let val = ProcessInfo.processInfo.environment[key]?.lowercased() else { return fallback }
            switch val {
            case "true", "on", "1", "yes": return true
            case "false", "off", "0", "no": return false
            default: return fallback
            }
        }

        // Metrics file: explicit env var > fallback derived from project root.
        // The fallback ensures metrics are always recorded even when Claude Code
        // doesn't pass SENKANI_METRICS_FILE through to the MCP subprocess.
        let explicitMetrics = ProcessInfo.processInfo.environment["SENKANI_METRICS_FILE"]
        let metricsFile = explicitMetrics ?? Self.fallbackMetricsPath(projectRoot: root)
        // Prune expired sandboxed results (>24h) on session startup
        SessionDatabase.shared.pruneSandboxedResults()
        // Prune token_events older than 90 days to prevent unbounded table growth
        SessionDatabase.shared.pruneTokenEvents()
        // Phase H+1 daily cadence sweep — promote `.recurring` rules with
        // sufficient evidence to `.staged` so they're visible to the
        // operator on the next `senkani learn status`. Lazy on session
        // start (no timers, no launchd plist). Bounded to `.recurring`
        // rules only — zero work when none exist.
        //
        // H+2a adds Gemma 4 rationale enrichment via the `GemmaInferenceAdapter`
        // — any rule promoted this sweep gets a detached Task that asks
        // the VLM to rewrite its deterministic rationale. Adapter returns
        // nil when no Gemma model is downloaded, so enrichment is best-
        // effort and never blocks the sweep.
        let enricher = GemmaRationaleRewriter(llm: GemmaInferenceAdapter())
        let promoted = CompoundLearning.runDailySweep(
            db: .shared, projectRoot: root, enricher: enricher)
        if promoted > 0 {
            Logger.log("compound_learning.daily_sweep", fields: [
                "promoted": .int(promoted),
                "outcome": .string("staged")
            ])
        }

        let agentType = AgentDetector.detect(environment: ProcessInfo.processInfo.environment)
        let sessionId: String? = SessionDatabase.shared.createSession(projectRoot: root, agentType: agentType)
        let paneId = ProcessInfo.processInfo.environment["SENKANI_PANE_ID"]

        Logger.log("mcp.session.resolved", fields: [
            "project_root": .path(root),
            "metrics_file": .path(metricsFile),
            "has_pane_id": .bool(paneId != nil),
            "has_session_id": .bool(sessionId != nil),
        ])

        let configFile = ProcessInfo.processInfo.environment["SENKANI_CONFIG_FILE"]

        return MCPSession(
            projectRoot: root,
            filterEnabled: passthrough ? false : envBool("SENKANI_MCP_FILTER", fallback: true),
            secretsEnabled: passthrough ? false : envBool("SENKANI_MCP_SECRETS", fallback: true),
            indexerEnabled: passthrough ? false : envBool("SENKANI_MCP_INDEX", fallback: true),
            cacheEnabled: passthrough ? false : envBool("SENKANI_MCP_CACHE", fallback: true),
            terseEnabled: passthrough ? false : envBool("SENKANI_MCP_TERSE", fallback: false),
            injectionGuardEnabled: passthrough ? false : envBool("SENKANI_MCP_INJECTION_GUARD", fallback: true),
            metricsFilePath: metricsFile,
            sessionId: sessionId,
            paneId: paneId,
            configFilePath: configFile,
            agentType: agentType
        )
    }

    /// Derive a deterministic metrics file path from the project root.
    /// Uses the last two path components for a readable, collision-resistant name.
    private static func fallbackMetricsPath(projectRoot: String) -> String {
        let components = projectRoot.split(separator: "/")
        let name = components.suffix(2).joined(separator: "-")
        let dir = NSHomeDirectory() + "/.senkani/metrics"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/" + name + ".jsonl"
    }

    /// Re-read feature toggles from the pane's config file.
    /// Called at the start of each tool call so GUI toggle changes take effect immediately.
    /// Cost: one file stat per tool call — negligible.
    func refreshConfig() {
        guard let path = configFilePath else { return }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        // Parse KEY=VALUE lines from the .env file
        var env: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                env[String(parts[0])] = String(parts[1])
            }
        }

        lock.lock()
        // Map pane env var names (SENKANI_FILTER) to session properties
        if let val = env["SENKANI_FILTER"] { filterEnabled = val == "on" }
        if let val = env["SENKANI_CACHE"] { cacheEnabled = val == "on" }
        if let val = env["SENKANI_SECRETS"] { secretsEnabled = val == "on" }
        if let val = env["SENKANI_INDEXER"] { indexerEnabled = val == "on" }
        if let val = env["SENKANI_TERSE"] { terseEnabled = val == "on" }
        // Per-pane budget cap — use SENKANI_PANE_BUDGET_SESSION to avoid collision
        // with the global SENKANI_BUDGET_SESSION env var read by BudgetConfig.
        if let val = env["SENKANI_PANE_BUDGET_SESSION"] {
            paneBudgetSessionLimitCents = Int(val)
        }
        lock.unlock()
    }

    /// Kick off background index build. Non-blocking.
    /// If an index exists on disk, loads it immediately (fast), then refreshes in background.
    /// If no index exists, does a full build in background.
    func warmIndex() {
        lock.lock()
        guard _symbolIndex == nil, !_indexBuilding else {
            lock.unlock()
            return
        }
        // Try fast disk load first (synchronous, <50ms)
        if let cached = IndexStore.load(projectRoot: projectRoot) {
            _symbolIndex = cached
            _repoMap = nil
            _indexBuilding = true
            lock.unlock()
            // Incremental update in background (populate tree cache for incremental re-parsing)
            DispatchQueue.global(qos: .utility).async { [projectRoot, treeCache] in
                let updated = IndexEngine.incrementalUpdate(existing: cached, projectRoot: projectRoot, treeCache: treeCache)
                try? IndexStore.save(updated, projectRoot: projectRoot)
                self.lock.lock()
                self._symbolIndex = updated
                self._repoMap = nil
                self._indexBuilding = false
                self.lock.unlock()
                self.startFileWatcher()
            }
        } else {
            _indexBuilding = true
            lock.unlock()
            // Full build in background (populate tree cache for incremental re-parsing)
            DispatchQueue.global(qos: .utility).async { [projectRoot, treeCache] in
                let idx = IndexEngine.index(projectRoot: projectRoot, treeCache: treeCache)
                try? IndexStore.save(idx, projectRoot: projectRoot)
                self.lock.lock()
                self._symbolIndex = idx
                self._repoMap = nil
                self._indexBuilding = false
                self.lock.unlock()
                self.startFileWatcher()
            }
        }
    }

    /// Return the index if available, nil if still building. Thread-safe.
    func indexIfReady() -> SymbolIndex? {
        lock.lock()
        defer { lock.unlock() }
        return _symbolIndex
    }

    /// Get the repo map for MCP instruction injection.
    /// Generated from the symbol index, cached until the index changes.
    /// Returns empty string if the index isn't ready yet.
    /// Tightened default (200 tokens ≈ 800 bytes) vs. previous 2000 tokens so the
    /// per-server-start instruction tax stays bounded; large repos overflow upstream
    /// in `instructionsPayload(budgetBytes:)` which truncates with a hint to call
    /// `senkani_explore` for the rest.
    func repoMap(maxTokens: Int = 200) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = _repoMap, maxTokens == 200 { return cached }
        guard let index = _symbolIndex else { return "" }
        let map = index.repoMap(maxTokens: maxTokens)
        if maxTokens == 200 { _repoMap = map }
        return map
    }

    /// Assemble the instructions payload injected into the MCP `Server(instructions:)`.
    /// Capped at `budgetBytes` across all three sections (sessionBrief > repoMap > skills,
    /// in priority order). The old path concatenated unbounded strings and taxed every
    /// MCP server start with ~8 KB on large repos. Override with
    /// `SENKANI_INSTRUCTIONS_BUDGET_BYTES`.
    func instructionsPayload(base: String, budgetBytes: Int? = nil) -> String {
        let envBudget = ProcessInfo.processInfo.environment["SENKANI_INSTRUCTIONS_BUDGET_BYTES"]
            .flatMap { Int($0) }
        let budget = budgetBytes ?? envBudget ?? 2048

        let briefBudget     = min(700, budget / 3)
        let paneDiaryBudget = min(800, budget / 3)
        let skillsBudget    = min(400, budget / 5)
        let repoBudget      = max(0, budget - briefBudget - paneDiaryBudget - skillsBudget)

        let brief = MCPSession.truncate(
            sessionBrief(),
            to: briefBudget,
            marker: "\n[session context truncated]"
        )

        let repoMapText: String = {
            guard repoBudget > 0 else { return "" }
            let raw = repoMap(maxTokens: max(50, repoBudget / 4))
            let capped = MCPSession.truncate(
                raw, to: repoBudget,
                marker: "\n... (repo map truncated — call senkani_explore for full tree)"
            )
            return capped.isEmpty ? "" : "\n\nProject structure:\n" + capped
        }()

        // Round-3 pane diary injection. Reads SENKANI_WORKSPACE_SLUG +
        // SENKANI_PANE_SLUG from the process env and loads the prior
        // diary from `~/.senkani/diaries/<ws>/<pane>.md`. Empty when
        // either env var is missing, the env gate is off, or no diary
        // exists yet. `PaneDiaryInjection` swallows read failures so a
        // bad diary can't block MCP server start.
        let paneDiary = MCPSession.truncate(
            PaneDiaryInjection.instructionsSection(),
            to: paneDiaryBudget,
            marker: "\n[pane diary truncated]"
        )

        let skills = MCPSession.truncate(
            skillsPrompt(),
            to: skillsBudget,
            marker: "\n[skills truncated — call senkani_knowledge for details]"
        )

        return base + repoMapText + brief + paneDiary + skills
    }

    /// Truncate `text` to fit in `maxBytes` of UTF-8, appending `marker` when cut.
    /// Returns the empty string (not the marker) for empty input.
    static func truncate(_ text: String, to maxBytes: Int, marker: String) -> String {
        if text.isEmpty { return "" }
        if text.utf8.count <= maxBytes { return text }
        // Byte-safe truncation: find a valid scalar boundary at or below maxBytes.
        let slice = text.utf8.prefix(max(0, maxBytes - marker.utf8.count))
        guard let headStr = String(slice) else {
            // Rare: the prefix sliced mid-scalar. Fall back to character-wise cut.
            var out = ""
            for ch in text {
                if out.utf8.count + ch.utf8.count + marker.utf8.count > maxBytes { break }
                out.append(ch)
            }
            return out + marker
        }
        return headStr + marker
    }

    /// Generate the session continuity brief. Cached after first call.
    /// Returns empty string if continuity is disabled or no prior session exists.
    func sessionBrief() -> String {
        lock.lock()
        if let cached = _sessionBrief {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Check feature toggle (default: on)
        guard Self.continuityEnabled() else {
            lock.lock()
            _sessionBrief = ""
            lock.unlock()
            return ""
        }

        let lastActivity = SessionDatabase.shared.lastSessionActivity(projectRoot: projectRoot)

        let changedFiles: [String]
        if let activity = lastActivity {
            changedFiles = SessionBriefGenerator.filesChangedSince(
                files: activity.topHotFiles,
                since: activity.endedAt,
                projectRoot: projectRoot
            )
        } else {
            changedFiles = []
        }

        // H+2b: pull applied context docs (most-recent-first) into the
        // brief's optional "Learned:" section. Docs contribute terse
        // one-liners; full bodies live on disk at .senkani/context/.
        let appliedDocs = Array(LearnedRulesStore.appliedContextDocs().prefix(5))
        let brief = SessionBriefGenerator.generate(
            lastActivity: lastActivity,
            changedFilesSinceLastSession: changedFiles,
            appliedContextDocs: appliedDocs
        )
        let section = brief.isEmpty ? "" : "\n\nSession context:\n" + brief

        lock.lock()
        _sessionBrief = section
        lock.unlock()
        return section
    }

    private static func continuityEnabled() -> Bool {
        let val = ProcessInfo.processInfo.environment["SENKANI_CONTINUITY"]?.lowercased()
        switch val {
        case "false", "off", "0", "no": return false
        default: return true  // on by default
        }
    }

    /// Build the WARP.md skills section for injection into MCP instructions. Cached after first call.
    /// Returns empty string when SENKANI_SKILLS=off or no skill files are found.
    func skillsPrompt() -> String {
        let skillsEnv = ProcessInfo.processInfo.environment["SENKANI_SKILLS"]?.lowercased()
        guard skillsEnv != "off" else { return "" }

        lock.lock()
        if let cached = _skillsContent {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let prompt = SkillScanner.buildSkillsPrompt(projectRoot: projectRoot)
        let names: [String]
        if prompt.isEmpty {
            names = []
        } else {
            names = SkillScanner.scanSenkaniSkills(projectRoot: projectRoot).map(\.name)
        }

        lock.lock()
        _skillsContent = prompt
        _loadedSkillNames = names
        lock.unlock()

        if names.isEmpty {
            FileHandle.standardError.write(Data("[MCP] WARP skills: none found (add .md files to ~/.senkani/skills/)\n".utf8))
        } else {
            FileHandle.standardError.write(Data("[MCP] WARP skills loaded: \(names.joined(separator: ", "))\n".utf8))
        }
        return prompt
    }

    /// Pre-populate ReadCache with hot files from the session database.
    /// L0 (top 5): pinned — never evicted by LRU. L1 (next 15): normal LRU.
    /// Non-blocking (utility queue). Only when cacheEnabled.
    func preCacheHotFiles() {
        guard cacheEnabled else { return }
        DispatchQueue.global(qos: .utility).async { [projectRoot, readCache] in
            let hotFiles = SessionDatabase.shared.hotFiles(projectRoot: projectRoot, limit: 50)
            var l0Count = 0, l1Count = 0
            for (index, file) in hotFiles.prefix(20).enumerated() {
                let absPath = file.path.hasPrefix("/") ? file.path : projectRoot + "/" + file.path
                guard FileManager.default.fileExists(atPath: absPath),
                      let content = try? String(contentsOfFile: absPath, encoding: .utf8),
                      content.utf8.count <= 500_000  // 500KB cap per file
                else { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: absPath)
                let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
                if index < 5 { readCache.pin(absPath) }
                // Pre-cache stores raw file content — only served to callers
                // that also request no processing. Secrets/filter/terse
                // callers will miss and take the full processing path.
                let rawMode = ReadProcessingMode(filter: false, secrets: false, terse: false)
                readCache.store(path: absPath, mtime: mtime, mode: rawMode, content: content, rawBytes: content.utf8.count)
                if index < 5 { l0Count += 1 } else { l1Count += 1 }
            }
            if l0Count + l1Count > 0 {
                fputs("[senkani] Pre-cached \(l0Count) L0 (pinned) + \(l1Count) L1 hot files\n", stderr)
            }
        }
    }

    /// Blocking index build for CLI commands. Checks if background build finished first.
    func ensureIndex() -> SymbolIndex {
        lock.lock()
        if let idx = _symbolIndex {
            lock.unlock()
            return idx
        }
        lock.unlock()
        // Background build may be in progress — just do a synchronous build
        let idx = IndexStore.buildOrUpdate(projectRoot: projectRoot)
        try? IndexStore.save(idx, projectRoot: projectRoot)
        lock.lock()
        _symbolIndex = idx
        _repoMap = nil
        _indexBuilding = false
        lock.unlock()
        return idx
    }

    /// Lazily build the dependency graph. Cached after first call.
    func ensureDependencyGraph() -> DependencyGraph {
        lock.lock()
        if let graph = _dependencyGraph {
            lock.unlock()
            return graph
        }
        lock.unlock()
        let graph = IndexEngine.buildDependencyGraph(projectRoot: projectRoot)
        lock.lock()
        _dependencyGraph = graph
        lock.unlock()
        return graph
    }

    /// Non-blocking access to the dependency graph.
    func dependencyGraphIfReady() -> DependencyGraph? {
        lock.lock()
        defer { lock.unlock() }
        return _dependencyGraph
    }

    // MARK: - File Watcher

    /// Start watching the project directory for file changes.
    /// Called after the initial index is built. Idempotent.
    func startFileWatcher() {
        lock.lock()
        defer { lock.unlock() }
        guard fileWatcher == nil else { return }

        let watcher = FileWatcher(projectRoot: projectRoot) { [weak self] changedFiles in
            guard let self else { return }
            self.handleFileChanges(changedFiles)
        }
        watcher.start()
        fileWatcher = watcher
    }

    /// Stop watching. Called on session teardown. Idempotent.
    func stopFileWatcher() {
        lock.lock()
        defer { lock.unlock() }
        fileWatcher?.stop()
        fileWatcher = nil
    }

    // MARK: - Change Event Ring Buffer (senkani_watch)

    /// A file change event for the ring buffer.
    struct ChangeEvent: Sendable, Codable {
        let path: String          // relative to projectRoot
        let eventType: String     // "modified", "created", "deleted"
        let timestamp: Date
    }

    private var recentChanges: [ChangeEvent] = []
    private let changeBufferCapacity = 500

    /// Append change events to the ring buffer. O(1) amortized.
    func appendChangeEvents(_ events: [ChangeEvent]) {
        lock.lock()
        defer { lock.unlock() }
        recentChanges.append(contentsOf: events)
        if recentChanges.count > changeBufferCapacity {
            recentChanges.removeFirst(recentChanges.count - changeBufferCapacity)
        }
    }

    /// Query changes since a cursor timestamp, optionally filtered by glob.
    /// Non-destructive — the agent manages its own cursor.
    func changesSince(_ since: Date?, glob: String?) -> [ChangeEvent] {
        lock.lock()
        let snapshot = recentChanges
        lock.unlock()

        var result = snapshot
        if let since = since {
            result = result.filter { $0.timestamp > since }
        }
        if let glob = glob {
            result = result.filter { fnmatch(glob, $0.path, FNM_PATHNAME) == 0 }
        }
        return result
    }

    // MARK: - Symbol Staleness Tracking

    /// Track a file path that was queried via search/fetch/outline.
    /// If the file later changes, a staleness notice will be generated.
    func trackQueriedSymbol(file: String) {
        lock.lock()
        queriedSymbols.insert(file)
        lock.unlock()
    }

    /// Check changed files against queried symbols and generate notices.
    /// Called from handleFileChanges() after re-indexing.
    func checkStaleness(changedFiles: Set<String>) {
        lock.lock()
        let staleFiles = changedFiles.intersection(queriedSymbols)
        if !staleFiles.isEmpty {
            let notice = "[stale] Symbols may have changed in: \(staleFiles.sorted().joined(separator: ", "))"
            staleNotices.append(notice)
            queriedSymbols.subtract(staleFiles)
        }
        lock.unlock()
    }

    /// Return and clear pending stale notices. Thread-safe.
    func drainStaleNotices() -> [String] {
        lock.lock()
        let notices = staleNotices
        staleNotices.removeAll()
        lock.unlock()
        return notices
    }

    // MARK: - Pinned Context (@-mention)

    /// Pin a named entity. Generates a compressed outline via the fallback chain
    /// and stores it in `pinnedContextStore` for prepending to subsequent results.
    /// Returns a user-facing confirmation or error string.
    func pinContext(name: String, ttl: Int = PinnedContextStore.defaultTTL) -> String {
        guard let outline = PinnedContextGenerator.generate(name: name, session: self) else {
            // Nothing found — suggest nearest BM25 match if available
            if let nearest = PinnedContextGenerator.nearestMatch(name: name, session: self) {
                return "Symbol '\(name)' not found. Did you mean '\(nearest)'? Use senkani_session action='pin' name='\(nearest)' to pin it."
            }
            return "Symbol '\(name)' not found in knowledge base or symbol index."
        }
        let entry = PinnedEntry(name: name, outline: outline, ttl: ttl)
        pinnedContextStore.pin(entry)
        let path = outline.components(separatedBy: "\n").first ?? name
        return "Pinned: \(path) · expires in \(entry.maxCalls) calls. Use action='unpin' to remove."
    }

    /// Enable or disable automatic @-mention pin detection from tool arguments.
    /// Off by default (Jobs synthesis: explicit-only pin is the safe default).
    func setAutoPinEnabled(_ enabled: Bool) {
        lock.lock()
        autoPinEnabled = enabled
        lock.unlock()
    }

    /// Scan tool argument text for `@Name` patterns and queue auto-pins.
    /// Only called when `autoPinEnabled` is true.
    func detectAndQueueAutoPins(argText: String) {
        let pattern = try? NSRegularExpression(pattern: #"@([A-Za-z_][A-Za-z0-9_]*)"#)
        let range = NSRange(argText.startIndex..., in: argText)
        let matches = pattern?.matches(in: argText, range: range) ?? []
        let names = matches.compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: argText) else { return nil }
            return String(argText[r])
        }
        guard !names.isEmpty else { return }
        let capturedSession = self
        Task.detached(priority: .background) {
            for name in names {
                guard capturedSession.pinnedContextStore.all()
                    .first(where: { $0.name == name }) == nil else { continue }
                _ = capturedSession.pinContext(name: name)
            }
        }
    }

    // MARK: - Background Jobs (senkani_exec background mode)

    /// A long-running background process managed by senkani_exec.
    final class BackgroundJob: @unchecked Sendable {
        let id: String
        let process: Process
        let startTime: Date
        let command: String
        private let outputLock = NSLock()
        private var _outputBuffer = Data()
        private var _exitCode: Int32? = nil
        private var _killed = false
        private let maxOutputBytes = 1_048_576  // 1MB

        init(id: String, process: Process, command: String) {
            self.id = id
            self.process = process
            self.command = command
            self.startTime = Date()
        }

        var pid: Int32 { process.processIdentifier }

        func appendOutput(_ data: Data) {
            outputLock.lock()
            defer { outputLock.unlock() }
            let remaining = maxOutputBytes - _outputBuffer.count
            if remaining > 0 { _outputBuffer.append(data.prefix(remaining)) }
        }

        func setExitCode(_ code: Int32) {
            outputLock.lock()
            _exitCode = code
            outputLock.unlock()
        }

        var exitCode: Int32? {
            outputLock.lock()
            defer { outputLock.unlock() }
            return _exitCode
        }

        var isRunning: Bool { process.isRunning }

        var output: String {
            outputLock.lock()
            defer { outputLock.unlock() }
            return String(data: _outputBuffer, encoding: .utf8) ?? ""
        }

        var killed: Bool {
            outputLock.lock()
            defer { outputLock.unlock() }
            return _killed
        }

        func markKilled() {
            outputLock.lock()
            _killed = true
            outputLock.unlock()
        }
    }

    private var backgroundJobs: [String: BackgroundJob] = [:]
    static let autoKillCeiling: TimeInterval = 600  // 10 minutes

    func registerBackgroundJob(_ job: BackgroundJob) {
        lock.lock()
        backgroundJobs[job.id] = job
        lock.unlock()
        scheduleAutoKill(jobId: job.id)
    }

    func backgroundJob(id: String) -> BackgroundJob? {
        lock.lock()
        defer { lock.unlock() }
        return backgroundJobs[id]
    }

    func removeBackgroundJob(id: String) {
        lock.lock()
        backgroundJobs.removeValue(forKey: id)
        lock.unlock()
    }

    private func scheduleAutoKill(jobId: String) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.autoKillCeiling) { [weak self] in
            guard let self, let job = self.backgroundJob(id: jobId) else { return }
            if job.isRunning {
                job.process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if job.isRunning { kill(job.pid, SIGKILL) }
                }
                job.markKilled()
            }
        }
    }

    // MARK: - File Change Handling

    /// Handle a batch of changed files from the FileWatcher.
    /// Re-indexes each file incrementally, then updates the in-memory symbol index.
    private func handleFileChanges(_ changedFiles: [String]) {
        let prefix = projectRoot + "/"
        let relativePaths = changedFiles.compactMap { absPath -> String? in
            guard absPath.hasPrefix(prefix) else { return nil }
            return String(absPath.dropFirst(prefix.count))
        }
        guard !relativePaths.isEmpty else { return }

        // Append to ring buffer for senkani_watch
        let now = Date()
        let events = relativePaths.map { ChangeEvent(path: $0, eventType: "modified", timestamp: now) }
        appendChangeEvents(events)

        var newEntries: [IndexEntry] = []
        var affectedFiles: Set<String> = []

        for relativePath in relativePaths {
            let fullPath = projectRoot + "/" + relativePath
            affectedFiles.insert(relativePath)

            if !FileManager.default.fileExists(atPath: fullPath) {
                treeCache.remove(file: relativePath)
                continue
            }

            do {
                let entries = try IndexEngine.indexFileIncremental(
                    relativePath: relativePath,
                    projectRoot: projectRoot,
                    treeCache: treeCache
                )
                newEntries.append(contentsOf: entries)
            } catch {
                fputs("[senkani] indexFileIncremental skipped for \(relativePath): \(error)\n", stderr)
            }
        }

        lock.lock()
        guard var idx = _symbolIndex else {
            lock.unlock()
            return
        }
        idx.removeSymbols(forFiles: affectedFiles)
        idx.symbols.append(contentsOf: newEntries)
        idx.generated = Date()
        _symbolIndex = idx
        _repoMap = nil
        lock.unlock()

        // Check for symbol staleness (files the agent previously queried)
        checkStaleness(changedFiles: affectedFiles)

        fputs("[senkani] Re-indexed \(relativePaths.count) changed files (\(newEntries.count) symbols)\n", stderr)
    }

    /// Record metrics for a tool call.
    /// Writes to in-memory counters, JSONL file (for MetricsWatcher), and SessionDatabase.
    func recordMetrics(rawBytes: Int, compressedBytes: Int, feature: String,
                       command: String? = nil, outputPreview: String? = nil, secretsFound: Int = 0) {
        lock.lock()
        totalRawBytes += rawBytes
        totalCompressedBytes += compressedBytes
        toolCallCount += 1
        perFeatureSaved[feature, default: 0] += (rawBytes - compressedBytes)
        lock.unlock()

        let savedBytes = rawBytes - compressedBytes

        // JSONL write — matches MetricEntry format expected by MetricsWatcher
        if let path = metricsFilePath {
            let savingsPercent = rawBytes > 0 ? Double(savedBytes) / Double(rawBytes) * 100.0 : 0.0
            let entry = JSONLMetricEntry(
                command: command ?? feature,
                feature: feature,
                rawBytes: rawBytes,
                filteredBytes: compressedBytes,
                savedBytes: savedBytes,
                savingsPercent: savingsPercent,
                secretsFound: secretsFound,
                timestamp: Date()
            )
            if let data = try? JSONEncoder().encode(entry),
               let json = String(data: data, encoding: .utf8) {
                let line = json + "\n"
                if let lineData = line.data(using: .utf8) {
                    if let handle = FileHandle(forWritingAtPath: path) {
                        handle.seekToEndOfFile()
                        handle.write(lineData)
                        handle.closeFile()
                    } else {
                        FileManager.default.createFile(atPath: path, contents: lineData)
                    }
                }
            }
        } else {
            Logger.log("mcp.metrics.path_missing", fields: [
                "feature": .string(feature),
                "outcome": .string("jsonl_skipped"),
            ])
        }

        // SessionDatabase: write to legacy commands table
        if let sid = sessionId {
            SessionDatabase.shared.recordCommand(
                sessionId: sid,
                toolName: feature,
                command: command,
                rawBytes: rawBytes,
                compressedBytes: compressedBytes,
                feature: feature,
                outputPreview: outputPreview
            )
        }

        // token_events: the new single source of truth for the UI
        let inputTokens = rawBytes / 4
        let outputTokens = compressedBytes / 4
        let savedTokens = savedBytes / 4
        let costCents = Int(Double(savedBytes) / 4.0 / 1_000_000.0 * 300.0)

        SessionDatabase.shared.recordTokenEvent(
            sessionId: sessionId ?? "unknown",
            paneId: paneId,
            projectRoot: projectRoot,
            source: "mcp_tool",
            toolName: feature,
            model: nil,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            savedTokens: savedTokens,
            costCents: costCents,
            feature: feature,
            command: command,
            modelTier: agentType.modelTier
        )
    }

    /// Shut down the session, ending the database session record.
    func shutdown() {
        // Flush pending KB mention deltas before exit — prevents data loss
        entityTracker.flush()
        stopFileWatcher()
        // Kill all background jobs
        lock.lock()
        let jobs = Array(backgroundJobs.values)
        lock.unlock()
        for job in jobs where job.isRunning {
            job.process.terminate()
        }
        // Round-3 pane diary regeneration. Best-effort — a write
        // failure (disk full, permission denied, missing slug env)
        // is swallowed by `PaneDiaryInjection.persist` so pane close
        // never hangs on the diary write. Runs BEFORE `endSession`
        // so the token_events used to compose the brief are still
        // from this session's window.
        let recentRows = SessionDatabase.shared.recentTokenEvents(
            projectRoot: projectRoot, limit: 100
        )
        PaneDiaryInjection.persist(rows: recentRows)
        if let sid = sessionId {
            SessionDatabase.shared.endSession(sessionId: sid)
            let root = projectRoot
            let capturedSid = sid
            Task.detached(priority: .background) {
                await CompoundLearning.runPostSession(
                    sessionId: capturedSid,
                    projectRoot: root,
                    db: .shared
                )
            }
        }
    }

    // MARK: - Budget Enforcement

    /// Check budget limits against current session, daily, and weekly spend.
    /// Per-pane cap is checked first (avoids DB round-trips for pane-only users).
    /// Returns the most restrictive decision across pane + global limits.
    func checkBudget() -> BudgetConfig.Decision {
        let config = BudgetConfig.load()

        lock.lock()
        let raw = totalRawBytes
        let compressed = totalCompressedBytes
        let paneBudgetLimit = paneBudgetSessionLimitCents
        lock.unlock()
        let sessionCents = ModelPricing.costSavedCents(bytes: raw - compressed)

        // Per-pane session cap
        let paneDecision: BudgetConfig.Decision
        if let limit = paneBudgetLimit, limit > 0 {
            let softLimit = Int(Double(limit) * 0.8)
            if sessionCents >= limit {
                paneDecision = .block("Pane session budget exceeded: $\(String(format: "%.2f", Double(sessionCents) / 100)) / $\(String(format: "%.2f", Double(limit) / 100))")
            } else if sessionCents >= softLimit {
                paneDecision = .warn("Approaching pane session budget: $\(String(format: "%.2f", Double(sessionCents) / 100)) / $\(String(format: "%.2f", Double(limit) / 100))")
            } else {
                paneDecision = .allow
            }
            notifyBudgetStatusIfChanged(decision: paneDecision, sessionCents: sessionCents, limitCents: limit)
        } else {
            paneDecision = .allow
        }

        // No global limits — return pane decision directly (skips DB queries)
        guard config.perSessionLimitCents != nil
            || config.dailyLimitCents != nil
            || config.weeklyLimitCents != nil else {
            return paneDecision
        }

        // DB queries: only executed when the relevant limit is configured
        let todayCents = config.dailyLimitCents != nil ? SessionDatabase.shared.costForToday() : 0
        let weekCents = config.weeklyLimitCents != nil ? SessionDatabase.shared.costForWeek() : 0
        let globalDecision = config.check(sessionCents: sessionCents, todayCents: todayCents, weekCents: weekCents)

        // Most restrictive of pane and global; pane wins on ties (pane message is more actionable)
        func priority(_ d: BudgetConfig.Decision) -> Int {
            switch d { case .allow: return 0; case .warn: return 1; case .block: return 2 }
        }
        return priority(paneDecision) >= priority(globalDecision) ? paneDecision : globalDecision
    }

    /// Budget remaining as a fraction (0.0...1.0). Returns 1.0 if no budget configured.
    /// Used by AdaptiveTruncation to scale output caps.
    func budgetRemainingPercent() -> Double {
        let config = BudgetConfig.load()

        lock.lock()
        let raw = totalRawBytes
        let compressed = totalCompressedBytes
        let paneBudgetLimit = paneBudgetSessionLimitCents
        lock.unlock()

        let hasAnyLimit = config.perSessionLimitCents != nil
            || config.dailyLimitCents != nil
            || config.weeklyLimitCents != nil
            || paneBudgetLimit != nil
        guard hasAnyLimit else { return 1.0 }

        let sessionCents = ModelPricing.costSavedCents(bytes: raw - compressed)
        var minRemaining = 1.0

        if let limit = paneBudgetLimit, limit > 0 {
            minRemaining = min(minRemaining, max(0, 1.0 - Double(sessionCents) / Double(limit)))
        }
        if let limit = config.perSessionLimitCents, limit > 0 {
            minRemaining = min(minRemaining, max(0, 1.0 - Double(sessionCents) / Double(limit)))
        }
        if let limit = config.dailyLimitCents, limit > 0 {
            let todayCents = SessionDatabase.shared.costForToday()
            minRemaining = min(minRemaining, max(0, 1.0 - Double(todayCents) / Double(limit)))
        }
        return minRemaining
    }

    /// Send a one-way budget status push to the GUI when the decision changes.
    /// Uses `lastBudgetIPCStatus` to debounce: only fires on transition (none→warn, warn→block, etc.).
    private func notifyBudgetStatusIfChanged(decision: BudgetConfig.Decision, sessionCents: Int, limitCents: Int) {
        guard let pid = paneId else { return }
        let newStatus: String
        switch decision {
        case .allow: newStatus = "none"
        case .warn:  newStatus = "warning"
        case .block: newStatus = "blocked"
        }
        lock.lock()
        let changed = newStatus != lastBudgetIPCStatus
        if changed { lastBudgetIPCStatus = newStatus }
        lock.unlock()
        guard changed else { return }

        let spent = sessionCents
        let limit = limitCents
        Task.detached(priority: .utility) {
            MCPSession.sendBudgetStatusIPC(paneId: pid, status: newStatus, spentCents: spent, limitCents: limit)
        }
    }

    /// Fire-and-forget push of the pane's budget status to the GUI over
    /// `~/.senkani/pane.sock`. If the GUI is not running, the call no-ops
    /// silently — budget telemetry is best-effort and must never stall
    /// the tool-call path.
    private static func sendBudgetStatusIPC(paneId: String, status: String, spentCents: Int, limitCents: Int) {
        let cmd = PaneIPCCommand(action: .setBudgetStatus, params: [
            "pane_id": paneId,
            "status": status,
            "spent_cents": "\(spentCents)",
            "limit_cents": "\(limitCents)",
        ])
        _ = PaneIPC.sendFireAndForget(cmd)
    }

    func recordCacheSaving(bytes: Int) {
        lock.lock()
        totalCacheSavedBytes += bytes
        totalCompressedBytes += 0  // cache hit = 0 bytes sent
        perFeatureSaved["cache", default: 0] += bytes
        lock.unlock()
    }

    /// Update feature toggles at runtime.
    /// Pass `budgetSessionCents: 0` to clear the per-pane budget cap.
    func updateConfig(filter: Bool? = nil, secrets: Bool? = nil, indexer: Bool? = nil,
                      cache: Bool? = nil, terse: Bool? = nil, autoPin: Bool? = nil,
                      budgetSessionCents: Int? = nil) {
        lock.lock()
        if let f = filter { filterEnabled = f }
        if let s = secrets { secretsEnabled = s }
        if let i = indexer { indexerEnabled = i }
        if let c = cache { cacheEnabled = c }
        if let t = terse { terseEnabled = t }
        if let a = autoPin { autoPinEnabled = a }
        if let b = budgetSessionCents { paneBudgetSessionLimitCents = b > 0 ? b : nil }
        lock.unlock()
    }

    /// Get session stats as a formatted string.
    func statsString() -> String {
        lock.lock()
        let raw = totalRawBytes
        let compressed = totalCompressedBytes
        let cacheSaved = totalCacheSavedBytes
        let calls = toolCallCount
        let features = perFeatureSaved
        lock.unlock()

        let totalSaved = raw - compressed + cacheSaved
        let pct = raw > 0 ? Double(totalSaved) / Double(raw + cacheSaved) * 100 : 0
        let estTokensSaved = ModelPricing.bytesToTokens(totalSaved)
        let estDollarsSaved = ModelPricing.costSaved(bytes: totalSaved)

        var lines: [String] = []
        lines.append("Senkani MCP Session Stats")
        lines.append("  Tool calls: \(calls)")
        lines.append("  Raw input:  \(formatBytes(raw + cacheSaved))")
        lines.append("  Output:     \(formatBytes(compressed))")
        lines.append("  Saved:      \(formatBytes(totalSaved)) (\(String(format: "%.0f", pct))%)")
        lines.append("")
        lines.append("  Per-feature savings:")
        for (feature, saved) in features.sorted(by: { $0.value > $1.value }) {
            lines.append("    \(feature.padding(toLength: 10, withPad: " ", startingAt: 0))\(formatBytes(saved))")
        }
        lines.append("")
        lines.append("  Cache hit rate: \(String(format: "%.0f", readCache.hitRate * 100))%")
        lines.append("  Est. tokens saved: \(estTokensSaved)")
        lines.append("  Est. cost saved: $\(String(format: "%.2f", estDollarsSaved))")
        lines.append("")
        lines.append("  Toggles: filter=\(filterEnabled) secrets=\(secretsEnabled) indexer=\(indexerEnabled) cache=\(cacheEnabled) terse=\(terseEnabled)")

        lock.lock()
        let paneBudget = paneBudgetSessionLimitCents
        let skillNames = _loadedSkillNames
        lock.unlock()
        if let limit = paneBudget {
            let sessionCents = ModelPricing.costSavedCents(bytes: raw - compressed + cacheSaved)
            lines.append("  Pane budget: $\(String(format: "%.2f", Double(sessionCents) / 100)) / $\(String(format: "%.2f", Double(limit) / 100))")
        }
        if let names = skillNames, !names.isEmpty {
            lines.append("  WARP skills: \(names.joined(separator: ", "))")
        } else if skillNames != nil {
            lines.append("  WARP skills: none (add .md files to ~/.senkani/skills/)")
        }
        return lines.joined(separator: "\n")
    }

    func configString() -> String {
        lock.lock()
        let paneBudget = paneBudgetSessionLimitCents
        lock.unlock()
        var s = "filter=\(filterEnabled) secrets=\(secretsEnabled) indexer=\(indexerEnabled) cache=\(cacheEnabled) terse=\(terseEnabled)"
        if let limit = paneBudget {
            s += " pane_budget=\(limit)¢"
        }
        return s
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }
}

/// JSONL entry format matching MetricEntry in MetricsWatcher.swift.
/// Uses default JSONEncoder Date encoding (Double, secondsSinceReferenceDate)
/// which matches the default JSONDecoder in MetricsWatcher.
private struct JSONLMetricEntry: Codable {
    let command: String
    let feature: String
    let rawBytes: Int
    let filteredBytes: Int
    let savedBytes: Int
    let savingsPercent: Double
    let secretsFound: Int
    let timestamp: Date
}
