import Testing
import Foundation
import SQLite3
@testable import Core

// `.serialized` belt-and-suspenders alongside the busy_timeout fix in
// `TempSessionDatabase.openSecondaryHandle`: the suite mutates on-disk
// sqlite rows via a second handle, and parallel-runner CPU/IO pressure
// was masking writer lock contention as `tamper code 2 "database is
// locked"`. See `chainrepairer-pane-refresh-state-database-locked-2026-05-04`.
@Suite("ChainRepairer — T.5 round 4", .serialized)
struct ChainRepairTests {

    // MARK: - Helpers

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-chain-repair-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
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
        guard let db = TempSessionDatabase.openSecondaryHandle(path) else {
            throw NSError(domain: "tamper", code: 1)
        }
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
        defer { TempSessionDatabase.close(db, path: path) }

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
        defer { TempSessionDatabase.close(db, path: path) }

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
        defer { TempSessionDatabase.close(db, path: path) }

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
        defer { TempSessionDatabase.close(db, path: path) }

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
        defer { TempSessionDatabase.close(db, path: path) }

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
        defer { TempSessionDatabase.close(db, path: path) }

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
        let rdb = try #require(TempSessionDatabase.openSecondaryHandle(path))
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
        defer { TempSessionDatabase.close(db, path: path) }

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
        defer { TempSessionDatabase.close(db, path: path) }

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

    // MARK: - Widened supportedTables (chainrepairer-supportedtables-widen)

    @Test("supportedTables covers every integer-keyed chain participant")
    func supportedTablesShape() {
        let expected: Set<String> = [
            "token_events",
            "validation_results",
            "commands",
            "policy_snapshots",
            "pane_refresh_state",
            "confirmations",
            "trust_audits",
        ]
        #expect(ChainRepairer.supportedTables == expected)
        // annotation_rate_cap_log is intentionally NOT a chain participant
        // (see AnnotationRateCapStore) — guard against accidental inclusion.
        #expect(!ChainRepairer.supportedTables.contains("annotation_rate_cap_log"))
        // sandboxed_results uses TEXT PKs and stays out of --from-rowid
        // repair (caller would need --from-created-at).
        #expect(!ChainRepairer.supportedTables.contains("sandboxed_results"))
    }

    @Test("unsupportedTable error message lists every supported table")
    func unsupportedTableMessageReflectsSet() {
        let err = ChainRepairer.RepairError.unsupportedTable("annotation_rate_cap_log")
        for table in ChainRepairer.supportedTables {
            #expect(err.description.contains(table), "missing '\(table)' in '\(err.description)'")
        }
    }

