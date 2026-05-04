import Testing
import Foundation
@testable import Bench

@Suite("SavingsTestRunner — End-to-End")
struct SavingsTestRunnerEndToEndTests {

    @Test func runsAllStandardTasksAndProducesReport() {
        let tasks = BenchmarkTasks.all()
        #expect(!tasks.isEmpty, "Benchmark task set must not be empty")

        let report = SavingsTestRunner.run(tasks: tasks)
        #expect(report.results.count == tasks.count * BenchmarkConfig.standardConfigs.count)
        #expect(report.durationMs > 0)
    }

    @Test func fullConfigSavesMoreThanBaseline() {
        let tasks = BenchmarkTasks.all()
        let report = SavingsTestRunner.run(tasks: tasks)

        let baselineBytes = report.results
            .filter { $0.configName == "baseline" }
            .reduce(0) { $0 + $1.compressedBytes }
        let fullBytes = report.results
            .filter { $0.configName == "full" }
            .reduce(0) { $0 + $1.compressedBytes }

        #expect(fullBytes < baselineBytes, "Full config must produce fewer bytes than baseline")
    }

    @Test func overallMultiplierMeetsFiveXGoal() throws {
        let tasks = BenchmarkTasks.all()
        let report = SavingsTestRunner.run(tasks: tasks)
        try #require(report.overallMultiplier >= 5.0, "Overall multiplier must be >= 5x — got \(report.overallMultiplier)")
    }

    @Test func noTaskRegressesUnderOptimization() throws {
        let tasks = BenchmarkTasks.all()
        let report = SavingsTestRunner.run(tasks: tasks)

        for result in report.results where result.configName != "baseline" {
            let baseline = report.results.first { $0.taskId == result.taskId && $0.configName == "baseline" }
            guard let baseline else { continue }
            // Allow up to 1% growth tolerance (matches the gate computation)
            let tolerance = max(1, baseline.compressedBytes / 100)
            try #require(
                result.compressedBytes <= baseline.compressedBytes + tolerance,
                "Task \(result.taskId) regressed under \(result.configName): \(baseline.compressedBytes) -> \(result.compressedBytes)"
            )
        }
    }
}

@Suite("SavingsTestRunner — Quality Gates")
struct SavingsTestRunnerGateTests {

    @Test func filterGatePassesWith60PercentSavings() throws {
        let tasks = BenchmarkTasks.filterTasks()
        let report = SavingsTestRunner.run(tasks: tasks)
        let filterGate = try #require(report.gates.first { $0.category == "filter" })
        try #require(filterGate.passed, "Filter gate must pass — actual: \(filterGate.actual)%, threshold: \(filterGate.threshold)%")
    }

    @Test func cacheGatePassesWith80PercentSavings() throws {
        let tasks = BenchmarkTasks.cacheTasks()
        let report = SavingsTestRunner.run(tasks: tasks)
        let cacheGate = try #require(report.gates.first { $0.category == "cache" })
        try #require(cacheGate.passed, "Cache gate must pass — actual: \(cacheGate.actual)%, threshold: \(cacheGate.threshold)%")
    }

    @Test func indexerGatePassesWith90PercentSavings() throws {
        let tasks = BenchmarkTasks.indexerTasks()
        let report = SavingsTestRunner.run(tasks: tasks)
        let indexerGate = try #require(report.gates.first { $0.category == "indexer" })
        try #require(indexerGate.passed, "Indexer gate must pass — actual: \(indexerGate.actual)%, threshold: \(indexerGate.threshold)%")
    }

    @Test func secretsGateDetectsAllPlantedKeys() throws {
        let tasks = BenchmarkTasks.secretTasks()
        let report = SavingsTestRunner.run(tasks: tasks)
        let secretsGate = try #require(report.gates.first { $0.category == "secrets" })
        try #require(secretsGate.passed, "Secret redaction gate must pass — actual: \(secretsGate.actual)%, threshold: \(secretsGate.threshold)%")
    }

    @Test func terseGatePassesWith40PercentSavings() throws {
        let tasks = BenchmarkTasks.terseTasks()
        let report = SavingsTestRunner.run(tasks: tasks)
        let terseGate = try #require(report.gates.first { $0.category == "terse" })
        try #require(terseGate.passed, "Terse gate must pass — actual: \(terseGate.actual)%, threshold: \(terseGate.threshold)%")
    }

    @Test func sandboxGatePassesWith80PercentSavings() throws {
        let tasks = BenchmarkTasks.sandboxTasks()
        let report = SavingsTestRunner.run(tasks: tasks)
        let sandboxGate = try #require(report.gates.first { $0.category == "sandbox" })
        try #require(sandboxGate.passed, "Sandbox gate must pass — actual: \(sandboxGate.actual)%, threshold: \(sandboxGate.threshold)%")
    }
}

