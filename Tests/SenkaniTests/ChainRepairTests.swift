import Testing
import Foundation
import SQLite3
@testable import Core

@Suite("ChainRepairer — T.5 round 4")
struct ChainRepairTests {

    // MARK: - Helpers

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-chain-repair-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func cleanup(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }

    private static func record(_ db: SessionDatabase, _ tag: String) {
        db.recordTokenEvent(
            sessionId: "s",
            paneId: nil,
            projectRoot: "/tmp/senkani-chain-repair",
            source: "mcp_tool",
            toolName: tag,
            model: nil,
            inputTokens: 100,
            outputTokens: 50,
            savedTokens: 50,
            costCents: 1,
            feature: nil,
            command: nil
        )
        db.flushWrites()
    }

    private static func tamper(_ path: String, table: String, where_: String, set: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "tamper", code: 1) }
        defer { sqlite3_close(db) }
        let sql = "UPDATE \(table) SET \(set) WHERE \(where_);"
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let err { sqlite3_free(err) }
            throw NSError(domain: "tamper", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // MARK: - Tests

    @Test("Repair refuses an unsupported table")
    func unsupportedTableRejected() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        do {
            _ = try db.repairChain(table: "sandboxed_results", fromRowid: 1, force: true)
            Issue.record("expected unsupportedTable, got success")
        } catch let error as ChainRepairer.RepairError {
            switch error {
            case .unsupportedTable:
                break
            default:
                Issue.record("expected unsupportedTable, got \(error)")
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("Repair refuses a fromRowid past the table's max id")
    func fromRowidOutOfRange() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        Self.record(db, "first")
        // Only one row exists; --from-rowid 999 should be rejected.
        do {
            _ = try db.repairChain(table: "token_events", fromRowid: 999, force: true)
            Issue.record("expected fromRowidOutOfRange, got success")
        } catch let error as ChainRepairer.RepairError {
            switch error {
            case .fromRowidOutOfRange:
                break
            default:
                Issue.record("expected fromRowidOutOfRange, got \(error)")
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("Repair after tamper: pre-segment OK, post-segment OK after a fresh write")
    func repairSegmentsBothVerify() throws {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        for i in 0..<5 { Self.record(db, "t-\(i)") }
        // Tamper row 3.
        try Self.tamper(path, table: "token_events", where_: "id = 3", set: "tool_name = 'tampered'")

        // Verify catches the tamper.
        let preRepair = ChainVerifier.verifyTokenEvents(db)
        guard case .brokenAt(_, let rowid, _, _) = preRepair else {
            Issue.record("expected brokenAt, got \(preRepair)")
            return
        }
        #expect(rowid == 3)

        // Repair from rowid 3.
        let outcome = try db.repairChain(table: "token_events", fromRowid: 3, force: true)
        #expect(outcome.table == "token_events")
        #expect(outcome.fromRowid == 3)
        #expect(outcome.rowsRebound == 3)  // rows 3, 4, 5

        // Write more data — the new segment grows.
        Self.record(db, "post-repair-1")
        Self.record(db, "post-repair-2")

        // Verify must be OK now: the prior segment (rows 1, 2) verifies
        // against its old anchor; rows 3, 4, 5 are anchor-from-now under
        // the new anchor (NULL hashes — verifier skips them); post-repair
        // rows verify under the new anchor.
        let postRepair = ChainVerifier.verifyTokenEvents(db)
        guard case .ok(_, let repairs) = postRepair else {
            Issue.record("expected .ok, got \(postRepair)")
            return
        }
        #expect(repairs == 1)
    }

    @Test("totalRepairCount reflects every repair anchor across all tables")
    func totalRepairCountAcrossTables() throws {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        Self.record(db, "t-1")
        Self.record(db, "t-2")
        let sid = db.createSession(paneCount: 1, projectRoot: "/tmp/senkani-chain-repair", agentType: nil)
        db.recordCommand(sessionId: sid, toolName: "Read", command: "/tmp/x.swift", rawBytes: 100, compressedBytes: 50)
        db.recordCommand(sessionId: sid, toolName: "Read", command: "/tmp/y.swift", rawBytes: 200, compressedBytes: 100)
        db.flushWrites()

        #expect(db.totalRepairCount() == 0)

        _ = try db.repairChain(table: "token_events", fromRowid: 2, force: true)
        #expect(db.totalRepairCount() == 1)

        _ = try db.repairChain(table: "commands", fromRowid: 2, force: true)
        #expect(db.totalRepairCount() == 2)
    }

    @Test("Idempotency guard: second repair without --force is rejected when prior anchor is repair-*")
    func secondRepairRequiresForce() throws {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        for i in 0..<3 { Self.record(db, "t-\(i)") }

        _ = try db.repairChain(table: "token_events", fromRowid: 2, force: true)

        // Second repair without --force should refuse — last anchor is now
        // a repair anchor.
        do {
            _ = try db.repairChain(table: "token_events", fromRowid: 2, force: false)
            Issue.record("expected repairAnchorAlreadyExists, got success")
        } catch let error as ChainRepairer.RepairError {
            switch error {
            case .repairAnchorAlreadyExists:
                break
            default:
                Issue.record("expected repairAnchorAlreadyExists, got \(error)")
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }

        // Same call WITH --force succeeds.
        let outcome = try db.repairChain(table: "token_events", fromRowid: 2, force: true)
        #expect(outcome.fromRowid == 2)
    }

    @Test("Repair anchor records prior tip hash in operator_note")
    func priorTipRecorded() throws {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        Self.record(db, "first")
        Self.record(db, "second")
        Self.record(db, "third")

        let outcome = try db.repairChain(
            table: "token_events",
            fromRowid: 2,
            operatorNote: "investigating SIGTRAP",
            force: true
        )

        // outcome.priorTipHash matches what was at id=3 (the tip of the
        // pre-repair chain).
        #expect(outcome.priorTipHash != nil)
        #expect(outcome.priorTipHash!.count == 64)

        // Read back the new anchor's operator_note: must contain prior_tip=
        // and the user-supplied note.
        var rdb: OpaquePointer?
        try #require(sqlite3_open(path, &rdb) == SQLITE_OK)
        defer { sqlite3_close(rdb) }
        var stmt: OpaquePointer?
        let sql = "SELECT operator_note FROM chain_anchors WHERE id = ?;"
        try #require(sqlite3_prepare_v2(rdb, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, outcome.newAnchorId)
        try #require(sqlite3_step(stmt) == SQLITE_ROW)
        let note = String(cString: sqlite3_column_text(stmt, 0))
        #expect(note.contains("prior_tip="))
        #expect(note.contains("investigating SIGTRAP"))
    }

    @Test("Repair with a fresh write afterward verifies, post-repair count rises")
    func freshWriteAfterRepairVerifies() throws {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        for i in 0..<4 { Self.record(db, "t-\(i)") }

        _ = try db.repairChain(table: "token_events", fromRowid: 3, force: true)

        Self.record(db, "post-1")
        Self.record(db, "post-2")
        Self.record(db, "post-3")

        let result = ChainVerifier.verifyTokenEvents(db)
        guard case .ok(_, let repairs) = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
        #expect(repairs == 1)
    }

    @Test("Repair on validation_results works end-to-end")
    func validationResultsRepair() throws {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        for i in 0..<3 {
            db.insertValidationResult(
                sessionId: "s",
                filePath: "/tmp/file-\(i).swift",
                validatorName: "swiftc",
                category: "syntax",
                exitCode: 0,
                rawOutput: nil,
                advisory: "OK",
                durationMs: 5
            )
        }
        db.flushWrites()

        // Tamper row 2.
        try Self.tamper(path, table: "validation_results", where_: "id = 2", set: "advisory = 'tampered'")
        let preRepair = ChainVerifier.verifyValidationResults(db)
        guard case .brokenAt = preRepair else {
            Issue.record("expected brokenAt, got \(preRepair)")
            return
        }

        // Repair from rowid 2.
        let outcome = try db.repairChain(table: "validation_results", fromRowid: 2, force: true)
        #expect(outcome.rowsRebound == 2)

        // Add a fresh row and verify.
        db.insertValidationResult(
            sessionId: "s",
            filePath: "/tmp/file-fresh.swift",
            validatorName: "swiftc",
            category: "syntax",
            exitCode: 0,
            rawOutput: nil,
            advisory: "OK",
            durationMs: 5
        )
        db.flushWrites()

        let postRepair = ChainVerifier.verifyValidationResults(db)
        guard case .ok = postRepair else {
            Issue.record("expected .ok, got \(postRepair)")
            return
        }
    }

    @Test("Repair on a chain with no tip hash (only backfilled rows) handles nil prior tip")
    func priorTipNilHandled() throws {
        // Set up a DB whose token_events anchor has only backfilled (NULL-hash)
        // rows — i.e. the migration anchor with no post-migration writes yet.
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        Self.record(db, "t-1")
        Self.record(db, "t-2")
        Self.record(db, "t-3")
        // Manually wipe hashes to simulate a pre-T.5 backfill state.
        var rdb: OpaquePointer?
        try #require(sqlite3_open(path, &rdb) == SQLITE_OK)
        defer { sqlite3_close(rdb) }
        var err: UnsafeMutablePointer<CChar>?
        try #require(sqlite3_exec(rdb, "UPDATE token_events SET prev_hash=NULL, entry_hash=NULL;", nil, nil, &err) == SQLITE_OK)
        if let err { sqlite3_free(err) }

        // Repair from rowid 2 with --force (no prior repair guards apply).
        let outcome = try db.repairChain(table: "token_events", fromRowid: 2, force: true)
        #expect(outcome.priorTipHash == nil)
        #expect(outcome.rowsRebound == 2)
    }
}