    @Test("Repair on policy_snapshots: tamper, doctor sees breach, repair, post-repair verify .ok")
    func policySnapshotsRepair() throws {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let sid = db.createSession(projectRoot: "/tmp/senkani-chain-repair", agentType: .claudeCode)
        for i in 0..<3 {
            let cfg = PolicyConfig(
                features: PolicyFeatures(
                    filter: true, secrets: true, indexer: true,
                    terse: false, injectionGuard: true
                ),
                budget: PolicyBudget(
                    perSessionLimitCents: 100 + i,
                    dailyLimitCents: nil, weeklyLimitCents: nil,
                    softLimitPercent: 0.8
                ),
                learnedRulesHash: "hash-\(i)",
                modelId: "claude-haiku-4-5",
                modelTier: nil,
                agentType: "claude_code",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            )
            #expect(db.recordPolicySnapshot(sessionId: sid, config: cfg))
        }
        db.flushWrites()

        // Tamper row 2.
        try Self.tamper(
            path, table: "policy_snapshots",
            where_: "id = 2", set: "policy_json = '{\"tampered\":true}'"
        )

        // `senkani doctor --verify-chain` reports the breach.
        let preRepair = ChainVerifier.verifyPolicySnapshots(db)
        guard case .brokenAt(_, let rowid, _, _) = preRepair else {
            Issue.record("expected brokenAt, got \(preRepair)")
            return
        }
        #expect(rowid == 2)

        // `senkani doctor --repair-chain --table policy_snapshots --from-rowid 2`
        // opens a repair anchor.
        let outcome = try db.repairChain(
            table: "policy_snapshots",
            fromRowid: 2,
            force: true
        )
        #expect(outcome.table == "policy_snapshots")
        #expect(outcome.fromRowid == 2)
        #expect(outcome.rowsRebound == 2)  // rows 2, 3

        // Add a fresh row under the new anchor and verify.
        let freshCfg = PolicyConfig(
            features: PolicyFeatures(filter: false, secrets: true, indexer: true, terse: false, injectionGuard: true),
            budget: PolicyBudget(perSessionLimitCents: 999, dailyLimitCents: nil, weeklyLimitCents: nil, softLimitPercent: 0.5),
            learnedRulesHash: "fresh",
            modelId: "claude-sonnet-4-6",
            modelTier: nil,
            agentType: "claude_code",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        #expect(db.recordPolicySnapshot(sessionId: sid, config: freshCfg))
        db.flushWrites()

        let postRepair = ChainVerifier.verifyPolicySnapshots(db)
        guard case .ok(_, let repairs) = postRepair else {
            Issue.record("expected .ok, got \(postRepair)")
            return
        }
        #expect(repairs >= 1)
    }

    @Test("Repair on pane_refresh_state: tamper, verify breach, repair, fresh write verifies .ok")
    func paneRefreshStateRepair() throws {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let projectRoot = "/tmp/senkani-chain-repair-prs"
        for i in 0..<3 {
            let state = PaneRefreshState(
                cacheType: .duration,
                cacheDuration: 30,
                nextUpdate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                contentAvailable: true
            )
            db.recordPaneRefreshState(projectRoot: projectRoot, tileId: "tile-\(i)", state: state)
        }
        db.flushWrites()

        // Tamper row 2 — flip its tile_id.
        try Self.tamper(
            path, table: "pane_refresh_state",
            where_: "id = 2", set: "tile_id = 'tampered'"
        )

        let preRepair = ChainVerifier.verifyPaneRefreshState(db)
        guard case .brokenAt(_, let rowid, _, _) = preRepair else {
            Issue.record("expected brokenAt, got \(preRepair)")
            return
        }
        #expect(rowid == 2)

        let outcome = try db.repairChain(
            table: "pane_refresh_state",
            fromRowid: 2,
            force: true
        )
        #expect(outcome.table == "pane_refresh_state")
        #expect(outcome.rowsRebound == 2)

        // Fresh write under the new anchor.
        let fresh = PaneRefreshState(
            cacheType: .duration, cacheDuration: 60,
            nextUpdate: Date(timeIntervalSince1970: 1_700_000_500),
            contentAvailable: false
        )
        db.recordPaneRefreshState(projectRoot: projectRoot, tileId: "tile-fresh", state: fresh)
        db.flushWrites()

        let postRepair = ChainVerifier.verifyPaneRefreshState(db)
        guard case .ok(_, let repairs) = postRepair else {
            Issue.record("expected .ok, got \(postRepair)")
            return
        }
        #expect(repairs >= 1)
    }

    @Test("Repair on confirmations: opens a repair anchor (verifier coverage pending)")
    func confirmationsRepairOpensAnchor() throws {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        for i in 0..<3 {
            db.recordConfirmation(ConfirmationRow(
                toolName: "Tool-\(i)",
                requestedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                decidedAt: Date(timeIntervalSince1970: 1_700_000_001 + Double(i)),
                decision: .auto,
                decidedBy: .auto,
                reason: nil
            ))
        }
        db.flushWrites()

        let outcome = try db.repairChain(
            table: "confirmations",
            fromRowid: 2,
            force: true
        )
        #expect(outcome.table == "confirmations")
        #expect(outcome.fromRowid == 2)
        #expect(outcome.rowsRebound == 2)
        #expect(outcome.newAnchorId > 0)

        // Repair anchor row exists with reason='repair-2' and the prior tip
        // recorded in operator_note.
        let rdb = try #require(TempSessionDatabase.openSecondaryHandle(path))
        defer { sqlite3_close(rdb) }
        var stmt: OpaquePointer?
        let sql = "SELECT reason, operator_note FROM chain_anchors WHERE id = ?;"
        try #require(sqlite3_prepare_v2(rdb, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, outcome.newAnchorId)
        try #require(sqlite3_step(stmt) == SQLITE_ROW)
        let reason = String(cString: sqlite3_column_text(stmt, 0))
        let note = String(cString: sqlite3_column_text(stmt, 1))
        #expect(reason == "repair-2")
        #expect(note.contains("prior_tip="))
    }

    @Test("Repair on trust_audits: opens a repair anchor (verifier coverage pending)")
    func trustAuditsRepairOpensAnchor() throws {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        for i in 0..<3 {
            let flag = FragmentationDetector.Flag(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                sessionId: "s-\(i)",
                paneId: nil,
                toolName: "Tool",
                reason: .toolBurst,
                correlationCount: 3
            )
            #expect(db.recordTrustFlag(flag, score: 50 + i) >= 0)
        }
        db.flushWrites()

        let outcome = try db.repairChain(
            table: "trust_audits",
            fromRowid: 2,
            force: true
        )
        #expect(outcome.table == "trust_audits")
        #expect(outcome.rowsRebound >= 2)
        #expect(outcome.newAnchorId > 0)
    }

    @Test("Repair on a chain with no tip hash (only backfilled rows) handles nil prior tip")
    func priorTipNilHandled() throws {
        // Set up a DB whose token_events anchor has only backfilled (NULL-hash)
        // rows — i.e. the migration anchor with no post-migration writes yet.
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        Self.record(db, "t-1")
        Self.record(db, "t-2")
        Self.record(db, "t-3")
        // Manually wipe hashes to simulate a pre-T.5 backfill state.
        let rdb = try #require(TempSessionDatabase.openSecondaryHandle(path))
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
