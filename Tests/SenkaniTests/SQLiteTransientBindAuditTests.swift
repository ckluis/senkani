import Testing
import Foundation
import SQLite3
@testable import Core

/// Single-row chain-verify + tamper-detection coverage for three chained
/// writers across `Sources/Core/Stores/` whose `sqlite3_bind_text` call
/// sites were converted from `SQLITE_STATIC` (nil destructor) to
/// `SQLITE_TRANSIENT_DESTRUCTOR` by the
/// `sqlite-bind-static-dangling-pointer-audit-2026-05-21` round.
///
/// Each test:
///   1. Inserts ONE row via the writer's public API (no other rows in
///      the chain — single-row coverage matches the v22 anchor test's
///      `resultStatusTamperDetected` shape).
///   2. Sanity-checks `ChainVerifier.verifyXxx(db) == .ok` pre-tamper —
///      proves the SQLITE_TRANSIENT-bound TEXT bytes round-trip through
///      the bind/step/read cycle without dangling-pointer corruption.
///   3. Tampers a TEXT column on the inserted row via a secondary
///      sqlite handle (UPDATE).
///   4. Asserts `ChainVerifier.verifyXxx(db)` returns `.brokenAt(_:rowid:_:_:)`
///      naming the tampered row's id — proves the tamper-detection
///      contract still fires on TEXT columns after the conversion.
///
/// Originating finding:
/// `process-gap-validation-results-migration-v22-anchor-pending-2026-05-19`
/// Execution evidence (2026-05-21) — the SQLITE_STATIC bug in the
/// browser-validation writer was caught by the v22 anchor's expanded
/// canonical hash map. The wider pattern existed across ~30 writers;
/// this audit converted all 243 transient bind sites in `Sources/Core/`.
/// These three tests are the per-writer regression guard.
@Suite("SQLITE_TRANSIENT bind audit — single-row tamper detection")
struct SQLiteTransientBindAuditTests {

    private func makeTempDB() -> (SessionDatabase, String) {
        let dir = NSTemporaryDirectory() + "senkani-sqlite-transient-audit-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "senkani.db"
        return (SessionDatabase(path: path), path)
    }

    // MARK: - 1. CommandStore.recordCommand — tamper `command` TEXT

    @Test("commands — single-row tamper of `command` TEXT detected by ChainVerifier")
    func commandStoreToolNameTamperDetected() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Insert one row via the public API. recordCommand commits
        // synchronously on parent.queue (V.5c durability contract,
        // 2026-05-18) so the row is visible immediately.
        let sid = db.createSession()
        db.recordCommand(
            sessionId: sid,
            toolName: "exec",
            command: "echo transient-bind-audit",
            rawBytes: 100,
            compressedBytes: 50
        )
        db.flushWrites()

        // Sanity: chain green pre-tamper. If this fails the
        // SQLITE_TRANSIENT conversion corrupted the bound TEXT bytes.
        let pre = ChainVerifier.verifyCommands(db)
        if case .brokenAt = pre {
            Issue.record("chain broken pre-tamper — SQLITE_TRANSIENT bind regression in CommandStore.recordCommand")
        }