@Suite("SavingsTestRunner — Reporter")
struct SavingsTestRunnerReporterTests {

    @Test func textReportContainsVerdict() {
        let tasks = BenchmarkTasks.all()
        let report = SavingsTestRunner.run(tasks: tasks)
        let text = BenchmarkReporter.textReport(report)
        #expect(text.contains("Verdict:"))
        #expect(text.contains("Quality Gates"))
        #expect(text.contains("Task Results"))
    }

    @Test func jsonReportIsValidAndRoundTrips() throws {
        let tasks = BenchmarkTasks.all()
        let report = SavingsTestRunner.run(tasks: tasks)
        let data = try BenchmarkReporter.jsonReport(report)
        #expect(data.count > 0)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BenchmarkReport.self, from: data)
        #expect(decoded.results.count == report.results.count)
        #expect(decoded.gates.count == report.gates.count)
    }
}

@Suite("SavingsTestRunner — Gate Math")
struct SavingsTestRunnerMathTests {

    @Test func overallMultiplierComputesCorrectly() throws {
        let results = [
            TaskResult(taskId: "t1", configName: "baseline", category: "filter", rawBytes: 500, compressedBytes: 500, durationMs: 1),
            TaskResult(taskId: "t1", configName: "full", category: "filter", rawBytes: 500, compressedBytes: 100, durationMs: 1),
            TaskResult(taskId: "t2", configName: "baseline", category: "cache", rawBytes: 500, compressedBytes: 500, durationMs: 1),
            TaskResult(taskId: "t2", configName: "full", category: "cache", rawBytes: 500, compressedBytes: 100, durationMs: 1),
        ]
        let multiplier = SavingsTestRunner.computeOverallMultiplier(results: results)
        try #require(multiplier == 5.0, "Expected 5.0x multiplier, got \(multiplier)")
    }

    @Test func gatesDetectRegression() throws {
        let results = [
            TaskResult(taskId: "t1", configName: "baseline", category: "filter", rawBytes: 100, compressedBytes: 100, durationMs: 1),
            TaskResult(taskId: "t1", configName: "full", category: "filter", rawBytes: 100, compressedBytes: 150, durationMs: 1),
        ]
        let gates = SavingsTestRunner.computeGates(results: results)
        let regressionGate = try #require(gates.first { $0.name == "No regressions" })
        try #require(!regressionGate.passed, "Regression gate must fail when a task regresses")
    }
}

@Suite("SavingsTestRunner — Confidence Rollup")
struct SavingsTestRunnerConfidenceTests {

    /// One `.estimated` task in the set degrades the report's overall
    /// confidence to `.estimated`.
    @Test func reportRollsUpEstimatedFromSingleTask() {
        let task = BenchmarkTask(
            id: "estimated_task",
            category: "filter",
            description: "Synthetic estimated task",
            execute: { config in
                TaskResult(
                    taskId: "estimated_task",
                    configName: config.name,
                    category: "filter",
                    rawBytes: 100,
                    compressedBytes: 50,
                    durationMs: 1,
                    confidence: .estimated
                )
            }
        )
        let report = SavingsTestRunner.run(tasks: [task], configs: [BenchmarkConfig.standardConfigs[0]])
        #expect(report.confidence == .estimated)
    }

    /// A three-task mix of `.exact`, `.estimated`, `.needsValidation`
    /// rolls up to the most permissive tier — `.needsValidation`.
    @Test func reportRollsUpToNeedsValidationAcrossMixedTiers() {
        let exactTask = BenchmarkTask(
            id: "exact_task",
            category: "filter",
            description: "Exact",
            execute: { config in
                TaskResult(
                    taskId: "exact_task", configName: config.name, category: "filter",
                    rawBytes: 100, compressedBytes: 50, durationMs: 1,
                    confidence: .exact
                )
            }
        )
        let estimatedTask = BenchmarkTask(
            id: "estimated_task",
            category: "cache",
            description: "Estimated",
            execute: { config in
                TaskResult(
                    taskId: "estimated_task", configName: config.name, category: "cache",
                    rawBytes: 100, compressedBytes: 50, durationMs: 1,
                    confidence: .estimated
                )
            }
        )
        let needsValidationTask = BenchmarkTask(
            id: "nv_task",
            category: "indexer",
            description: "Needs validation",
            execute: { config in
                TaskResult(
                    taskId: "nv_task", configName: config.name, category: "indexer",
                    rawBytes: 100, compressedBytes: 50, durationMs: 1,
                    confidence: .needsValidation
                )
            }
        )
        let report = SavingsTestRunner.run(
            tasks: [exactTask, estimatedTask, needsValidationTask],
            configs: [BenchmarkConfig.standardConfigs[0]]
        )
        #expect(report.confidence == .needsValidation)
    }
}
