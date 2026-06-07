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

    @Test("openai.cold.start (V.13e-3): field decodes, backfills nil pre-V.13e-3, and evaluates against threshold")
    func openaiColdStartRowAppendedAndEvaluated() throws {
        // 1. A row carrying the V.13e-3 field decodes it + value(for:).
        let withField = """
        {"ts": 1714161600.0, "git_sha": "abc1234", "version": "0.4.0",
         "cold_start_ms_p95": 142.0, "idle_memory_mb": null,
         "install_size_mb": 21.3, "classifier_p95_ms": null,
         "openai_cold_start_ms_p95": 412.0}
        """
        let row = try JSONDecoder().decode(ReleaseSLORow.self,
                                           from: Data(withField.utf8))
        #expect(row.openaiColdStartMsP95 == 412.0)
        #expect(row.value(for: .openaiColdStart) == 412.0)

        // 2. A pre-V.13e-3 row (no key) backfills to nil — the
        //    measure-slos.sh schema bump is backward compatible.
        let withoutField = """
        {"ts": 1.0, "git_sha": "a", "version": "0.2.0",
         "cold_start_ms_p95": 100.0, "idle_memory_mb": null,
         "install_size_mb": 20.0, "classifier_p95_ms": null}
        """
        let old = try JSONDecoder().decode(ReleaseSLORow.self,
                                           from: Data(withoutField.utf8))
        #expect(old.openaiColdStartMsP95 == nil)
        #expect(old.value(for: .openaiColdStart) == nil)

        // 3. A measured row under the 1500ms threshold is ok. (History
        //    is one JSON object per line, so use a single-line row.)
        let okPath = makeTempHistoryPath()
        defer { try? FileManager.default.removeItem(atPath: okPath) }
        writeRows([
            #"{"ts":1714161600.0,"git_sha":"abc1234","version":"0.4.0","cold_start_ms_p95":142.0,"idle_memory_mb":null,"install_size_mb":21.3,"classifier_p95_ms":null,"openai_cold_start_ms_p95":412.0}"#
        ], to: okPath)
        let okHistory = ReleaseSLOHistory(customPath: okPath)
        let okEval = okHistory.evaluateAll().first { $0.slo == .openaiColdStart }!
        #expect(okEval.verdict == .ok)
        #expect(okEval.latest == 412.0)
        #expect(okHistory.shouldFailGate() == false)

        // 4. A row over the 1500ms threshold fails as overBudget.
        let badPath = makeTempHistoryPath()
        defer { try? FileManager.default.removeItem(atPath: badPath) }
        writeRows([
            #"{"ts":2.0,"git_sha":"b","version":"0.4.0","cold_start_ms_p95":142.0,"idle_memory_mb":null,"install_size_mb":21.3,"classifier_p95_ms":null,"openai_cold_start_ms_p95":1600.0}"#
        ], to: badPath)
        let badHistory = ReleaseSLOHistory(customPath: badPath)
        let badEval = badHistory.evaluateAll().first { $0.slo == .openaiColdStart }!
        #expect(badEval.verdict == .overBudget)
        #expect(badHistory.shouldFailGate() == true)
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
struct ReleaseSLOInstallSizeMeasurementTests {

    /// Repo root, resolved from this source file:
    /// Tests/SenkaniTests/ReleaseSLOTests.swift → up three components.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SenkaniTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// Run `tools/measure-install-size.sh <dir>` and return its trimmed
    /// stdout. Throws if the binary can't launch.
    private static func runHelper(_ dir: String) throws -> String {
        let script = repoRoot.appendingPathComponent("tools/measure-install-size.sh")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, dir]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func writeRandom(_ bytes: Int, to path: String) {
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })
        FileManager.default.createFile(atPath: path, contents: data)
    }

    @Test("measure-install-size.sh resolves a symlinked release dir to a non-zero size and sums only shipped products")
    func resolvesSymlinkAndExcludesIntermediates() throws {
        let fm = FileManager.default
        let root = "/tmp/senkani-install-size-\(UUID().uuidString)"
        let target = root + "/arm64-apple-macosx/release"
        let link = root + "/release"          // symlink → target, like SwiftPM
        defer { try? fm.removeItem(atPath: root) }

        try fm.createDirectory(atPath: target, withIntermediateDirectories: true)

        // Shipped products (≈ 384 KB total) — what install.size counts.
        Self.writeRandom(256 * 1024, to: target + "/senkani")
        Self.writeRandom(128 * 1024, to: target + "/senkani-mcp")

        // Build intermediates + a non-product binary (≈ 8 MB) — these
        // MUST NOT be counted. This is the 1.8 GB-tree problem in
        // miniature: random (non-compressible) so APFS can't sparse it.
        try fm.createDirectory(atPath: target + "/Core.build",
                               withIntermediateDirectories: true)
        Self.writeRandom(4 * 1024 * 1024, to: target + "/Core.build/junk.o")
        Self.writeRandom(4 * 1024 * 1024, to: target + "/SenkaniApp") // GUI bundle target — not a CLI product

        // SwiftPM-shaped symlink: `release` → `arm64-apple-macosx/release`.
        try fm.createSymbolicLink(atPath: link, withDestinationPath: "arm64-apple-macosx/release")

        // The bug: `du -sk <symlink>` reports ~0. The fix must follow
        // the link AND sum only the products.
        let out = try Self.runHelper(link)
        let mb = Double(out)
        #expect(mb != nil, "helper printed non-numeric output: \(out)")
        guard let mb else { return }

        // Non-zero → the symlink was followed (the original bug yielded 0.0).
        #expect(mb > 0.0)
        // < 1 MB → only the ~384 KB of products counted; the 8 MB of
        // intermediates / non-products were excluded.
        #expect(mb < 1.0, "expected products-only (~0.4 MB), got \(mb) MB — intermediates leaked in")

        // A missing dir is a `null` measurement, not an error — the
        // script's "never abort the run" contract.
        #expect(try Self.runHelper(root + "/nope") == "null")
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
