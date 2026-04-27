import Testing
import Foundation
@testable import Core

private func makeTempHistoryPath() -> String {
    "/tmp/senkani-release-slo-\(UUID().uuidString).jsonl"
}

private func writeRows(_ rows: [String], to path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir,
                                              withIntermediateDirectories: true)
    let text = rows.joined(separator: "\n") + "\n"
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
}

@Suite(.serialized)
struct ReleaseSLORowTests {

    @Test("Row decodes from the script's JSON shape with provenance fields")
    func decodesScriptShape() throws {
        let json = """
        {"ts": 1714161600.123, "git_sha": "abc1234", "version": "0.2.0",
         "cold_start_ms_p95": 142.0, "idle_memory_mb": 38.4,
         "install_size_mb": 21.3, "classifier_p95_ms": null}
        """
        let row = try JSONDecoder().decode(ReleaseSLORow.self,
                                            from: Data(json.utf8))
        #expect(row.gitSha == "abc1234")
        #expect(row.version == "0.2.0")
        #expect(row.coldStartMsP95 == 142.0)
        #expect(row.idleMemoryMB == 38.4)
        #expect(row.installSizeMB == 21.3)
        #expect(row.classifierP95Ms == nil)
        #expect(row.value(for: .classifierP95) == nil)
        #expect(row.value(for: .coldStart) == 142.0)
    }

    @Test("Empty history returns noHistory for every SLO")
    func emptyHistoryNoHistoryVerdict() {
        let path = makeTempHistoryPath()
        // File does not exist — load() must return [] and evaluate
        // must surface noHistory rather than throwing.
        let history = ReleaseSLOHistory(customPath: path)
        let evals = history.evaluateAll()
        #expect(evals.count == ReleaseSLOName.allCases.count)
        for e in evals {
            #expect(e.verdict == .noHistory)
        }
        #expect(history.shouldFailGate() == false)
    }
}

@Suite(.serialized)
struct ReleaseSLOEvaluationTests {

    @Test("Latest row within budget + no baseline yet → ok with no-baseline note")
    func singleRowOk() {
        let path = makeTempHistoryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        writeRows([
            #"{"ts":1.0,"git_sha":"a","version":"0.2.0","cold_start_ms_p95":120.0,"idle_memory_mb":40.0,"install_size_mb":22.0,"classifier_p95_ms":null}"#
        ], to: path)
        let history = ReleaseSLOHistory(customPath: path)
        let evals = history.evaluateAll()
        let cold = evals.first { $0.slo == .coldStart }!
        #expect(cold.verdict == .ok)
        #expect(cold.latest == 120.0)
        #expect(cold.baseline == nil)

        let cls = evals.first { $0.slo == .classifierP95 }!
        #expect(cls.verdict == .missing)
        #expect(cls.missingReason?.contains("U.1") == true)

        #expect(history.shouldFailGate() == false)
    }

    @Test("Median-of-5 baseline flags ≥10% regression")
    func regressionFlaggedAt10Pct() {
        let path = makeTempHistoryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Five baseline rows at 100ms cold-start, then a 6th at 115ms
        // (15% over baseline median = 100ms). The gate must flag it.
        writeRows([
            #"{"ts":1.0,"git_sha":"a","version":"0.2.0","cold_start_ms_p95":100.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
            #"{"ts":2.0,"git_sha":"b","version":"0.2.0","cold_start_ms_p95":102.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
            #"{"ts":3.0,"git_sha":"c","version":"0.2.0","cold_start_ms_p95":98.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
            #"{"ts":4.0,"git_sha":"d","version":"0.2.0","cold_start_ms_p95":101.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
            #"{"ts":5.0,"git_sha":"e","version":"0.2.0","cold_start_ms_p95":99.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
            #"{"ts":6.0,"git_sha":"f","version":"0.2.0","cold_start_ms_p95":115.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
        ], to: path)
        let history = ReleaseSLOHistory(customPath: path)
        let cold = history.evaluateAll().first { $0.slo == .coldStart }!
        #expect(cold.verdict == .regression)
        #expect(cold.baseline == 100.0)
        #expect(cold.percentOverBaseline.map { $0 >= 10.0 } == true)
        #expect(history.shouldFailGate() == true)
    }

    @Test("A 5% improvement passes the gate; improvements never regress")
    func improvementsDoNotRegress() {
        let path = makeTempHistoryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        writeRows([
            #"{"ts":1.0,"git_sha":"a","version":"0.2.0","cold_start_ms_p95":100.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
            #"{"ts":2.0,"git_sha":"b","version":"0.2.0","cold_start_ms_p95":100.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
            #"{"ts":3.0,"git_sha":"c","version":"0.2.0","cold_start_ms_p95":100.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
            #"{"ts":4.0,"git_sha":"d","version":"0.2.0","cold_start_ms_p95":100.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
            #"{"ts":5.0,"git_sha":"e","version":"0.2.0","cold_start_ms_p95":100.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
            #"{"ts":6.0,"git_sha":"f","version":"0.2.0","cold_start_ms_p95":95.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
        ], to: path)
        let history = ReleaseSLOHistory(customPath: path)
        let cold = history.evaluateAll().first { $0.slo == .coldStart }!
        #expect(cold.verdict == .ok)
        #expect(history.shouldFailGate() == false)
    }

    @Test("A measurement over the published threshold fails as overBudget, even with no baseline")
    func overBudgetFailsImmediately() {
        let path = makeTempHistoryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Single row, install size 60 MB > 50 MB threshold.
        writeRows([
            #"{"ts":1.0,"git_sha":"a","version":"0.2.0","cold_start_ms_p95":120.0,"idle_memory_mb":null,"install_size_mb":60.0,"classifier_p95_ms":null}"#,
        ], to: path)
        let history = ReleaseSLOHistory(customPath: path)
        let install = history.evaluateAll().first { $0.slo == .installSize }!
        #expect(install.verdict == .overBudget)
        #expect(history.shouldFailGate() == true)
    }

    @Test("Bad lines in the middle are skipped without failing the read")
    func badLinesAreSkipped() {
        let path = makeTempHistoryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        writeRows([
            #"{"ts":1.0,"git_sha":"a","version":"0.2.0","cold_start_ms_p95":100.0,"idle_memory_mb":null,"install_size_mb":20.0,"classifier_p95_ms":null}"#,
            "this is not json",
            "",
            #"{"ts":2.0,"git_sha":"b","version":"0.2.0","cold_start_ms_p95":105.0,"idle_memory_mb":null,"install_size_mb":21.0,"classifier_p95_ms":null}"#,
        ], to: path)
        let history = ReleaseSLOHistory(customPath: path)
        let rows = history.load()
        #expect(rows.count == 2)
        #expect(rows.last?.coldStartMsP95 == 105.0)
    }
}
