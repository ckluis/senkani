import Testing
import Foundation
@testable import Core

// ValidationStore — extraction round 4 of 5 of the sessiondatabase-split
// umbrella (Luminary P2-11, `sessiondb-split-5-validationstore`). These tests
// exercise the store through the `SessionDatabase` façade because that public
// API is the compatibility boundary used by AutoValidateQueue, HookRouter, and
// RetentionScheduler.

private func makeValidationTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-validation-store-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupValidationDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func insertAdvisory(
    _ db: SessionDatabase,
    sessionId: String,
    filePath: String = "/tmp/project/Broken.swift",
    advisory: String = "fix the type error"
) {
    db.insertValidationResult(
        sessionId: sessionId,
        filePath: filePath,
        validatorName: "swiftc",
        category: "type",
        exitCode: 1,
        rawOutput: "error",
        advisory: advisory,
        durationMs: 10
    )
}

@Suite("ValidationStore — attempts, delivery, prune")
struct ValidationStoreTests {

    @Test("pendingValidationAdvisories reads without consuming")
    func pendingReadDoesNotMarkSurfaced() {
        let (db, path) = makeValidationTempDB()
        defer { cleanupValidationDB(path) }
        let sid = db.createSession(projectRoot: "/tmp/project")

        insertAdvisory(db, sessionId: sid)
        db.flushWrites()

        let first = db.pendingValidationAdvisories(sessionId: sid)
        let second = db.pendingValidationAdvisories(sessionId: sid)

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first.first?.outcome == "advisory")
        #expect(first.first?.surfacedAt == nil)
    }

    @Test("markValidationAdvisoriesSurfaced consumes pending rows and records surfaced_at")
    func markSurfacedConsumesPending() {
        let (db, path) = makeValidationTempDB()
        defer { cleanupValidationDB(path) }
        let sid = db.createSession(projectRoot: "/tmp/project")

        insertAdvisory(db, sessionId: sid)
        db.flushWrites()

        let rows = db.pendingValidationAdvisories(sessionId: sid)
        db.markValidationAdvisoriesSurfaced(ids: rows.map(\.id))
        db.flushWrites()

        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty)
        let stored = db.validationResults(sessionId: sid)
        #expect(stored.count == 1)
        #expect(stored.first?.surfacedAt != nil)
    }

    @Test("clean and dropped attempts are inspectable but never pending")
    func cleanAndDroppedAreNotPending() {
        let (db, path) = makeValidationTempDB()
        defer { cleanupValidationDB(path) }
        let sid = db.createSession(projectRoot: "/tmp/project")

        db.insertValidationResult(
            sessionId: sid,
            filePath: "/tmp/project/OK.swift",
            validatorName: "swiftc",
            category: "syntax",
            exitCode: 0,
            rawOutput: nil,
            advisory: "",
            durationMs: 4
        )
        db.insertValidationResult(
            sessionId: sid,
            filePath: "/tmp/project/Missing.swift",
            validatorName: "swiftc",
            category: "syntax",
            exitCode: -1,
            rawOutput: "spawn failed",
            advisory: "spawn failed",
            durationMs: 1,
            outcome: "dropped",
            reason: "spawn_failed"
        )
        db.flushWrites()

        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty)
        #expect(db.validationResults(sessionId: sid, outcome: "clean").count == 1)
        let dropped = db.validationResults(sessionId: sid, outcome: "dropped")
        #expect(dropped.count == 1)
        #expect(dropped.first?.reason == "spawn_failed")
    }

    @Test("pending query is session-scoped and limited to ten newest advisories")
    func pendingQueryIsScopedAndLimited() {
        let (db, path) = makeValidationTempDB()
        defer { cleanupValidationDB(path) }
        let sid = db.createSession(projectRoot: "/tmp/project")
        let other = db.createSession(projectRoot: "/tmp/project")

        for idx in 0..<12 {
            insertAdvisory(
                db,
                sessionId: sid,
                filePath: "/tmp/project/Broken\(idx).swift",
                advisory: "diagnostic \(idx)"
            )
        }
        insertAdvisory(db, sessionId: other, advisory: "other session")
        db.flushWrites()

        let pending = db.pendingValidationAdvisories(sessionId: sid)
        #expect(pending.count == 10)
        #expect(pending.allSatisfy { $0.advisory != "other session" })
        #expect(db.pendingValidationAdvisories(sessionId: other).count == 1)
    }

    @Test("pruneValidationResults removes only rows older than the cutoff")
    func pruneRemovesOnlyOldRows() {
        let (db, path) = makeValidationTempDB()
        defer { cleanupValidationDB(path) }
        let sid = db.createSession(projectRoot: "/tmp/project")

        insertAdvisory(db, sessionId: sid, filePath: "/tmp/project/Old.swift", advisory: "old")
        insertAdvisory(db, sessionId: sid, filePath: "/tmp/project/Fresh.swift", advisory: "fresh")
        db.flushWrites()
        db.executeRawSQL("""
            UPDATE validation_results
            SET created_at = \(Date().addingTimeInterval(-100_000).timeIntervalSince1970)
            WHERE file_path = '/tmp/project/Old.swift';
            """)

        let pruned = db.pruneValidationResults(olderThanHours: 24)
        let remaining = db.validationResults(sessionId: sid)

        #expect(pruned == 1)
        #expect(remaining.count == 1)
        #expect(remaining.first?.advisory == "fresh")
    }

    @Test("fetchAndMarkDelivered preserves legacy destructive-read behavior")
    func legacyFetchAndMarkDeliveredConsumes() {
        let (db, path) = makeValidationTempDB()
        defer { cleanupValidationDB(path) }
        let sid = db.createSession(projectRoot: "/tmp/project")

        insertAdvisory(db, sessionId: sid)
        db.flushWrites()

        let first = db.fetchAndMarkDelivered(sessionId: sid)
        let second = db.fetchAndMarkDelivered(sessionId: sid)

        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(db.validationResults(sessionId: sid).first?.surfacedAt != nil)
    }
}
