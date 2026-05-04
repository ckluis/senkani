import Testing
import Foundation
@testable import Core

// Closes the gap tracked in `cleanup-19-sessiondatabase-store-coverage-gaps-file`.
// Two cross-store composition methods on the SessionDatabase façade —
// `lastExecResult` and `complianceRate` — were exercised only indirectly
// through MCP/hook flows. These tests pin: project_root isolation, the
// numerator filter / preview-match window, and the empty-data nil return.

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-cross-store-\(UUID().uuidString).sqlite"
    return (SessionDatabase(path: path), path)
}

private func cleanupDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

// MARK: - lastExecResult

@Suite("SessionDatabase — lastExecResult cross-store join")
struct SessionDatabaseLastExecResultTests {

    @Test func returnsTimestampAndPreviewWhenBothStoresAgree() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        db.recordTokenEvent(
            sessionId: "s1", paneId: nil, projectRoot: "/tmp/lex-A",
            source: "mcp_tool", toolName: "exec", model: nil,
            inputTokens: 10, outputTokens: 5, savedTokens: 5,
            costCents: 0, feature: "exec", command: "echo hi"
        )
        db.recordCommand(
            sessionId: "s1", toolName: "exec", command: "echo hi",
            rawBytes: 6, compressedBytes: 6, outputPreview: "hi\n"
        )
        db.flushWrites()

        let result = db.lastExecResult(command: "echo hi", projectRoot: "/tmp/lex-A")
        #expect(result != nil, "Both stores wrote — full tuple expected")
        #expect(result?.outputPreview == "hi\n", "Preview comes from commands table")
    }

    @Test func projectIsolationDoesNotLeakAcrossRoots() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        // Same command string in two projects.
        db.recordTokenEvent(
            sessionId: "sA", paneId: nil, projectRoot: "/tmp/lex-A",
            source: "mcp_tool", toolName: "exec", model: nil,
            inputTokens: 1, outputTokens: 1, savedTokens: 0,
            costCents: 0, feature: "exec", command: "ls"
        )
        db.recordTokenEvent(
            sessionId: "sB", paneId: nil, projectRoot: "/tmp/lex-B",
            source: "mcp_tool", toolName: "exec", model: nil,
            inputTokens: 1, outputTokens: 1, savedTokens: 0,
            costCents: 0, feature: "exec", command: "ls"
        )
        db.flushWrites()

        // Querying project A must not surface project B's exec, even though
        // the command string is identical. token_events is the timestamp source
        // and is project-scoped; the SQL relies on that filter.
        let resultA = db.lastExecResult(command: "ls", projectRoot: "/tmp/lex-A")
        let resultB = db.lastExecResult(command: "ls", projectRoot: "/tmp/lex-B")
        let resultC = db.lastExecResult(command: "ls", projectRoot: "/tmp/lex-C")

        #expect(resultA != nil, "project A has the exec — should match")
        #expect(resultB != nil, "project B has the exec — should match")
        #expect(resultC == nil, "project C has no exec — should be nil")
    }

    @Test func returnsNilWhenNoExecMatches() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        // A read event for an unrelated tool — must not surface as exec.
        db.recordTokenEvent(
            sessionId: "s1", paneId: nil, projectRoot: "/tmp/lex-D",
            source: "mcp_tool", toolName: "read", model: nil,
            inputTokens: 1, outputTokens: 1, savedTokens: 0,
            costCents: 0, feature: "read", command: "Sources/main.swift"
        )
        db.flushWrites()

        #expect(db.lastExecResult(command: "echo hi", projectRoot: "/tmp/lex-D") == nil)
    }

    @Test func returnsTimestampWithNilPreviewWhenCommandsRowAbsent() {
        // Pins the contract: the preview-match window is independent of the
        // timestamp source. If token_events has the exec but commands lacks a
        // matching row (or it is outside the ±2s window), the function still
        // returns the timestamp, with preview = nil.
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        db.recordTokenEvent(
            sessionId: "s1", paneId: nil, projectRoot: "/tmp/lex-E",
            source: "mcp_tool", toolName: "exec", model: nil,
            inputTokens: 1, outputTokens: 1, savedTokens: 0,
            costCents: 0, feature: "exec", command: "uname"
        )
        // Deliberately do NOT call recordCommand for "uname" — the join's
        // preview half should miss while the timestamp half hits.
        db.flushWrites()

        let result = db.lastExecResult(command: "uname", projectRoot: "/tmp/lex-E")
        #expect(result != nil, "Timestamp half (token_events) has the row")
        #expect(result?.outputPreview == nil, "Preview half (commands) has no matching row")
    }
}

// MARK: - complianceRate

@Suite("SessionDatabase — complianceRate cross-store ratio")
struct SessionDatabaseComplianceRateTests {

    @Test func numeratorCountsHookAndMcpSourcesOnly() {
        // Pins the SQL filter `(source = 'mcp' OR source = 'hook')` against
        // a non-senkani source ('claude'). One hook event, one claude event
        // → ratio = 0.5.
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        db.recordTokenEvent(
            sessionId: "s1", paneId: nil, projectRoot: "/tmp/cr-A",
            source: "hook", toolName: "Read", model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0,
            costCents: 0, feature: "PostToolUse", command: nil
        )
        db.recordTokenEvent(
            sessionId: "s1", paneId: nil, projectRoot: "/tmp/cr-A",
            source: "claude", toolName: "Read", model: nil,
            inputTokens: 100, outputTokens: 50, savedTokens: 0,
            costCents: 1, feature: "Read", command: nil
        )
        db.flushWrites()

        let rate = db.complianceRate(projectRoot: "/tmp/cr-A")
        #expect(rate != nil)
        #expect(abs((rate ?? 0) - 0.5) < 0.001, "1 hook / (1 hook + 1 claude) = 0.5")
    }

    @Test func projectIsolationDoesNotLeakAcrossRoots() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        // project-A: 1 hook, 0 non-senkani → 1.0
        db.recordTokenEvent(
            sessionId: "sA", paneId: nil, projectRoot: "/tmp/cr-A",
            source: "hook", toolName: "Read", model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0,
            costCents: 0, feature: "PostToolUse", command: nil
        )
        // project-B: 0 hook, 1 claude → 0.0
        db.recordTokenEvent(
            sessionId: "sB", paneId: nil, projectRoot: "/tmp/cr-B",
            source: "claude", toolName: "Read", model: nil,
            inputTokens: 100, outputTokens: 50, savedTokens: 0,
            costCents: 1, feature: "Read", command: nil
        )
        db.flushWrites()

        let rateA = db.complianceRate(projectRoot: "/tmp/cr-A")
        let rateB = db.complianceRate(projectRoot: "/tmp/cr-B")

        #expect(rateA != nil)
        #expect(abs((rateA ?? 0) - 1.0) < 0.001,
                "project A — only its hook event counts; project B's claude must not leak in")
        #expect(rateB != nil)
        #expect(abs((rateB ?? 0) - 0.0) < 0.001,
                "project B — its claude event must not be counted as senkani")
    }

    @Test func returnsNilWhenNoEventsForProject() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        // Write events for a different project — querying our target project
        // should still see zero rows and return nil (the empty-data sentinel).
        db.recordTokenEvent(
            sessionId: "sX", paneId: nil, projectRoot: "/tmp/cr-other",
            source: "hook", toolName: "Read", model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0,
            costCents: 0, feature: "PostToolUse", command: nil
        )
        db.flushWrites()

        #expect(db.complianceRate(projectRoot: "/tmp/cr-empty") == nil)
    }
}
