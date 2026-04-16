import Foundation

/// Persisted per-category savings baseline for regression detection.
public struct BenchBaseline: Codable {
    public let generatedAt: Date
    /// category → average savedPct (0–100)
    public let categoryAverages: [String: Double]

    public init(generatedAt: Date, categoryAverages: [String: Double]) {
        self.generatedAt = generatedAt
        self.categoryAverages = categoryAverages
    }
}

extension BenchBaseline {

    private static func baselinePath(_ projectRoot: String) -> String {
        projectRoot + "/.senkani/bench-baseline.json"
    }

    /// Load a saved baseline, or nil if none exists.
    public static func load(projectRoot: String) -> BenchBaseline? {
        let path = baselinePath(projectRoot)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BenchBaseline.self, from: data)
    }

    /// Persist the baseline to `.senkani/bench-baseline.json`.
    public static func save(_ baseline: BenchBaseline, projectRoot: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(baseline)
        try data.write(to: URL(fileURLWithPath: baselinePath(projectRoot)))
    }

    /// Build a baseline from the per-category average savedPct in a report's results.
    public static func from(report: BenchmarkReport) -> BenchBaseline {
        var sums: [String: (total: Double, count: Int)] = [:]
        for r in report.results {
            var bucket = sums[r.category] ?? (0, 0)
            bucket.total += r.savedPct
            bucket.count += 1
            sums[r.category] = bucket
        }
        let averages = sums.mapValues { $0.total / Double($0.count) }
        return BenchBaseline(generatedAt: Date(), categoryAverages: averages)
    }

    /// Compute per-category regression gates against a saved baseline.
    /// Tolerance is in percentage points (default: 2pp).
    public static func computeRegressionGates(
        results: [TaskResult],
        baseline: BenchBaseline,
        tolerance: Double = 2.0
    ) -> [QualityGate] {
        var sums: [String: (total: Double, count: Int)] = [:]
        for r in results {
            var bucket = sums[r.category] ?? (0, 0)
            bucket.total += r.savedPct
            bucket.count += 1
            sums[r.category] = bucket
        }
        let current = sums.mapValues { $0.total / Double($0.count) }

        return baseline.categoryAverages.compactMap { cat, baselineAvg in
            guard let currentAvg = current[cat] else { return nil }
            let threshold = max(0, baselineAvg - tolerance)
            return QualityGate(name: "regression.\(cat)", category: "regression",
                               threshold: threshold, actual: currentAvg)
        }
    }
}
