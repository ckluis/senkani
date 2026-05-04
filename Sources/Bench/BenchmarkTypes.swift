import Foundation

/// A single benchmark task. Executes under a specific BenchmarkConfig
/// and returns a TaskResult with byte counts and duration.
public struct BenchmarkTask: Sendable {
    public let id: String
    public let category: String
    public let description: String
    public let execute: @Sendable (BenchmarkConfig) -> TaskResult

    public init(
        id: String,
        category: String,
        description: String,
        execute: @Sendable @escaping (BenchmarkConfig) -> TaskResult
    ) {
        self.id = id
        self.category = category
        self.description = description
        self.execute = execute
    }
}

/// Result of running a single task under a single configuration.
public struct TaskResult: Sendable, Codable {
    public let taskId: String
    public let configName: String
    public let category: String
    public let rawBytes: Int
    public let compressedBytes: Int
    public let savedBytes: Int
    public let savedPct: Double
    public let durationMs: Double
    public let error: String?
    /// Confidence tier for this single result. Most fixture-bench tasks
    /// are `.exact`; tasks computed from measured ratios or template
    /// assumptions surface `.estimated` so the runner's rollup can
    /// degrade the report's overall tier accordingly.
    public let confidence: Confidence

    public init(
        taskId: String,
        configName: String,
        category: String,
        rawBytes: Int,
        compressedBytes: Int,
        durationMs: Double,
        error: String? = nil,
        confidence: Confidence = .exact
    ) {
        self.taskId = taskId
        self.configName = configName
        self.category = category
        self.rawBytes = rawBytes
        self.compressedBytes = compressedBytes
        self.savedBytes = max(0, rawBytes - compressedBytes)
        self.savedPct = rawBytes > 0 ? Double(rawBytes - compressedBytes) / Double(rawBytes) * 100 : 0
        self.durationMs = durationMs
        self.error = error
        self.confidence = confidence
    }
}

/// A named configuration: which feature toggles are on.
public struct BenchmarkConfig: Sendable, Codable {
    public let name: String
    public let filter: Bool
    public let cache: Bool
    public let secrets: Bool
    public let indexer: Bool
    public let terse: Bool

    public init(name: String, filter: Bool, cache: Bool, secrets: Bool, indexer: Bool, terse: Bool) {
        self.name = name
        self.filter = filter
        self.cache = cache
        self.secrets = secrets
        self.indexer = indexer
        self.terse = terse
    }

    /// The seven standard configurations from the spec.
    public static let standardConfigs: [BenchmarkConfig] = [
        .init(name: "baseline",     filter: false, cache: false, secrets: false, indexer: false, terse: false),
        .init(name: "filter_only",  filter: true,  cache: false, secrets: false, indexer: false, terse: false),
        .init(name: "cache_only",   filter: false, cache: true,  secrets: false, indexer: false, terse: false),
        .init(name: "indexer_only", filter: false, cache: false, secrets: false, indexer: true,  terse: false),
        .init(name: "terse_only",   filter: false, cache: false, secrets: false, indexer: false, terse: true),
        .init(name: "fcsi",         filter: true,  cache: true,  secrets: true,  indexer: true,  terse: false),
        .init(name: "full",         filter: true,  cache: true,  secrets: true,  indexer: true,  terse: true),
    ]
}

/// A quality gate: threshold + measured value + pass/fail.
public struct QualityGate: Sendable, Codable {
    public let name: String
    public let category: String
    public let threshold: Double
    public let actual: Double
    public let passed: Bool

    public init(name: String, category: String, threshold: Double, actual: Double) {
        self.name = name
        self.category = category
        self.threshold = threshold
        self.actual = actual
        self.passed = actual >= threshold
    }
}

/// Confidence tier for a reported savings number. See
/// `spec/testing.md` → "Confidence Tiers for Reported Savings".
/// The discipline rule: an `estimated` number must never be presented
/// as `exact` in any user-facing surface.
public enum Confidence: String, Sendable, Codable {
    /// Mechanically derived from receipts or pure-function computation.
    /// Same inputs → byte-identical output.
    case exact
    /// Uses measured ratios or template assumptions to project what
    /// *would* happen on inputs that weren't actually run.
    case estimated
    /// Depends on behavior that can't be re-derived without re-execution.
    case needsValidation = "needs_validation"
    /// Inputs lack the evidence to evaluate this question at all.
    case unsupported

    /// The most permissive tier of two. Used to roll up a mixed-tier
    /// report to its weakest member: a pile containing one `estimated`
    /// row reports `estimated` overall.
    public func loosened(by other: Confidence) -> Confidence {
        let order: [Confidence] = [.exact, .estimated, .needsValidation, .unsupported]
        let lhs = order.firstIndex(of: self) ?? 0
        let rhs = order.firstIndex(of: other) ?? 0
        return order[max(lhs, rhs)]
    }
}

/// Aggregated benchmark report.
public struct BenchmarkReport: Sendable, Codable {
    public let timestamp: Date
    public let durationMs: Double
    public let configs: [BenchmarkConfig]
    public let results: [TaskResult]
    public let gates: [QualityGate]
    public let overallMultiplier: Double
    public let allGatesPassed: Bool
    /// Confidence tier for the headline numbers in this report.
    /// Defaults to `.exact` for the fixture bench (deterministic
    /// computation over fixed inputs). Scenario simulator reports
    /// override to `.estimated`. See `Confidence` above.
    public let confidence: Confidence

    public init(
        timestamp: Date,
        durationMs: Double,
        configs: [BenchmarkConfig],
        results: [TaskResult],
        gates: [QualityGate],
        overallMultiplier: Double,
        allGatesPassed: Bool,
        confidence: Confidence = .exact
    ) {
        self.timestamp = timestamp
        self.durationMs = durationMs
        self.configs = configs
        self.results = results
        self.gates = gates
        self.overallMultiplier = overallMultiplier
        self.allGatesPassed = allGatesPassed
        self.confidence = confidence
    }
}

extension BenchmarkReport {
    /// Returns a new report with additional gates appended and allGatesPassed recomputed.
    public func appending(gates extra: [QualityGate]) -> BenchmarkReport {
        let merged = gates + extra
        return BenchmarkReport(
            timestamp: timestamp,
            durationMs: durationMs,
            configs: configs,
            results: results,
            gates: merged,
            overallMultiplier: overallMultiplier,
            allGatesPassed: merged.allSatisfy(\.passed),
            confidence: confidence
        )
    }
}
