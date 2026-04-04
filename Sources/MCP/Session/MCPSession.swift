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
    let metricsFilePath: String?
    let sessionId: String?
    private let lock = NSLock()

    // Feature toggles (mutable at runtime)
    private(set) var filterEnabled: Bool
    private(set) var secretsEnabled: Bool
    private(set) var indexerEnabled: Bool
    private(set) var cacheEnabled: Bool

    // Lazy symbol index
    private var _symbolIndex: SymbolIndex?

    // Running metrics
    private(set) var totalRawBytes = 0
    private(set) var totalCompressedBytes = 0
    private(set) var totalCacheSavedBytes = 0
    private(set) var toolCallCount = 0
    private(set) var perFeatureSaved: [String: Int] = [:]  // feature name -> bytes saved

    init(projectRoot: String, filterEnabled: Bool = true, secretsEnabled: Bool = true,
         indexerEnabled: Bool = true, cacheEnabled: Bool = true,
         readCache: ReadCache? = nil,
         metricsFilePath: String? = nil, sessionId: String? = nil) {
        self.projectRoot = projectRoot
        self.filterEnabled = filterEnabled
        self.secretsEnabled = secretsEnabled
        self.indexerEnabled = indexerEnabled
        self.cacheEnabled = cacheEnabled
        self.readCache = readCache ?? ReadCache()
        self.metricsFilePath = metricsFilePath
        self.sessionId = sessionId

        let config = FeatureConfig(filter: filterEnabled, secrets: secretsEnabled, indexer: indexerEnabled)
        self.pipeline = FilterPipeline(config: config)
        self.validatorRegistry = ValidatorRegistry.load(projectRoot: projectRoot)
    }

    /// Resolve session config from environment.
    static func resolve() -> MCPSession {
        let root = ProcessInfo.processInfo.environment["SENKANI_PROJECT_ROOT"]
            ?? FileManager.default.currentDirectoryPath
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

        let metricsFile = ProcessInfo.processInfo.environment["SENKANI_METRICS_FILE"]
        let sessionId: String? = metricsFile != nil ? SessionDatabase.shared.createSession() : nil

        return MCPSession(
            projectRoot: root,
            filterEnabled: passthrough ? false : envBool("SENKANI_MCP_FILTER", fallback: true),
            secretsEnabled: passthrough ? false : envBool("SENKANI_MCP_SECRETS", fallback: true),
            indexerEnabled: passthrough ? false : envBool("SENKANI_MCP_INDEX", fallback: true),
            cacheEnabled: passthrough ? false : envBool("SENKANI_MCP_CACHE", fallback: true),
            metricsFilePath: metricsFile,
            sessionId: sessionId
        )
    }

    /// Lazily build or load the symbol index.
    func ensureIndex() -> SymbolIndex {
        lock.lock()
        defer { lock.unlock() }
        if let idx = _symbolIndex { return idx }
        let idx = IndexStore.buildOrUpdate(projectRoot: projectRoot)
        try? IndexStore.save(idx, projectRoot: projectRoot)
        _symbolIndex = idx
        return idx
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

        // JSONL write — matches MetricEntry format expected by MetricsWatcher
        if let path = metricsFilePath {
            let savedBytes = rawBytes - compressedBytes
            let savingsPercent = rawBytes > 0 ? Double(savedBytes) / Double(rawBytes) * 100.0 : 0.0
            let entry = JSONLMetricEntry(
                command: command ?? feature,
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
        }

        // SessionDatabase write
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
    }

    /// Shut down the session, ending the database session record.
    func shutdown() {
        if let sid = sessionId {
            SessionDatabase.shared.endSession(sessionId: sid)
        }
    }

    // MARK: - Budget Enforcement

    /// Check budget limits against current session, daily, and weekly spend.
    /// Returns nil if allowed, a warning string for soft limits, or an error string for hard limits.
    /// The caller must distinguish warn vs block by checking BudgetConfig.Decision directly.
    func checkBudget() -> BudgetConfig.Decision {
        let config = BudgetConfig.load()

        // If no limits configured, skip entirely
        guard config.perSessionLimitCents != nil
            || config.dailyLimitCents != nil
            || config.weeklyLimitCents != nil else {
            return .allow
        }

        // Session cost estimate: (total bytes processed) / 4 bytes per token / 1M * $3 in cents
        lock.lock()
        let raw = totalRawBytes
        let compressed = totalCompressedBytes
        lock.unlock()
        let sessionCents = Int(Double(raw - compressed) / 4.0 / 1_000_000 * 300)

        // Daily and weekly from database
        let todayCents = SessionDatabase.shared.costForToday()
        let weekCents = SessionDatabase.shared.costForWeek()

        return config.check(sessionCents: sessionCents, todayCents: todayCents, weekCents: weekCents)
    }

    func recordCacheSaving(bytes: Int) {
        lock.lock()
        totalCacheSavedBytes += bytes
        totalCompressedBytes += 0  // cache hit = 0 bytes sent
        perFeatureSaved["cache", default: 0] += bytes
        lock.unlock()
    }

    /// Update feature toggles at runtime.
    func updateConfig(filter: Bool? = nil, secrets: Bool? = nil, indexer: Bool? = nil, cache: Bool? = nil) {
        lock.lock()
        if let f = filter { filterEnabled = f }
        if let s = secrets { secretsEnabled = s }
        if let i = indexer { indexerEnabled = i }
        if let c = cache { cacheEnabled = c }
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
        let estTokensSaved = totalSaved / 4  // rough: 1 token ~ 4 bytes
        let estDollarsSaved = Double(estTokensSaved) / 1_000_000 * 3.0  // ~$3/M input tokens

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
        lines.append("  Toggles: filter=\(filterEnabled) secrets=\(secretsEnabled) indexer=\(indexerEnabled) cache=\(cacheEnabled)")
        return lines.joined(separator: "\n")
    }

    func configString() -> String {
        "filter=\(filterEnabled) secrets=\(secretsEnabled) indexer=\(indexerEnabled) cache=\(cacheEnabled)"
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
    let rawBytes: Int
    let filteredBytes: Int
    let savedBytes: Int
    let savingsPercent: Double
    let secretsFound: Int
    let timestamp: Date
}
