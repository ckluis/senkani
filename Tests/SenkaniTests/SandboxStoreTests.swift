import Testing
import Foundation
@testable import Core

// SandboxStore — extraction round 3 of 5 of the sessiondatabase-split umbrella
// (Luminary P2-11, `sessiondb-split-4-sandboxstore`). These tests exercise
// the store via the façade contract — the public API is the compatibility
// surface callers (ExecTool, WebFetchTool, SessionTool, MCPSession,
// RetentionScheduler) depend on and must not drift.
//
// OutputSandboxingTests.swift still covers the higher-level sandbox summary
// behavior; this suite pins the store-scoped invariants: ID shape, prune
// boundaries, multi-session isolation, and byte/line counting. If it passes
// after the extraction and before it, the move is byte-identical.

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-sandbox-store-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanup(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

@Suite("SandboxStore — writes, reads, prune")
struct SandboxStoreTests {

    @Test("storeSandboxedResult returns a r_-prefixed 14-char ID")
    func storeReturnsWellFormedId() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let sessionId = db.createSession()
        let id = db.storeSandboxedResult(sessionId: sessionId, command: "ls", output: "one\ntwo\nthree")
        #expect(id.hasPrefix("r_"))
        #expect(id.count == 14)

        let suffix = String(id.dropFirst(2))
        let allowed = CharacterSet(charactersIn: "0123456789abcdef-")
        #expect(suffix.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    @Test("retrieveSandboxedResult round-trips command, output, and counts")
    func retrieveRoundTripsCounts() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let sessionId = db.createSession()
        let output = (0..<12).map { "row \($0)" }.joined(separator: "\n")
        let id = db.storeSandboxedResult(sessionId: sessionId, command: "emit", output: output)

        let row = db.retrieveSandboxedResult(resultId: id)
        #expect(row != nil)
        #expect(row?.command == "emit")
        #expect(row?.output == output)
        #expect(row?.lineCount == 12)
        #expect(row?.byteCount == output.utf8.count)
    }

    @Test("pruneSandboxedResults drops rows older than the cutoff and returns the delete count")
    func pruneByAgeRemovesOldRows() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let sessionId = db.createSession()
        let id = db.storeSandboxedResult(sessionId: sessionId, command: "old", output: "stale")

        // interval=0 means "everything older than *now*" — the just-written row
        // ends up on the wrong side of the cutoff.
        let pruned = db.pruneSandboxedResults(olderThan: 0)
        #expect(pruned == 1)

        #expect(db.retrieveSandboxedResult(resultId: id) == nil)
    }

    @Test("pruneSandboxedResults keeps rows younger than the cutoff")
    func pruneKeepsRecentRows() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let sessionId = db.createSession()
        let id = db.storeSandboxedResult(sessionId: sessionId, command: "fresh", output: "keep")

        let pruned = db.pruneSandboxedResults(olderThan: 3600)
        #expect(pruned == 0)
        #expect(db.retrieveSandboxedResult(resultId: id)?.command == "fresh")
    }

    @Test("retrieveSandboxedResult returns nil for an unknown ID")
    func retrieveMissingReturnsNil() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        #expect(db.retrieveSandboxedResult(resultId: "r_doesnotexist") == nil)
    }

    @Test("rows from different sessions are isolated by ID but share the table")
    func multiSessionIsolation() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let s1 = db.createSession()
        let s2 = db.createSession()
        let a = db.storeSandboxedResult(sessionId: s1, command: "a", output: "alpha")
        let b = db.storeSandboxedResult(sessionId: s2, command: "b", output: "beta")

        #expect(a != b)
        #expect(db.retrieveSandboxedResult(resultId: a)?.output == "alpha")
        #expect(db.retrieveSandboxedResult(resultId: b)?.output == "beta")

        // Pruning with a long interval keeps both.
        #expect(db.pruneSandboxedResults(olderThan: 86400) == 0)
        #expect(db.retrieveSandboxedResult(resultId: a) != nil)
        #expect(db.retrieveSandboxedResult(resultId: b) != nil)
    }
}
