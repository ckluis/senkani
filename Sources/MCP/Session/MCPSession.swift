import Foundation
import Core
import Filter
import Indexer

/// Shared session state for the MCP server.
/// Holds read cache, symbol index, feature config, and running metrics.
final class MCPSession: @unchecked Sendable {
    let projectRoot: String
    let readCache = ReadCache()
    let pipeline: FilterPipeline
    let validatorRegistry: ValidatorRegistry
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
    private(set) var perFeatureSaved: [String: Int] = [:]  // feature name → bytes saved

    init(projectRoot: String, filterEnabled: Bool = true, secretsEnabled: Bool = true,
         indexerEnabled: Bool = true, cacheEnabled: Bool = true) {
        self.projectRoot = projectRoot
        self.filterEnabled = filterEnabled
        self.secretsEnabled = secretsEnabled
        self.indexerEnabled = indexerEnabled
        self.cacheEnabled = cacheEnabled

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

        return MCPSession(
            projectRoot: root,
            filterEnabled: passthrough ? false : envBool("SENKANI_MCP_FILTER", fallback: true),
            secretsEnabled: passthrough ? false : envBool("SENKANI_MCP_SECRETS", fallback: true),
            indexerEnabled: passthrough ? false : envBool("SENKANI_MCP_INDEX", fallback: true),
            cacheEnabled: passthrough ? false : envBool("SENKANI_MCP_CACHE", fallback: true)
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
    func recordMetrics(rawBytes: Int, compressedBytes: Int, feature: String) {
        lock.lock()
        totalRawBytes += rawBytes
        totalCompressedBytes += compressedBytes
        toolCallCount += 1
        perFeatureSaved[feature, default: 0] += (rawBytes - compressedBytes)
        lock.unlock()
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
