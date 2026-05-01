import Testing
import Foundation
import SQLite3
@testable import Core

@Suite("ChainVerifier — token_events tamper-evidence (T.5 round 2)")
struct ChainVerifierTests {

    // MARK: - Helpers

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-chainverifier-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func cleanup(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }

    private static func record(_ db: SessionDatabase, _ tag: String, tokens: Int = 100) {
        db.recordTokenEvent(
            sessionId: "s-\(tag)",
            paneId: nil,
            projectRoot: "/tmp/senkani-chainverifier-test",
            source: "mcp_tool",
            toolName: tag,
            model: nil,
            inputTokens: tokens,
            outputTokens: tokens / 2,
            savedTokens: tokens / 2,
            costCents: 1,
            feature: nil,
            command: nil
        )
        db.flushWrites()
    }

    /// Direct-to-handle SQL fixture: tampers a single column in a single row.
    /// Mirrors what an attacker (or a bug) would have to do — flip a byte in
    /// the data, leave the chain columns untouched.
    private static func tamper(_ path: String, rowid: Int64) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "tamper", code: 1)
        }
        defer { sqlite3_close(db) }
        let sql = "UPDATE token_events SET tool_name = 'tampered' WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "tamper", code: 2)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "tamper", code: 3)
        }
    }

    // MARK: - Tests

    @Test("Fresh DB with no rows reports noChain")
    func freshDBNoChain() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        let result = ChainVerifier.verifyTokenEvents(db)
        #expect(result == .noChain)
    }

    @Test("Single insert opens fresh-install anchor and verifies OK")
    func singleInsertOK() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        Self.record(db, "first")

        let result = ChainVerifier.verifyTokenEvents(db)
        guard case .ok(_, let repairs) = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
        #expect(repairs == 0)
    }

    @Test("Multiple inserts chain cleanly and verify OK")
    func chainOfFiveVerifies() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        for i in 0..<5 { Self.record(db, "t-\(i)", tokens: 100 + i) }

        let result = ChainVerifier.verifyTokenEvents(db)
        guard case .ok = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
    }

    @Test("Single-byte tamper at row K is caught at row K (not earlier, not later)")
    func tamperAtRowKCaught() throws {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        for i in 0..<5 { Self.record(db, "t-\(i)") }
        // Get the rowid of the third inserted row.
        let rowids = try Self.selectAllRowids(path: path)
        #expect(rowids.count == 5)
        let target = rowids[2]
        try Self.tamper(path, rowid: target)

        let result = ChainVerifier.verifyTokenEvents(db)
        guard case .brokenAt(let table, let rowid, _, _) = result else {
            Issue.record("expected .brokenAt, got \(result)")
            return
        }
        #expect(table == "token_events")
        #expect(rowid == target)
    }

    @Test("Chain survives a process restart — cold-start prev lookup hits the DB")
    func chainSurvivesRestart() {
        let (db1, path) = Self.makeDB()
        Self.record(db1, "before-restart-1")
        Self.record(db1, "before-restart-2")
        db1.close()

        let db2 = SessionDatabase(path: path)
        defer { db2.close(); Self.cleanup(path) }

        Self.record(db2, "after-restart-1")
        Self.record(db2, "after-restart-2")

        let result = ChainVerifier.verifyTokenEvents(db2)
        guard case .ok = result else {
            Issue.record("expected .ok after restart, got \(result)")
            return
        }
    }

    @Test("Pre-T.5 backfilled rows are skipped by verification")
    func preT5RowsSkipped() throws {
        // Manually construct a DB that mimics the v4 migration outcome:
        // existing rows with chain_anchor_id pointing at a 'migration-v4'
        // anchor, NULL prev_hash + entry_hash. The verifier should NOT
        // walk those rows — they predate the chain by design.
        let path = "/tmp/senkani-chainverifier-pret5-\(UUID().uuidString).sqlite"
        defer { Self.cleanup(path) }

        let db = SessionDatabase(path: path)
        // First, write rows under the fresh-install anchor that v4 would have
        // backfilled if they'd predated the migration.
        Self.record(db, "p-1")
        Self.record(db, "p-2")

        // Now mutate the test DB to look like a post-migration backfill:
        // - The first two rows: NULL prev/entry, anchor unchanged (simulating
        //   anchor-from-now), `started_at_rowid = MAX(id-among-pre)`.
        // Then write more rows under the new chain.
        let preIds = try Self.selectAllRowids(path: path)
        try Self.runSQL(path: path, """
            UPDATE token_events SET prev_hash = NULL, entry_hash = NULL
             WHERE id IN (\(preIds.map(String.init).joined(separator: ",")));
            UPDATE chain_anchors SET started_at_rowid = \(preIds.last!),
                                     reason = 'migration-v4'
             WHERE table_name = 'token_events';
        """)

        // Write fresh post-migration rows — these belong to the same anchor
        // but have id > started_at_rowid, so they DO verify.
        Self.record(db, "post-1")
        Self.record(db, "post-2")
        defer { db.close() }

        let result = ChainVerifier.verifyTokenEvents(db)
        guard case .ok = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
    }

    @Test("Independent computation of expected hash matches the stored entry_hash for row 1")
    func firstRowHashMatchesIndependentComputation() throws {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        Self.record(db, "exact")

        // Read back the exact bound values for row 1.
        let row = try Self.selectFirstRow(path: path)
        #expect(row.prevHash == nil) // first row in a fresh-install anchor

        let columns: [String: ChainHasher.CanonicalValue] = [
            "timestamp":     .real(row.timestamp),
            "session_id":    .text(row.sessionId),
            "pane_id":       .null,
            "project_root":  .text(row.projectRoot ?? ""),
            "source":        .text(row.source),
            "tool_name":     .text(row.toolName ?? ""),
            "model":         .null,
            "input_tokens":  .integer(Int64(row.inputTokens)),
            "output_tokens": .integer(Int64(row.outputTokens)),
            "saved_tokens":  .integer(Int64(row.savedTokens)),
            "cost_cents":    .integer(Int64(row.costCents)),
            "feature":       .null,
            "command":       .null,
            "model_tier":    .null,
        ]
        let expected = ChainHasher.entryHash(
            table: "token_events", columns: columns, prev: nil
        )
        #expect(row.entryHash == expected)
    }

    // MARK: - Direct SQL helpers

    private static func selectAllRowids(path: String) throws -> [Int64] {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "select", code: 1)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM token_events ORDER BY id;", -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "select", code: 2)
        }
        defer { sqlite3_finalize(stmt) }
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    private struct FirstRow {
        let timestamp: Double
        let sessionId: String
        let projectRoot: String?
        let source: String
        let toolName: String?
        let inputTokens: Int
        let outputTokens: Int
        let savedTokens: Int
        let costCents: Int
        let prevHash: String?
        let entryHash: String
    }

    private static func selectFirstRow(path: String) throws -> FirstRow {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "select", code: 1)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = """
            SELECT timestamp, session_id, project_root, source, tool_name,
                   input_tokens, output_tokens, saved_tokens, cost_cents,
                   prev_hash, entry_hash
              FROM token_events ORDER BY id ASC LIMIT 1;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "select", code: 2)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NSError(domain: "select", code: 3)
        }
        return FirstRow(
            timestamp: sqlite3_column_double(stmt, 0),
            sessionId: String(cString: sqlite3_column_text(stmt, 1)),
            projectRoot: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
            source: String(cString: sqlite3_column_text(stmt, 3)),
            toolName: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            inputTokens: Int(sqlite3_column_int64(stmt, 5)),
            outputTokens: Int(sqlite3_column_int64(stmt, 6)),
            savedTokens: Int(sqlite3_column_int64(stmt, 7)),
            costCents: Int(sqlite3_column_int64(stmt, 8)),
            prevHash: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
            entryHash: String(cString: sqlite3_column_text(stmt, 10))
        )
    }

    private static func runSQL(path: String, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "exec", code: 1)
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let err { sqlite3_free(err) }
            throw NSError(domain: "exec", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
