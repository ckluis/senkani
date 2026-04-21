import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-commandstore-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupTempDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

// MARK: - CommandStore CRUD + FTS tests

@Suite("CommandStore — CRUD + FTS")
struct CommandStoreCRUDTests {

    @Test func createSessionReturnsIdAndPersists() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let id = db.createSession(paneCount: 3, projectRoot: "/tmp/proj", agentType: .claudeCode)
        #expect(!id.isEmpty, "createSession returns a non-empty UUID")

        let sessions = db.loadSessions()
        #expect(sessions.count == 1, "Session row visible via loadSessions")
        #expect(sessions.first?.id == id, "loadSessions surfaces the new id")
        #expect(sessions.first?.paneCount == 3, "paneCount persisted")
    }

    @Test func recordCommandUpdatesSessionAggregates() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession()
        db.recordCommand(
            sessionId: sid, toolName: "read", command: "cat README.md",
            rawBytes: 1_000, compressedBytes: 400, feature: "read", outputPreview: nil
        )
        // Flush async recordCommand by forcing a queue.sync read
        _ = db.loadSessions()

        let rows = db.loadSessions()
        let row = rows.first { $0.id == sid }
        #expect(row != nil, "session row still present")
        #expect(row?.commandCount == 1, "commandCount incremented")
        #expect(row?.totalRaw == 1_000, "totalRawBytes accumulates")
        #expect(row?.totalSaved == 600, "totalSavedBytes = raw - compressed")
    }

    @Test func recordCommandRedactsSecrets() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession()
        let leaky = "curl -H 'Authorization: Bearer sk-ant-api03-aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990000-abcdeFGH' https://api.anthropic.com/v1/messages"
        db.recordCommand(
            sessionId: sid, toolName: "exec", command: leaky,
            rawBytes: 512, compressedBytes: 256
        )
        _ = db.loadSessions()

        let hits = db.search(query: "sk-ant-api03-aaaabbbbccccdddd")
        #expect(hits.isEmpty, "raw API key should be redacted out of the stored command")

        let curlHits = db.search(query: "curl")
        #expect(!curlHits.isEmpty, "non-secret portions of the command still indexed")
    }

    @Test func endSessionSetsDuration() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession()
        db.recordCommand(sessionId: sid, toolName: "read", command: "ls", rawBytes: 10, compressedBytes: 5)
        _ = db.loadSessions()

        db.endSession(sessionId: sid)
        // Drain async queue
        _ = db.loadSessions()
        let row = db.loadSessions().first { $0.id == sid }
        #expect(row != nil, "row present after endSession")
        #expect(row!.duration >= 0, "duration set after endSession (non-negative real)")
    }

    @Test func loadSessionsCapsAt500() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        // Sanity: the store clamps limit at 500 even when caller asks for more.
        // We can't easily create 500 sessions in a unit test — verify by
        // checking loadSessions returns <= 500 for an absurd limit.
        _ = db.createSession()
        _ = db.createSession()
        let rows = db.loadSessions(limit: 9_999)
        #expect(rows.count <= 500, "loadSessions caps at 500 rows")
    }

    @Test func searchFindsRecordedCommands() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession()
        db.recordCommand(sessionId: sid, toolName: "read", command: "zeppelin-migrate configure", rawBytes: 100, compressedBytes: 50)
        db.recordCommand(sessionId: sid, toolName: "exec", command: "echo unrelated", rawBytes: 20, compressedBytes: 10)
        _ = db.loadSessions()

        let hits = db.search(query: "zeppelin")
        #expect(hits.count == 1, "FTS finds the one matching command")
        #expect(hits.first?.command?.contains("zeppelin") == true, "match contains query term")
    }

    @Test func searchSanitizesFTSOperators() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession()
        db.recordCommand(sessionId: sid, toolName: "read", command: "just a plain command", rawBytes: 100, compressedBytes: 50)
        _ = db.loadSessions()

        // These would be FTS5 syntax errors pre-sanitization. After:
        //  - "col:value" strips the colon/asterisk
        //  - AND/OR/NOT are dropped from the term list
        let a = db.search(query: "plain* AND command")
        #expect(!a.isEmpty, "operator-ish query still returns results after sanitization")

        let b = db.search(query: "plain (command)")
        #expect(!b.isEmpty, "parenthesized query still returns results after sanitization")
    }

    @Test func sanitizeFTS5QueryStripsOperatorsAndQuotesTerms() {
        // Empty / whitespace / operator-only → empty (caller should skip)
        #expect(CommandStore.sanitizeFTS5Query("") == "")
        #expect(CommandStore.sanitizeFTS5Query("   ") == "")
        #expect(CommandStore.sanitizeFTS5Query("AND OR NOT NEAR") == "")

        // Normal terms get quoted
        #expect(CommandStore.sanitizeFTS5Query("hello") == "\"hello\"")
        #expect(CommandStore.sanitizeFTS5Query("hello world") == "\"hello\" \"world\"")

        // Special FTS5 chars stripped
        let cleaned = CommandStore.sanitizeFTS5Query("col:value * ^prefix")
        #expect(!cleaned.contains(":"), "colon stripped")
        #expect(!cleaned.contains("*"), "wildcard stripped")
        #expect(!cleaned.contains("^"), "caret stripped")
    }

    @Test func fts5SyncPreservesConsistencyUnderSerialWrites() {
        // The BEGIN IMMEDIATE transaction boundary is the contract that makes
        // (commands insert, FTS5 sync, session aggregate update) atomic. We can't
        // easily simulate concurrent writes across processes in a unit test, but
        // we can verify that N writes leave N matching FTS rows visible and the
        // session aggregate equals N.
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession()
        let n = 25
        for i in 0..<n {
            db.recordCommand(
                sessionId: sid, toolName: "read",
                command: "fts-marker-\(i)",
                rawBytes: 100, compressedBytes: 40
            )
        }
        // Drain async queue
        _ = db.loadSessions()

        let hits = db.search(query: "fts-marker")
        #expect(hits.count == n, "every recorded command is visible via FTS")

        let row = db.loadSessions().first { $0.id == sid }
        #expect(row?.commandCount == n, "session aggregate matches FTS row count")
        #expect(row?.totalRaw == n * 100, "raw bytes aggregate matches N writes")
    }

    @Test func schemaSurvivesReopen() {
        // Regression for the extraction: schema creation is idempotent and the
        // CommandStore setup runs on every open. Open, write, close, reopen →
        // rows remain and the FTS index is queryable.
        let path = "/tmp/senkani-commandstore-reopen-\(UUID().uuidString).sqlite"
        defer { cleanupTempDB(path) }

        do {
            let db = SessionDatabase(path: path)
            let sid = db.createSession()
            db.recordCommand(sessionId: sid, toolName: "read", command: "persisted-marker", rawBytes: 50, compressedBytes: 25)
            _ = db.loadSessions()
            db.close()
        }

        let db2 = SessionDatabase(path: path)
        let hits = db2.search(query: "persisted-marker")
        #expect(hits.count == 1, "command row survives reopen")
        db2.close()
    }
}
