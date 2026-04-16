import Testing
import Foundation
@testable import Bench

private func makeTempRoot() -> String {
    let root = "/tmp/senkani-baseline-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: root + "/.senkani",
                                              withIntermediateDirectories: true)
    return root
}
private func cleanup(_ root: String) { try? FileManager.default.removeItem(atPath: root) }

@Suite("BenchBaseline")
struct BenchBaselineTests {

    // 1. Load returns nil when no baseline file exists
    @Test func testLoadMissingReturnsNil() {
        let root = "/tmp/senkani-no-baseline-\(UUID().uuidString)"
        #expect(BenchBaseline.load(projectRoot: root) == nil)
    }

    // 2. Save + Load roundtrip preserves values
    @Test func testSaveLoadRoundtrip() throws {
        let root = makeTempRoot(); defer { cleanup(root) }
        let baseline = BenchBaseline(generatedAt: Date(),
                                     categoryAverages: ["filter": 72.5, "cache": 85.0])
        try BenchBaseline.save(baseline, projectRoot: root)
        let loaded = BenchBaseline.load(projectRoot: root)
        #expect(loaded != nil)
        #expect(loaded?.categoryAverages["filter"] == 72.5)
        #expect(loaded?.categoryAverages["cache"] == 85.0)
    }

    // 3. from(report:) computes correct per-category averages
    // filter: (60 + 80) / 2 = 70, cache: 90
    @Test func testFromReportAverages() {
        let results = [
            TaskResult(taskId: "t1", configName: "full", category: "filter",
                       rawBytes: 100, compressedBytes: 40, durationMs: 10),  // savedPct = 60
            TaskResult(taskId: "t2", configName: "full", category: "filter",
                       rawBytes: 100, compressedBytes: 20, durationMs: 10),  // savedPct = 80
            TaskResult(taskId: "t3", configName: "full", category: "cache",
                       rawBytes: 100, compressedBytes: 10, durationMs: 10),  // savedPct = 90
        ]
        let report = BenchmarkReport(
            timestamp: Date(), durationMs: 0, configs: [], results: results,
            gates: [], overallMultiplier: 0, allGatesPassed: true
        )
        let baseline = BenchBaseline.from(report: report)
        #expect(abs((baseline.categoryAverages["filter"] ?? 0) - 70.0) < 0.01)
        #expect(abs((baseline.categoryAverages["cache"] ?? 0) - 90.0) < 0.01)
    }

    // 4. computeRegressionGates: within tolerance (2pp) → PASS
    // baseline=70.0, tolerance=2.0 → threshold=68.0; current=69.0 → PASS
    @Test func testRegressionGatePassWithinTolerance() {
        let baseline = BenchBaseline(generatedAt: Date(),
                                     categoryAverages: ["filter": 70.0])
        let results = [
            TaskResult(taskId: "t1", configName: "full", category: "filter",
                       rawBytes: 100, compressedBytes: 31, durationMs: 10),  // savedPct = 69
        ]
        let gates = BenchBaseline.computeRegressionGates(results: results, baseline: baseline)
        let gate = gates.first { $0.name == "regression.filter" }
        #expect(gate?.passed == true)
    }

    // 5. computeRegressionGates: below tolerance → FAIL
    // baseline=70.0, tolerance=2.0 → threshold=68.0; current=60.0 → FAIL
    @Test func testRegressionGateFailBelowTolerance() {
        let baseline = BenchBaseline(generatedAt: Date(),
                                     categoryAverages: ["filter": 70.0])
        let results = [
            TaskResult(taskId: "t1", configName: "full", category: "filter",
                       rawBytes: 100, compressedBytes: 40, durationMs: 10),  // savedPct = 60
        ]
        let gates = BenchBaseline.computeRegressionGates(results: results, baseline: baseline)
        let gate = gates.first { $0.name == "regression.filter" }
        #expect(gate?.passed == false)
    }
}
