import Testing
import Foundation

/// Gate: `tools/check-multiplier-claims.sh` enforces the testing.md
/// "Live Session Caveat" rule — any external-facing surface quoting
/// a bare multiplier (80x, 80.37, 5-10x, …) must pair it with a
/// fixture / live / synthetic / pending qualifier within ±4 lines.
/// Luminary round 2026-04-24-0 (live-session-multiplier-gate).
@Suite("MultiplierClaimGate") struct MultiplierClaimGateTests {

    private static func runGate(on files: [String]) -> (stdout: String, stderr: String, exit: Int32) {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // .../Tests/SenkaniTests
            .deletingLastPathComponent()          // .../Tests
            .deletingLastPathComponent()          // repo root
            .path
        let script = repoRoot + "/tools/check-multiplier-claims.sh"

        let proc = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: script)
        proc.arguments = files
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch {
            return (stdout: "", stderr: error.localizedDescription, exit: -1)
        }
        proc.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, proc.terminationStatus)
    }

    private static func withTempFile(_ body: String, ext: String = "md", _ test: (String) throws -> Void) rethrows {
        let path = NSTemporaryDirectory() + "senkani-multcheck-\(UUID().uuidString).\(ext)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        FileManager.default.createFile(atPath: path, contents: body.data(using: .utf8))
        try test(path)
    }

    // MARK: - 1. Unpaired bare claim → exit 1

    @Test("unpaired '80x' in a standalone doc fails the gate")
    func unpairedClaimFails() throws {
        try Self.withTempFile(
            """
            # Some marketing doc
            Senkani gets you 80x compression, full stop.
            Other unrelated paragraph.
            """
        ) { path in
            let r = Self.runGate(on: [path])
            #expect(r.exit == 1, "expected nonzero exit, got \(r.exit). stderr=\(r.stderr)")
            #expect(r.stderr.contains("UNPAIRED"))
        }
    }

    // MARK: - 2. Paired claim (fixture qualifier) → exit 0

    @Test("'80.37' paired with 'fixture' within ±4 lines passes the gate")
    func pairedWithFixturePasses() throws {
        try Self.withTempFile(
            """
            # Some honest doc
            Fixture benchmark measurements:
            Compression multiplier 80.37 on synthetic tasks.
            Live number is separately reported.
            """
        ) { path in
            let r = Self.runGate(on: [path])
            #expect(r.exit == 0, "expected zero exit, got \(r.exit). stderr=\(r.stderr)")
        }
    }

    // MARK: - 3. Claim paired only with 'pending' placeholder → exit 0

    @Test("'5-10x' with 'live pending' placeholder passes the gate")
    func pairedWithLivePendingPasses() throws {
        try Self.withTempFile(
            """
            # Mixed doc
            Product promise: 5-10x cost reduction on typical workflows.
            Live-session median: pending Phase G capture.
            """
        ) { path in
            let r = Self.runGate(on: [path])
            #expect(r.exit == 0, "expected zero exit, got \(r.exit). stderr=\(r.stderr)")
        }
    }

    // MARK: - 4. Current repo state (sanity)

    @Test("current external surfaces pass the gate")
    func currentRepoPasses() {
        // No file args → script scans the default surface set.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().path
        let script = repoRoot + "/tools/check-multiplier-claims.sh"
        let proc = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: script)
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch {
            Issue.record("failed to run gate: \(error)")
            return
        }
        proc.waitUntilExit()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0, "gate failed on current repo state. stderr=\(err)")
    }
}
