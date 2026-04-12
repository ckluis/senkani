import Testing
import Foundation
@testable import Core

// MARK: - Helpers

/// Create a fresh temp DB and auto-clean on scope exit.
private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-sandbox-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanup(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

/// Generate a multi-line test output string.
private func makeOutput(lines: Int) -> String {
    (0..<lines).map { "line \($0): output content here" }.joined(separator: "\n")
}

// MARK: - Suite 1: Database Storage

@Suite("Output Sandboxing — Database Storage")
struct SandboxDatabaseStorageTests {

    @Test("Store and retrieve sandboxed result")
    func storeAndRetrieve() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let sessionId = db.createSession()
        let output = makeOutput(lines: 50)
        let resultId = db.storeSandboxedResult(sessionId: sessionId, command: "ls -la", output: output)

        #expect(resultId.hasPrefix("r_"))
        #expect(resultId.count == 14) // "r_" + 12 chars

        let retrieved = db.retrieveSandboxedResult(resultId: resultId)
        #expect(retrieved != nil)
        #expect(retrieved?.command == "ls -la")
        #expect(retrieved?.output == output)
        #expect(retrieved?.lineCount == 50)
        #expect(retrieved?.byteCount == output.utf8.count)
    }

    @Test("Retrieve returns nil for unknown ID")
    func retrieveUnknown() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let result = db.retrieveSandboxedResult(resultId: "r_nonexistent0")
        #expect(result == nil)
    }

    @Test("Prune removes old results")
    func pruneOldResults() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let sessionId = db.createSession()
        let id1 = db.storeSandboxedResult(sessionId: sessionId, command: "cmd1", output: "old output")

        // Prune with 0 interval removes everything
        let pruned = db.pruneSandboxedResults(olderThan: 0)
        #expect(pruned == 1)

        let result = db.retrieveSandboxedResult(resultId: id1)
        #expect(result == nil)
    }

    @Test("Prune preserves recent results")
    func pruneKeepsRecent() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let sessionId = db.createSession()
        let id1 = db.storeSandboxedResult(sessionId: sessionId, command: "recent", output: "recent output")

        // Prune with 1 hour interval — nothing should be removed
        let pruned = db.pruneSandboxedResults(olderThan: 3600)
        #expect(pruned == 0)

        let result = db.retrieveSandboxedResult(resultId: id1)
        #expect(result != nil)
        #expect(result?.command == "recent")
    }

    @Test("Multiple results stored independently")
    func multipleResults() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let sessionId = db.createSession()
        let id1 = db.storeSandboxedResult(sessionId: sessionId, command: "cmd1", output: "output one")
        let id2 = db.storeSandboxedResult(sessionId: sessionId, command: "cmd2", output: "output two")
        let id3 = db.storeSandboxedResult(sessionId: sessionId, command: "cmd3", output: "output three")

        #expect(id1 != id2)
        #expect(id2 != id3)

        let r1 = db.retrieveSandboxedResult(resultId: id1)
        let r2 = db.retrieveSandboxedResult(resultId: id2)
        let r3 = db.retrieveSandboxedResult(resultId: id3)

        #expect(r1?.command == "cmd1")
        #expect(r2?.command == "cmd2")
        #expect(r3?.command == "cmd3")
        #expect(r1?.output == "output one")
        #expect(r2?.output == "output two")
        #expect(r3?.output == "output three")
    }
}

// MARK: - Suite 2: Summary Builder

@Suite("Output Sandboxing — Summary Builder")
struct SandboxSummaryBuilderTests {

    @Test("Summary contains head and tail lines")
    func summaryHeadTail() {
        let output = makeOutput(lines: 50)
        let summary = buildSandboxSummary(
            output: output,
            lineCount: 50,
            byteCount: output.utf8.count,
            resultId: "r_test12345678"
        )

        // Should contain first line
        #expect(summary.contains("line 0: output content here"))
        // Should contain last line
        #expect(summary.contains("line 49: output content here"))
        // Should contain omitted count
        #expect(summary.contains("lines omitted"))
        // Should contain the result ID for retrieval
        #expect(summary.contains("r_test12345678"))
        // Should contain retrieval instruction
        #expect(summary.contains("senkani_session"))
        #expect(summary.contains("result"))
    }

    @Test("Summary shows correct omitted line count")
    func summaryOmittedCount() {
        let output = makeOutput(lines: 30)
        let summary = buildSandboxSummary(
            output: output,
            lineCount: 30,
            byteCount: output.utf8.count,
            resultId: "r_test00000000"
        )

        // 30 lines - 5 head - 5 tail = 20 omitted
        #expect(summary.contains("20 lines omitted"))
    }

    @Test("Summary includes metadata header")
    func summaryMetadata() {
        let output = makeOutput(lines: 100)
        let summary = buildSandboxSummary(
            output: output,
            lineCount: 100,
            byteCount: 2500,
            resultId: "r_meta12345678"
        )

        #expect(summary.contains("100 lines"))
        #expect(summary.contains("2500 bytes"))
        #expect(summary.contains("output sandboxed"))
    }
}

// MARK: - Suite 3: Sandbox Mode Logic

@Suite("Output Sandboxing — Mode Logic")
struct SandboxModeLogicTests {

    @Test("Auto mode threshold is 20 lines")
    func autoModeThreshold() {
        #expect(sandboxLineThreshold == 20)
    }

    @Test("Sandbox mode parses from string")
    func sandboxModeParsing() {
        #expect(SandboxMode(rawValue: "auto") == .auto)
        #expect(SandboxMode(rawValue: "always") == .always)
        #expect(SandboxMode(rawValue: "never") == .never)
        #expect(SandboxMode(rawValue: "invalid") == nil)
    }

    @Test("Result ID format is correct")
    func resultIdFormat() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let sessionId = db.createSession()
        let resultId = db.storeSandboxedResult(sessionId: sessionId, command: "test", output: "test output")

        #expect(resultId.hasPrefix("r_"))
        #expect(resultId.count == 14) // "r_" + 12 chars
        // Only lowercase hex chars and hyphens after prefix
        let suffix = String(resultId.dropFirst(2))
        let validChars = CharacterSet(charactersIn: "0123456789abcdef-")
        #expect(suffix.unicodeScalars.allSatisfy { validChars.contains($0) })
    }
}
