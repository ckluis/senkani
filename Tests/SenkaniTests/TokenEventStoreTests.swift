import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-tokeneventstore-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupTempDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

/// The store's write path is queue.async; force a sync read through the
/// serial queue to flush pending writes before asserting.
private func flush(_ db: SessionDatabase) {
    _ = db.tokenStatsAllProjects()
}

// MARK: - Tests

@Suite("TokenEventStore — writes, reads, cursors, prune")
struct TokenEventStoreTests {

    @Test func recordTokenEventPersistsAllFields() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj")
        db.recordTokenEvent(
            sessionId: sid,
            paneId: "pane-A",
            projectRoot: "/tmp/proj",
            source: "mcp_tool",
            toolName: "read",
            model: "claude",
            inputTokens: 1_000,
            outputTokens: 200,
            savedTokens: 800,
            costCents: 5,
            feature: "read",
            command: "/tmp/proj/README.md"
        )
        flush(db)

        let stats = db.tokenStatsForProject("/tmp/proj")
        #expect(stats.inputTokens == 1_000, "input tokens persisted")
        #expect(stats.outputTokens == 200, "output tokens persisted")
        #expect(stats.savedTokens == 800, "saved tokens persisted")
        #expect(stats.costCents == 5, "cost cents persisted")
        #expect(stats.commandCount == 1, "one event counted")
    }

    @Test func recordHookEventLandsInTokenEventsWithHookSource() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj")
        db.recordHookEvent(
            sessionId: sid,
            toolName: "Read",
            eventType: "PreToolUse",
            projectRoot: "/tmp/proj"
        )
        flush(db)

        let events = db.recentTokenEvents(projectRoot: "/tmp/proj", limit: 10)
        #expect(events.count == 1, "hook event surfaces via token_events API")
        #expect(events.first?.source == "hook", "source=hook (no separate hook_events table)")
        #expect(events.first?.feature == "PreToolUse", "eventType persisted in feature column")
        #expect(events.first?.toolName == "Read", "toolName persisted")
    }

    @Test func tokenStatsForProjectAggregatesAcrossEvents() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj")
        for _ in 0..<3 {
            db.recordTokenEvent(
                sessionId: sid, paneId: nil, projectRoot: "/tmp/proj",
                source: "mcp_tool", toolName: "read", model: nil,
                inputTokens: 100, outputTokens: 50, savedTokens: 80,
                costCents: 1, feature: "read", command: nil
            )
        }
        flush(db)

        let stats = db.tokenStatsForProject("/tmp/proj")
        #expect(stats.commandCount == 3, "three events counted")
        #expect(stats.inputTokens == 300, "sum of inputs")
        #expect(stats.savedTokens == 240, "sum of saved tokens")
    }

    @Test func tokenStatsByFeatureSortsBySavedDescending() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj")
        db.recordTokenEvent(
            sessionId: sid, paneId: nil, projectRoot: "/tmp/proj",
            source: "mcp_tool", toolName: "read", model: nil,
            inputTokens: 100, outputTokens: 0, savedTokens: 100,
            costCents: 0, feature: "read", command: nil
        )
        db.recordTokenEvent(
            sessionId: sid, paneId: nil, projectRoot: "/tmp/proj",
            source: "mcp_tool", toolName: "exec", model: nil,
            inputTokens: 500, outputTokens: 0, savedTokens: 400,
            costCents: 0, feature: "exec", command: nil
        )
        flush(db)

        let rows = db.tokenStatsByFeature(projectRoot: "/tmp/proj")
        #expect(rows.count == 2, "two feature rows")
        #expect(rows.first?.feature == "exec", "highest saved first")
        #expect(rows.first?.savedTokens == 400)
        #expect(rows.last?.feature == "read")
    }

    @Test func liveSessionMultiplierReturnsNilWithoutData() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let m = db.liveSessionMultiplier(projectRoot: "/tmp/nothing")
        #expect(m == nil, "no events → nil multiplier")
    }

    @Test func liveSessionMultiplierComputesRawOverCompressed() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj")
        // input=200, saved=800 → raw=1000, compressed=200 → 5.0x
        db.recordTokenEvent(
            sessionId: sid, paneId: nil, projectRoot: "/tmp/proj",
            source: "mcp_tool", toolName: "read", model: nil,
            inputTokens: 200, outputTokens: 0, savedTokens: 800,
            costCents: 0, feature: "read", command: nil
        )
        flush(db)

        let m = db.liveSessionMultiplier(projectRoot: "/tmp/proj")
        #expect(m != nil, "multiplier available")
        #expect(abs((m ?? 0) - 5.0) < 0.001, "multiplier = (input+saved)/input = 1000/200 = 5.0")
    }

    @Test func hotFilesRanksByFrequency() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj")
        // /hot read 3x, /cold read 1x
        for _ in 0..<3 {
            db.recordTokenEvent(
                sessionId: sid, paneId: nil, projectRoot: "/tmp/proj",
                source: "mcp_tool", toolName: "read", model: nil,
                inputTokens: 10, outputTokens: 0, savedTokens: 5,
                costCents: 0, feature: "read", command: "/tmp/proj/hot.swift"
            )
        }
        db.recordTokenEvent(
            sessionId: sid, paneId: nil, projectRoot: "/tmp/proj",
            source: "mcp_tool", toolName: "read", model: nil,
            inputTokens: 10, outputTokens: 0, savedTokens: 5,
            costCents: 0, feature: "read", command: "/tmp/proj/cold.swift"
        )
        flush(db)

        let rows = db.hotFiles(projectRoot: "/tmp/proj")
        #expect(rows.count == 2, "two distinct files")
        #expect(rows.first?.path == "/tmp/proj/hot.swift", "hot first")
        #expect(rows.first?.freq == 3, "three reads counted")
    }

    @Test func sessionCursorUpsertsOnConflict() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let p = "/tmp/proj/session.jsonl"
        #expect(db.getSessionCursor(path: p) == (0, 0), "new path → (0, 0)")

        db.setSessionCursor(path: p, byteOffset: 512, turnIndex: 3)
        flush(db)
        let first = db.getSessionCursor(path: p)
        #expect(first.byteOffset == 512)
        #expect(first.turnIndex == 3)

        // Upsert — same path, new values
        db.setSessionCursor(path: p, byteOffset: 1024, turnIndex: 7)
        flush(db)
        let second = db.getSessionCursor(path: p)
        #expect(second.byteOffset == 1024, "upsert replaced byte_offset")
        #expect(second.turnIndex == 7, "upsert replaced turn_index")
    }

    @Test func pruneTokenEventsRemovesOldRows() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj")
        db.recordTokenEvent(
            sessionId: sid, paneId: nil, projectRoot: "/tmp/proj",
            source: "mcp_tool", toolName: "read", model: nil,
            inputTokens: 1, outputTokens: 0, savedTokens: 0,
            costCents: 0, feature: "read", command: nil
        )
        flush(db)

        // Backdate the one row to 100 days ago.
        let oldTs = Date().addingTimeInterval(-100 * 86400).timeIntervalSince1970
        db.executeRawSQL("UPDATE token_events SET timestamp = \(oldTs);")

        let pruned = db.pruneTokenEvents(olderThanDays: 90)
        #expect(pruned == 1, "one row pruned at 90-day cutoff")

        let stats = db.tokenStatsForProject("/tmp/proj")
        #expect(stats.commandCount == 0, "row gone from token_events")
    }
}