        // Tamper `command` via a secondary handle.
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle for tamper")
            return
        }
        defer { sqlite3_close(handle) }
        // Find the inserted row's id (single row → id is the max).
        var rowid: Int64 = -1
        var selStmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT MAX(id) FROM commands;", -1, &selStmt, nil) == SQLITE_OK {
            if sqlite3_step(selStmt) == SQLITE_ROW {
                rowid = sqlite3_column_int64(selStmt, 0)
            }
            sqlite3_finalize(selStmt)
        }
        #expect(rowid > 0, "expected one row in commands; got max id \(rowid)")

        var stmt: OpaquePointer?
        let updateSQL = "UPDATE commands SET command = 'tampered' WHERE id = ?;"
        guard sqlite3_prepare_v2(handle, updateSQL, -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("failed to prepare UPDATE for commands tamper")
            return
        }
        sqlite3_bind_int64(stmt, 1, rowid)
        let stepRC = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        #expect(stepRC == SQLITE_DONE, "UPDATE step rc=\(stepRC)")

        // Verifier MUST catch the tamper at the tampered row.
        let post = ChainVerifier.verifyCommands(db)
        switch post {
        case .brokenAt(let table, let id, _, _):
            #expect(table == "commands")
            #expect(id == rowid, "expected break at tampered row \(rowid); got \(id)")
        case .ok:
            Issue.record("tamper of commands.command was NOT detected")
        case .noChain:
            Issue.record("no chain to verify (test setup bug)")
        }
    }

    // MARK: - 2. TokenEventStore.recordTokenEvent — tamper `tool_name` TEXT

    @Test("token_events — single-row tamper of `tool_name` TEXT detected by ChainVerifier")
    func tokenEventStoreToolNameTamperDetected() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        db.recordTokenEvent(
            sessionId: "sid-transient-audit",
            paneId: nil,
            projectRoot: nil,
            source: "session_jsonl",
            toolName: "read",
            model: "claude-opus-4-7",
            inputTokens: 1000,
            outputTokens: 200,
            savedTokens: 0,
            costCents: 5,
            feature: nil,
            command: nil
        )
        // recordTokenEvent dispatches async — flush before reading.
        db.flushWrites()

        let pre = ChainVerifier.verifyTokenEvents(db)
        if case .brokenAt = pre {
            Issue.record("chain broken pre-tamper — SQLITE_TRANSIENT bind regression in TokenEventStore.recordTokenEvent")
        }

        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle for tamper")
            return
        }
        defer { sqlite3_close(handle) }

        var rowid: Int64 = -1
        var selStmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT MAX(id) FROM token_events;", -1, &selStmt, nil) == SQLITE_OK {
            if sqlite3_step(selStmt) == SQLITE_ROW {
                rowid = sqlite3_column_int64(selStmt, 0)
            }
            sqlite3_finalize(selStmt)
        }
        #expect(rowid > 0, "expected one row in token_events; got max id \(rowid)")

        var stmt: OpaquePointer?
        let updateSQL = "UPDATE token_events SET tool_name = 'tampered' WHERE id = ?;"
        guard sqlite3_prepare_v2(handle, updateSQL, -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("failed to prepare UPDATE for token_events tamper")
            return
        }
        sqlite3_bind_int64(stmt, 1, rowid)
        let stepRC = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        #expect(stepRC == SQLITE_DONE, "UPDATE step rc=\(stepRC)")

        let post = ChainVerifier.verifyTokenEvents(db)
        switch post {
        case .brokenAt(let table, let id, _, _):
            #expect(table == "token_events")
            #expect(id == rowid, "expected break at tampered row \(rowid); got \(id)")
        case .ok:
            Issue.record("tamper of token_events.tool_name was NOT detected")
        case .noChain:
            Issue.record("no chain to verify (test setup bug)")
        }
    }

    // MARK: - 3. EvalResultsStore.record — tamper `fixture_id` TEXT

    @Test("eval_results — single-row tamper of `fixture_id` TEXT detected by ChainVerifier")
    func evalResultsStoreFixtureIdTamperDetected() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let ok = db.recordEvalResult(
            modelId: "phi-3-mini",
            fixtureId: "fixture-pii-masking-001",
            precision: 0.93,
            recall: 0.89,
            f1: 0.91,
            durationMs: 42
        )
        #expect(ok, "recordEvalResult must succeed for the audit test")

        let pre = ChainVerifier.verifyEvalResults(db)
        if case .brokenAt = pre {
            Issue.record("chain broken pre-tamper — SQLITE_TRANSIENT bind regression in EvalResultsStore.record")
        }

        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle for tamper")
            return
        }
        defer { sqlite3_close(handle) }

        var rowid: Int64 = -1
        var selStmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT MAX(id) FROM eval_results;", -1, &selStmt, nil) == SQLITE_OK {
            if sqlite3_step(selStmt) == SQLITE_ROW {
                rowid = sqlite3_column_int64(selStmt, 0)
            }
            sqlite3_finalize(selStmt)
        }
        #expect(rowid > 0, "expected one row in eval_results; got max id \(rowid)")

        var stmt: OpaquePointer?
        let updateSQL = "UPDATE eval_results SET fixture_id = 'tampered-fixture' WHERE id = ?;"
        guard sqlite3_prepare_v2(handle, updateSQL, -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("failed to prepare UPDATE for eval_results tamper")
            return
        }
        sqlite3_bind_int64(stmt, 1, rowid)
        let stepRC = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        #expect(stepRC == SQLITE_DONE, "UPDATE step rc=\(stepRC)")

        let post = ChainVerifier.verifyEvalResults(db)
        switch post {
        case .brokenAt(let table, let id, _, _):
            #expect(table == "eval_results")
            #expect(id == rowid, "expected break at tampered row \(rowid); got \(id)")
        case .ok:
            Issue.record("tamper of eval_results.fixture_id was NOT detected")
        case .noChain:
            Issue.record("no chain to verify (test setup bug)")
        }
    }
}
