import Foundation

/// Runs benchmark tasks against configurations and produces a report.
public enum SavingsTestRunner {

    /// Execute a set of tasks across a set of configurations.
    /// Returns a BenchmarkReport with per-task results, quality gates, and an overall multiplier.
    public static func run(
        tasks: [BenchmarkTask],
        configs: [BenchmarkConfig] = BenchmarkConfig.standardConfigs
    ) -> BenchmarkReport {
        let startTime = Date()
        var results: [TaskResult] = []

        for config in configs {
            for task in tasks {
                let result = task.execute(config)
                results.append(result)
            }
        }

        let gates = computeGates(results: results)
        let multiplier = computeOverallMultiplier(results: results)
        let duration = Date().timeIntervalSince(startTime) * 1000
        let confidence = results.reduce(Confidence.exact) { $0.loosened(by: $1.confidence) }

        return BenchmarkReport(
            timestamp: Date(),
            durationMs: duration,
            configs: configs,
            results: results,
            gates: gates,
            overallMultiplier: multiplier,
            allGatesPassed: gates.allSatisfy(\.passed),
            confidence: confidence
        )
    }

    // MARK: - Gate Computation

    /// Compute quality gates from the raw results.
    /// Each gate checks whether a category's best savings meet the threshold.
    public static func computeGates(results: [TaskResult]) -> [QualityGate] {
        let thresholds: [(category: String, name: String, threshold: Double)] = [
            ("filter",      "Filter savings",      60.0),
            ("cache",       "Cache savings",       80.0),
            ("indexer",     "Indexer savings",     90.0),
            ("terse",       "Terse savings",       40.0),
            ("secrets",     "Secret redaction",    99.0),
            ("sandbox",     "Sandbox savings",     80.0),
            ("parse",       "Parse savings",       85.0),
        ]

        var gates: [QualityGate] = []
        for (category, name, threshold) in thresholds {
            let categoryResults = results.filter { $0.category == category && $0.error == nil }
            guard !categoryResults.isEmpty else { continue }
            let best = categoryResults.map(\.savedPct).max() ?? 0
            gates.append(QualityGate(
                name: name,
                category: category,
                threshold: threshold,
                actual: best
            ))
        }

        // Overall multiplier gate: full config bytes vs baseline bytes
        let multiplier = computeOverallMultiplier(results: results)
        gates.append(QualityGate(
            name: "Overall cost multiplier",
            category: "overall",
            threshold: 5.0,
            actual: multiplier
        ))

        // No-regression gate: no task should be significantly WORSE with optimization.
        // Allow up to 1% growth to tolerate rounding artifacts (e.g., TerseCompressor
        // applied to ANSI-escaped text may add a few bytes).
        let hasRegression = results.contains { result in
            if result.configName == "baseline" { return false }
            let baselineBytes = results.first(where: {
                $0.taskId == result.taskId && $0.configName == "baseline"
            })?.compressedBytes ?? result.compressedBytes
            let tolerance = max(1, baselineBytes / 100)
            return result.compressedBytes > baselineBytes + tolerance
        }
        gates.append(QualityGate(
            name: "No regressions",
            category: "overall",
            threshold: 1.0,
            actual: hasRegression ? 0.0 : 1.0
        ))

        return gates
    }

    /// Compute the overall cost multiplier: sum(baseline bytes) / sum(full bytes).
    /// A multiplier of 5.0 means the "full" config uses 1/5 the bytes of baseline.
    public static func computeOverallMultiplier(results: [TaskResult]) -> Double {
        let baselineResults = results.filter { $0.configName == "baseline" && $0.error == nil }
        let fullResults = results.filter { $0.configName == "full" && $0.error == nil }
        let baselineBytes = baselineResults.reduce(0) { $0 + $1.compressedBytes }
        let fullBytes = fullResults.reduce(0) { $0 + $1.compressedBytes }
        guard fullBytes > 0 else { return 0 }
        return Double(baselineBytes) / Double(fullBytes)
    }
}
