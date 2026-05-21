import Testing
import Foundation
import SQLite3
@testable import Core

/// Coverage for the v29 migration anchor + writer/verifier branching that
/// folds the v22-added `validation_results` columns (`axes`,
/// `target_url`, `plan_steps`, `result_status`, `screenshot_path`) into
/// the canonical hash map. Filed as
/// `process-gap-validation-results-migration-v22-anchor-pending-2026-05-19` —
/// the partial-defer follow-up from U.2a-2b's close-mode 2026-05-19.
///
/// Three scenarios, each in its own temp DB:
///   1. Idempotency — lazy-open on first browser-validation creates
///      exactly one `migration-v22` row; second browser write reuses it.
///   2. Branched verifier — pre-v22 (legacy-shape) rows + v22-shape rows
///      both verify under their own anchor's shape.
///   3. Tamper detection — flipping a stored `result_status` post-write
///      is caught by ChainVerifier (the regression the defect describes).
@Suite("validation_results — migration-v22 anchor + verifier branching")
struct ValidationResultsMigrationV22AnchorTests {

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-validation-v22-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    /// Insert a `fresh-install-pre-v22` anchor for `validation_results`
    /// via a secondary handle so the test exercises the post-upgrade
    /// path (where the v29 rename has fired against a pre-existing
    /// `fresh-install` anchor) without depending on a snapshot DB
    /// fixture. Returns the anchor's rowid.
    private func seedLegacyAnchor(path: String, startedAtRowid: Int64 = 0) -> Int64 {
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle to seed legacy anchor")
            return -1
        }
        defer { sqlite3_close(handle) }
        // Wipe any auto-created `fresh-install` and pre-existing
        // `fresh-install-pre-v22` anchor so the post-upgrade single-
        // anchor state is exact. ChainState may have raced the test
        // setup and lazy-created its own `fresh-install` anchor on
        // first read; this clean slate keeps the assertion precise.
        let cleanup = """
            DELETE FROM chain_anchors
             WHERE table_name = 'validation_results'
               AND reason IN ('fresh-install', 'fresh-install-pre-v22');
        """
        var cleanupErr: UnsafeMutablePointer<CChar>?
        sqlite3_exec(handle, cleanup, nil, nil, &cleanupErr)
        if let cleanupErr { sqlite3_free(cleanupErr) }

        let now = Date().timeIntervalSince1970
        let sql = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES ('validation_results', ?, ?, 'fresh-install-pre-v22', NULL);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, startedAtRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Count `chain_anchors` rows for `validation_results` matching
    /// `reason`. Used to assert the lazy-open is idempotent.
    private func anchorCount(path: String, reason: String) -> Int {
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else { return -1 }
        defer { sqlite3_close(handle) }
        let sql = "SELECT COUNT(*) FROM chain_anchors WHERE table_name = 'validation_results' AND reason = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (reason as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - 1. Idempotency

    @Test("First browser-validation under a pre-v22 anchor lazy-opens exactly one migration-v22 anchor; subsequent browser writes reuse it")
    func openMigrationV22AnchorIsIdempotent() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Seed the post-upgrade state: only a `fresh-install-pre-v22`
        // anchor exists. No migration-v22 anchor yet.
        _ = seedLegacyAnchor(path: path)

        #expect(anchorCount(path: path, reason: "fresh-install-pre-v22") == 1)
        #expect(anchorCount(path: path, reason: "migration-v22") == 0)

        // First browser write triggers the lazy-open path.
        db.insertBrowserValidationResult(
            sessionId: "sid-1",
            targetURL: "https://example.com/v22-idempotent",
            axes: ["perf"],
            planStepsJSON: "[]",
            resultStatus: "pass",
            assertionsPassed: 1,
            assertionsFailed: 0,
            advisory: "first browser row",
            screenshotPath: nil
        )
        db.flushWrites()

        #expect(anchorCount(path: path, reason: "migration-v22") == 1,
                "first browser write must lazy-open exactly one migration-v22 anchor")

