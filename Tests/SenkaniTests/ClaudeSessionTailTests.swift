import Testing
import Foundation
@testable import Core

// Helpers — local to this suite to avoid cross-file dependencies on
// AgentTrackingTests' private makeTempDB.
private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-tail-test-\(UUID().uuidString)/senkani.db"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: dir)
}

private func makeAssistantUsageLine(sessionId: String, input: Int = 100, output: Int = 50,
                                    cacheRead: Int = 10) -> String {
    let usage = #"{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":0}"#
    return #"{"type":"assistant","timestamp":"2026-05-15T00:00:00.000Z","sessionId":"\#(sessionId)","message":{"usage":\#(usage),"model":"claude-sonnet-4-6"}}"#
}

@Suite("ClaudeSessionTail — restart-safe cursor tail")
struct ClaudeSessionTailTests {

    /// Acceptance bullet 4: synthesize JSONL lines, run "watcher" (tail) to
    /// drain, query token_events, then re-invoke tail on the same file and
    /// assert count unchanged. The cursor stops historical re-emission on a
    /// "restart" (= second tail invocation against the same DB-backed cursor).
    @Test func secondTailReadDoesNotReEmitHistorical() throws {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(path: dbPath) }

        let dir = "/tmp/senkani-tail-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jsonlPath = dir + "/session-1.jsonl"

        let probeSession = "probe-\(UUID().uuidString)"
        let lines = (0..<50).map { _ in makeAssistantUsageLine(sessionId: probeSession) }
        try (lines.joined(separator: "\n") + "\n").write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let projectRoot = "/tmp/test-project-\(UUID().uuidString)"
        let paneId = UUID().uuidString

        let result1 = ClaudeSessionTail.tail(path: jsonlPath, projectRoot: projectRoot,
                                              paneId: paneId, db: db)
        #expect(result1.eventsEmitted == 50, "first read should emit all 50 lines")

        // Flush the async cursor write + token-event writes via a sync read.
        _ = db.tokenStatsAllProjects()
        let count1 = db.tokenStatsForProject(projectRoot).commandCount
        #expect(count1 == 50, "expected 50 token_events rows for project, got \(count1)")

        // Second tail invocation simulates an app restart. The cursor in
        // claude_session_cursors should drive offset = EOF, emitting 0 rows.
        let result2 = ClaudeSessionTail.tail(path: jsonlPath, projectRoot: projectRoot,
                                              paneId: paneId, db: db)
        #expect(result2.eventsEmitted == 0, "second read must not re-emit historical lines (got \(result2.eventsEmitted))")

        _ = db.tokenStatsAllProjects()
        let count2 = db.tokenStatsForProject(projectRoot).commandCount
        #expect(count2 == 50, "row count must stay at 50 after second read (got \(count2))")
    }

    /// Acceptance bullet 5: after first drain, append more lines. Second
    /// invocation reads only the suffix — assert exact count = old + appended.
    @Test func suffixOnlyReReadAfterAppend() throws {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(path: dbPath) }

        let dir = "/tmp/senkani-tail-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jsonlPath = dir + "/session-1.jsonl"

        let probeSession = "probe-\(UUID().uuidString)"
        let firstBatch = (0..<50).map { _ in makeAssistantUsageLine(sessionId: probeSession) }
        try (firstBatch.joined(separator: "\n") + "\n").write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let projectRoot = "/tmp/test-project-\(UUID().uuidString)"
        let paneId = UUID().uuidString

        let result1 = ClaudeSessionTail.tail(path: jsonlPath, projectRoot: projectRoot,
                                              paneId: paneId, db: db)
        #expect(result1.eventsEmitted == 50)

        // Append 10 more lines to the same file.
        let appendBatch = (0..<10).map { _ in makeAssistantUsageLine(sessionId: probeSession) }
        let appendText = appendBatch.joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: jsonlPath))
        try handle.seekToEnd()
        if let appendData = appendText.data(using: .utf8) {
            try handle.write(contentsOf: appendData)
        }
        try handle.close()

        let result2 = ClaudeSessionTail.tail(path: jsonlPath, projectRoot: projectRoot,
                                              paneId: paneId, db: db)
        #expect(result2.eventsEmitted == 10, "expected suffix-only read of 10 lines, got \(result2.eventsEmitted)")

        _ = db.tokenStatsAllProjects()
        let count = db.tokenStatsForProject(projectRoot).commandCount
        #expect(count == 60, "row count must be 60 (50 + 10), got \(count)")
    }

    /// Cursor beyond EOF (file truncated/rotated under us) resets to 0 and
    /// re-reads the new contents. Validates the diagnostic path that logs
    /// `claude_session_tail.cursor_beyond_eof`.
    @Test func cursorBeyondEOFResetsToBeginning() throws {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(path: dbPath) }

        let dir = "/tmp/senkani-tail-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jsonlPath = dir + "/session-1.jsonl"

        let probeSession = "probe-\(UUID().uuidString)"
        // Pre-seed the cursor at offset 10_000 to simulate a prior read on
        // a much longer file that has since been replaced by a shorter one.
        db.setSessionCursor(path: jsonlPath, byteOffset: 10_000, turnIndex: 0, reader: "watcher")
        _ = db.tokenStatsAllProjects()

        let lines = (0..<5).map { _ in makeAssistantUsageLine(sessionId: probeSession) }
        try (lines.joined(separator: "\n") + "\n").write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let projectRoot = "/tmp/test-project-\(UUID().uuidString)"
        let paneId = UUID().uuidString

        let result = ClaudeSessionTail.tail(path: jsonlPath, projectRoot: projectRoot,
                                             paneId: paneId, db: db)
        #expect(result.resetFromBeginning, "expected cursor-beyond-eof reset path")
        #expect(result.eventsEmitted == 5, "expected re-read of full 5 lines after reset, got \(result.eventsEmitted)")
    }
}
