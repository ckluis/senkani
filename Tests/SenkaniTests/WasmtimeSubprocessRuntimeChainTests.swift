import Testing
import Foundation
import SQLite3
@testable import Core

/// T.3a-4 — chained `wasm_kill` row writer + chain integrity tests.
///
/// Two tests:
///   1. `wasmKillRowAppearsInTokenEvents` — call `recordWasmKill` once
///      against a fresh DB; assert one row in `token_events` with
///      `source='wasm_kill'`, `wasm_reason='fuel'`, non-null
///      `wasm_duration_us` / `wasm_budget_delta_us`, and non-null
///      `entry_hash`. Verifies the writer wires the v33 canonical map
///      correctly and the row lands under the post-v33 chain anchor.
///   2. `hundredMixedKillRowsVerifyClean` — write 100 mixed-reason
///      kill rows interleaved with regular `recordTokenEvent` calls;
///      run `ChainVerifier.verifyTokenEvents` and assert `.ok`.
///      Verifies chain hash determinism across mixed event types
///      under the same anchor.
@Suite("WasmtimeSubprocessRuntime — T.3a-4 chained wasm_kill rows")
struct WasmtimeSubprocessRuntimeChainTests {

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-t3a-4-test-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private static func cleanupDB(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-shm")
        try? fm.removeItem(atPath: path + "-wal")
    }

    /// Wait for the parent.queue async write to land. The store's
    /// `recordWasmKill` dispatches onto `parent.queue.async`, so the
    /// caller must `parent.queue.sync` (or a SELECT through the
    /// public API) to flush. The `SessionDatabase` public surface
    /// doesn't expose `queue.sync` directly; we hit it via any
    /// read that goes through the same queue.
    private static func flushQueue(_ db: SessionDatabase) {
        _ = db.tokenEventExists(source: "wasm_kill", feature: "fuel")
    }

    @Test("recordWasmKill writes a row with wasm_* columns + entry_hash populated")
    func wasmKillRowAppearsInTokenEvents() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(path) }

        db.recordWasmKill(
            sessionId: "t3a-4-fuel-test",
            reason: .fuel,
            durationUs: 12345,
            budgetDeltaUs: 2345,
            toolId: "test-tool"
        )
        Self.flushQueue(db)

        // Read back via raw SQLite to inspect the wasm_* columns +
        // entry_hash. Public stats APIs don't surface these columns
        // yet (T.3b-era follow-up wires them into V.18 timeline).
        var rowCount = 0
        var wasmReason: String?
        var wasmDuration: Int64?
        var wasmBudgetDelta: Int64?
        var wasmToolId: String?
        var entryHash: String?
        var source: String?

        let sql = """
            SELECT source, wasm_reason, wasm_duration_us, wasm_budget_delta_us,
                   wasm_tool_id, entry_hash
              FROM token_events
             WHERE source = 'wasm_kill';
        """
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(rawDB, sql, -1, &stmt, nil) == SQLITE_OK else {
                Issue.record("prepare failed")
                return
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                rowCount += 1
                source = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
                wasmReason = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
                    wasmDuration = sqlite3_column_int64(stmt, 2)
                }
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                    wasmBudgetDelta = sqlite3_column_int64(stmt, 3)
                }
                wasmToolId = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                entryHash = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            }
        }

        #expect(rowCount == 1, "expected exactly one wasm_kill row, got \(rowCount)")
        #expect(source == "wasm_kill")
        #expect(wasmReason == "fuel")
        #expect(wasmDuration == 12345)
        #expect(wasmBudgetDelta == 2345)
        #expect(wasmToolId == "test-tool")
        #expect(entryHash != nil && !(entryHash ?? "").isEmpty,
                "entry_hash must be populated for chained rows")
    }

    @Test("100 mixed wasm_kill + token_event rows verify clean via ChainVerifier")
    func hundredMixedKillRowsVerifyClean() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(path) }

        let reasons: [WasmKillReason] = [.fuel, .epoch, .escape, .crash]
        for i in 0..<100 {
            if i.isMultiple(of: 3) {
                // Interleave a regular token_event so the chain
                // covers mixed source types under the same anchor.
                db.recordTokenEvent(
                    sessionId: "t3a-4-chain",
                    paneId: nil,
                    projectRoot: "/tmp/t3a-4-chain",
                    source: "test",
                    toolName: "regular_event",
                    model: nil,
                    inputTokens: 0,
                    outputTokens: 0,
                    savedTokens: 0,
                    costCents: 0,
                    feature: "interleaved-\(i)",
                    command: nil
                )
            } else {
                let reason = reasons[i % reasons.count]
                db.recordWasmKill(
                    sessionId: "t3a-4-chain",
                    reason: reason,
                    durationUs: Int64(1000 + i * 7),
                    budgetDeltaUs: Int64(i * 3),
                    toolId: "kill-\(i)"
                )
            }
        }
        // Flush serial queue.
        Self.flushQueue(db)

        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break
        default:
            Issue.record("expected .ok after 100 mixed wasm_kill + token_event rows, got \(result)")
        }
    }
}

// Test-only convenience: expose a raw-SQLite block on the parent
// queue so chain tests can SELECT directly without going through
// each store's read path. Public APIs cover the bulk of test needs;
// this gap is the wasm_* columns which haven't been wired into
// public stats yet.
extension SessionDatabase {
    func unsafeQueueSync(_ block: (OpaquePointer) -> Void) {
        queue.sync {
            guard let db = self.db else { return }
            block(db)
        }
    }
}