        // Second + third browser writes — must reuse the existing
        // anchor, NOT open a second one.
        db.insertBrowserValidationResult(
            sessionId: "sid-2",
            targetURL: "https://example.com/v22-second",
            axes: ["completeness"],
            planStepsJSON: "[]",
            resultStatus: "fail",
            assertionsPassed: 0,
            assertionsFailed: 2,
            advisory: "second browser row",
            screenshotPath: "/tmp/shot-2.png"
        )
        db.insertBrowserValidationResult(
            sessionId: "sid-3",
            targetURL: "https://example.com/v22-third",
            axes: ["perf", "completeness"],
            planStepsJSON: "[]",
            resultStatus: "pass",
            assertionsPassed: 3,
            assertionsFailed: 0,
            advisory: "third browser row",
            screenshotPath: nil
        )
        db.flushWrites()

        #expect(anchorCount(path: path, reason: "migration-v22") == 1,
                "subsequent browser writes must NOT open duplicate migration-v22 anchors")

        // Chain still verifies.
        let r = ChainVerifier.verifyValidationResults(db)
        if case .brokenAt(let table, let rowid, let exp, let act) = r {
            Issue.record("chain broken after idempotent lazy-open: \(table):\(rowid) expected=\(exp) actual=\(act)")
        }
    }

    // MARK: - 2. Verifier branches across pre-v22 + v22 segments

    @Test("Verifier walks both segments: pre-v22 rows verify under legacy 13-col shape; post-browser-write rows verify under v22 18-col shape")
    func verifierBranchesAcrossPreAndPostV22Segments() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Seed pre-upgrade anchor (post-v29 rename simulation).
        _ = seedLegacyAnchor(path: path)

        // Pre-v22 segment: write 2 auto-validate rows. Both chain under
        // the renamed `fresh-install-pre-v22` anchor using the legacy
        // 13-column shape.
        db.insertValidationResult(
            sessionId: "sid-pre-1",
            filePath: "/tmp/pre-1.swift",
            validatorName: "swiftlint",
            category: "lint",
            exitCode: 0,
            rawOutput: nil,
            advisory: "clean",
            durationMs: 5,
            outcome: "clean",
            reason: nil
        )
        db.insertValidationResult(
            sessionId: "sid-pre-2",
            filePath: "/tmp/pre-2.swift",
            validatorName: "swiftlint",
            category: "lint",
            exitCode: 1,
            rawOutput: "warning: foo",
            advisory: "review",
            durationMs: 7,
            outcome: "advisory",
            reason: "1 warning"
        )
        db.flushWrites()

        // v22 segment: first browser write lazy-opens the migration-v22
        // anchor; subsequent rows (including a later auto-validate)
        // chain under the new anchor with the 18-column shape.
        db.insertBrowserValidationResult(
            sessionId: "sid-post-1",
            targetURL: "https://example.com/v22-page",
            axes: ["perf", "completeness"],
            planStepsJSON: "[{\"action\":\"navigate\"}]",
            resultStatus: "pass",
            assertionsPassed: 4,
            assertionsFailed: 0,
            advisory: "all green",
            screenshotPath: "/tmp/post-1.png"
        )
        db.insertValidationResult(
            sessionId: "sid-post-2",
            filePath: "/tmp/post-2.swift",
            validatorName: "swift-format",
            category: "format",
            exitCode: 0,
            rawOutput: nil,
            advisory: "clean",
            durationMs: 9,
            outcome: "clean",
            reason: nil
        )
        db.insertBrowserValidationResult(
            sessionId: "sid-post-3",
            targetURL: "https://example.com/v22-page-2",
            axes: ["security"],
            planStepsJSON: "[]",
            resultStatus: "fail",
            assertionsPassed: 0,
            assertionsFailed: 1,
            advisory: "blocked by axis security",
            screenshotPath: nil
        )
        db.flushWrites()

        // Whole chain verifies across both segments.
        let r = ChainVerifier.verifyValidationResults(db)
        switch r {
        case .ok: break
        case .noChain: Issue.record("expected chain across both segments; got .noChain")
        case .brokenAt(let table, let rowid, let exp, let act):
            Issue.record("chain broken across pre/post-v22 boundary at \(table):\(rowid) expected=\(exp) actual=\(act)")
        }

        // Confirm the row-by-anchor split actually happened: at least
        // one row lives under the pre-v22 anchor and at least one lives
        // under the migration-v22 anchor. Otherwise the test silently
        // passes a single-anchor chain (which would be a meaningless
        // green).
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle for segment check")
            return
        }
        defer { sqlite3_close(handle) }
        let segSQL = """
            SELECT a.reason, COUNT(v.id)
              FROM chain_anchors a
              LEFT JOIN validation_results v ON v.chain_anchor_id = a.id
             WHERE a.table_name = 'validation_results'
             GROUP BY a.reason;
        """
        var segStmt: OpaquePointer?
        var counts: [String: Int] = [:]
        if sqlite3_prepare_v2(handle, segSQL, -1, &segStmt, nil) == SQLITE_OK {
            while sqlite3_step(segStmt) == SQLITE_ROW {
                let reason = String(cString: sqlite3_column_text(segStmt, 0))
                counts[reason] = Int(sqlite3_column_int64(segStmt, 1))
            }
            sqlite3_finalize(segStmt)
        }
        #expect((counts["fresh-install-pre-v22"] ?? 0) >= 2,
                "expected ≥2 rows under legacy anchor (2 auto-validate); got \(counts)")
        #expect((counts["migration-v22"] ?? 0) >= 3,
                "expected ≥3 rows under v22 anchor (2 browser + 1 auto-validate); got \(counts)")
    }

    // MARK: - 3. Tamper detection of result_status

    @Test("Post-write UPDATE of result_status on a v22-anchor browser row is detected by ChainVerifier")
    func resultStatusTamperDetected() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Fresh install path — no pre-v22 anchor seeded. ChainState
        // lazy-creates a `fresh-install` anchor on first write, which
        // under the v29-aware writer uses the v22 canonical shape.
        db.insertBrowserValidationResult(
            sessionId: "sid-tamper",
            targetURL: "https://example.com/tamper",
            axes: ["perf"],
            planStepsJSON: "[]",
            resultStatus: "fail",
            assertionsPassed: 0,
            assertionsFailed: 1,
            advisory: "blocked by axis perf",
            screenshotPath: nil
        )
        db.flushWrites()

        // Look up the rowid we just wrote.
        let failingRow = db.firstFailingBrowserValidation(sessionId: "sid-tamper")
        guard let row = failingRow else {
            Issue.record("expected a failing browser-validation row to exist")
            return
        }

        // Sanity: chain green pre-tamper.
        let pre = ChainVerifier.verifyValidationResults(db)
        if case .brokenAt = pre {
            Issue.record("chain broken pre-tamper; v22 shape mismatch")
        }

        // Tamper: flip the stored result_status via a secondary handle.
        // Pre-v29 this would have been undetected (the column wasn't
        // in the canonical hash map); the v22 shape now folds it in,
        // so the verifier MUST catch it.
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle for tamper")
            return
        }
        defer { sqlite3_close(handle) }
        let updateSQL = "UPDATE validation_results SET result_status = 'pass' WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, updateSQL, -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("failed to prepare UPDATE")
            return
        }
        sqlite3_bind_int64(stmt, 1, row.id)
        let stepRC = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        #expect(stepRC == SQLITE_DONE, "UPDATE step rc=\(stepRC)")

        // Verifier now sees the row's stored hash diverge from the
        // recomputed hash because the v22 canonical shape inputs
        // result_status.
        let post = ChainVerifier.verifyValidationResults(db)
        switch post {
        case .brokenAt(let table, let rowid, _, _):
            #expect(table == "validation_results")
            #expect(rowid == row.id, "expected break at the tampered row id \(row.id); got \(rowid)")
        case .ok:
            Issue.record("tamper of result_status was NOT detected — v22 shape regression")
        case .noChain:
            Issue.record("no chain to verify (test setup bug)")
        }
    }
}
