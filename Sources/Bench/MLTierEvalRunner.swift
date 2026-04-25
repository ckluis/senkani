import Foundation

// MARK: - Quality rating

/// Per-tier output-quality rating. Surfaced in `senkani doctor` and the
/// Models pane so 8 GB Mac users learn the lower tier is materially worse
/// before silently being routed to it.
public enum MLTierQualityRating: String, Codable, Sendable {
    /// ≥80% pass rate. Ship the tier without caveat.
    case excellent
    /// 60–79% pass rate. Usable; doctor logs it but does not warn.
    case acceptable
    /// <60% pass rate. Doctor emits a warning so the user knows.
    case degraded
    /// Tier exists in the registry but no eval has been run, or RAM is
    /// below `requiredRAM` so the tier can't load on this machine.
    case notEvaluated

    public static func rate(passRate: Double) -> MLTierQualityRating {
        if passRate >= 0.80 { return .excellent }
        if passRate >= 0.60 { return .acceptable }
        return .degraded
    }
}

// MARK: - Per-tier result

/// Aggregated eval result for a single tier.
public struct MLTierEvalResult: Codable, Sendable {
    public let tierId: String
    public let tierName: String
    public let rating: MLTierQualityRating
    public let passed: Int
    public let total: Int
    public let medianLatencyMs: Double
    public let totalOutputTokens: Int
    public let evaluatedAt: Date
    /// When `rating == .notEvaluated`, a one-liner explaining why
    /// (e.g. "insufficient RAM (8 GB; tier requires 16 GB)").
    public let skipReason: String?

    public var passRate: Double {
        total > 0 ? Double(passed) / Double(total) : 0
    }

    public init(
        tierId: String,
        tierName: String,
        rating: MLTierQualityRating,
        passed: Int,
        total: Int,
        medianLatencyMs: Double,
        totalOutputTokens: Int,
        evaluatedAt: Date,
        skipReason: String? = nil
    ) {
        self.tierId = tierId
        self.tierName = tierName
        self.rating = rating
        self.passed = passed
        self.total = total
        self.medianLatencyMs = medianLatencyMs
        self.totalOutputTokens = totalOutputTokens
        self.evaluatedAt = evaluatedAt
        self.skipReason = skipReason
    }
}

// MARK: - Report

/// Persisted on disk at `~/.senkani/ml-tier-eval.json`. `senkani doctor`
/// and the Models pane both read it.
public struct MLTierEvalReport: Codable, Sendable {
    public let generatedAt: Date
    public let machineRamGB: Int
    public let tiers: [MLTierEvalResult]

    public init(generatedAt: Date, machineRamGB: Int, tiers: [MLTierEvalResult]) {
        self.generatedAt = generatedAt
        self.machineRamGB = machineRamGB
        self.tiers = tiers
    }

    public func result(for tierId: String) -> MLTierEvalResult? {
        return tiers.first { $0.tierId == tierId }
    }
}

// MARK: - Persistence

public enum MLTierEvalReportStore {

    /// Default path: `~/.senkani/ml-tier-eval.json`.
    public static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".senkani/ml-tier-eval.json")
    }

    public static func load(from url: URL = defaultURL) -> MLTierEvalReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MLTierEvalReport.self, from: data)
    }

    public static func save(_ report: MLTierEvalReport, to url: URL = defaultURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Runner

/// Drives a list of `MLTierEvalTask`s against a caller-provided
/// inference closure and aggregates results. Bench has no MLX dependency
/// — the actual MLX wiring lives in MCPServer / a future
/// `senkani ml-eval` CLI that injects its inference closure here.
public enum MLTierEvalRunner {

    /// Run all tasks against `inference`, return aggregated tier result.
    /// `inference` is async and may throw. Failures count as task misses
    /// (they reduce accuracy but do not abort the run).
    public static func evaluate(
        tier: (id: String, name: String),
        tasks: [MLTierEvalTask],
        clock: () -> Date = { Date() },
        inference: (MLTierEvalTask) async throws -> (response: String, outputTokens: Int)
    ) async -> MLTierEvalResult {
        var passed = 0
        var latencies: [Double] = []
        var totalTokens = 0

        for task in tasks {
            let start = clock()
            do {
                let (response, tokens) = try await inference(task)
                let elapsedMs = clock().timeIntervalSince(start) * 1000
                latencies.append(elapsedMs)
                totalTokens += tokens
                if task.passes(response: response) { passed += 1 }
            } catch {
                let elapsedMs = clock().timeIntervalSince(start) * 1000
                latencies.append(elapsedMs)
            }
        }

        let total = tasks.count
        let median = Self.median(latencies)
        let rating: MLTierQualityRating = total == 0
            ? .notEvaluated
            : MLTierQualityRating.rate(passRate: Double(passed) / Double(total))

        return MLTierEvalResult(
            tierId: tier.id,
            tierName: tier.name,
            rating: rating,
            passed: passed,
            total: total,
            medianLatencyMs: median,
            totalOutputTokens: totalTokens,
            evaluatedAt: clock()
        )
    }

    /// Build a "not evaluated" placeholder for a tier the machine can't
    /// load (RAM below `requiredRAM`).
    public static func notEvaluated(
        tier: (id: String, name: String),
        reason: String,
        clock: () -> Date = { Date() }
    ) -> MLTierEvalResult {
        return MLTierEvalResult(
            tierId: tier.id,
            tierName: tier.name,
            rating: .notEvaluated,
            passed: 0,
            total: 0,
            medianLatencyMs: 0,
            totalOutputTokens: 0,
            evaluatedAt: clock(),
            skipReason: reason
        )
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
