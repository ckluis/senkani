import Testing
import Foundation
import SQLite3
@testable import Core

/// Coverage for the v28 migration anchor + writer/verifier branching that
/// folds the v25-added `trust_audits` columns (`observed_rate`,
/// `observed_sample`, `call_id`) into the canonical hash map. Filed as
/// `process-gap-trust-audits-migration-v25-anchor-pending-2026-05-20` —
/// the partial-defer follow-up from U.4b-1's close-mode 2026-05-20.
///
/// Three scenarios, each in its own temp DB:
///   1. Idempotency — lazy-open on first promotion creates exactly one
///      `migration-v25` row; second promotion reuses it.
///   2. Branched verifier — pre-v25 (legacy-shape) rows + v25-shape rows
///      both verify under their own anchor's shape.
///   3. Tamper detection — flipping a stored `observed_rate` post-write
///      is caught by ChainVerifier (the regression the defect describes).
@Suite("trust_audits — migration-v25 anchor + verifier branching")
struct TrustAuditsMigrationV25AnchorTests {

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-trust-v25-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    /// Insert a `fresh-install-pre-v25` anchor for `trust_audits` via a
    /// secondary handle so the test exercises the post-upgrade path
    /// (where the v28 rename has fired against a pre-existing
    /// `fresh-install` anchor) without depending on a snapshot DB
    /// fixture. Returns the anchor's rowid.
    private func seedLegacyAnchor(path: String, startedAtRowid: Int64 = 0) -> Int64 {
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle to seed legacy anchor")
            return -1
        }
        defer { sqlite3_close(handle) }
        let now = Date().timeIntervalSince1970
        let sql = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES ('trust_audits', ?, ?, 'fresh-install-pre-v25', NULL);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, startedAtRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Count `chain_anchors` rows for `trust_audits` matching `reason`.
    /// Used to assert the lazy-open is idempotent.
    private func anchorCount(path: String, reason: String) -> Int {
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else { return -1 }
        defer { sqlite3_close(handle) }
        let sql = "SELECT COUNT(*) FROM chain_anchors WHERE table_name = 'trust_audits' AND reason = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (reason as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - 1. Idempotency

    @Test("First promotion under a pre-v25 anchor lazy-opens exactly one migration-v25 anchor; subsequent promotions reuse it")
    func openMigrationV25AnchorIsIdempotent() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Seed the post-upgrade state: only a `fresh-install-pre-v25`
        // anchor exists (the v28 rename ran against an existing pre-v25
        // anchor). No migration-v25 anchor yet.
        _ = seedLegacyAnchor(path: path)

        #expect(anchorCount(path: path, reason: "fresh-install-pre-v25") == 1)
        #expect(anchorCount(path: path, reason: "migration-v25") == 0)

        // First promotion writes through the lazy-open path.
        let p1 = db.recordTrustPromotion(
            from: "softFlag", to: "blocking",
            fpRateMax: 0.05, minLabeledSample: 200,
            observedRate: 0.03, observedSample: 250,
            promotedBy: "operator"
        )
        #expect(p1 > 0)
        db.flushWrites()

        #expect(anchorCount(path: path, reason: "migration-v25") == 1,
                "first promotion must lazy-open exactly one migration-v25 anchor")

        // Second promotion (and an override) — must reuse the existing
        // anchor, NOT open a second one.
        let p2 = db.recordTrustPromotion(
            from: "blocking", to: "softFlag",
            fpRateMax: nil, minLabeledSample: nil,
            observedRate: nil, observedSample: 0,
            promotedBy: "operator"
        )
        #expect(p2 > p1)
        let o1 = db.recordTrustOverride(
            callId: "call-idempotent",
            flagId: nil,
            operator: "operator",
            justification: "second-call uses same anchor"
        )
        #expect(o1 > p2)
        db.flushWrites()

        #expect(anchorCount(path: path, reason: "migration-v25") == 1,
                "second promotion + override must NOT open a duplicate migration-v25 anchor")

        // Chain still verifies.
        let r = ChainVerifier.verifyTrustAudits(db)
        if case .brokenAt(let table, let rowid, let exp, let act) = r {
            Issue.record("chain broken after idempotent lazy-open: \(table):\(rowid) expected=\(exp) actual=\(act)")
        }
    }

    // MARK: - 2. Verifier branches across pre-v25 + v25 segments

    @Test("Verifier walks both segments: pre-v25 rows verify under legacy 11-col shape; post-promotion rows verify under v25 14-col shape")
    func verifierBranchesAcrossPreAndPostV25Segments() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Seed pre-upgrade anchor (post-v28 rename simulation).
        _ = seedLegacyAnchor(path: path)

        // Pre-v25 segment: write 2 flag rows + 1 label row. All chain
        // under the renamed `fresh-install-pre-v25` anchor using the
        // legacy 11-column shape.
        let flag1 = FragmentationDetector.Flag(
            createdAt: Date(timeIntervalSince1970: 1700000000),
            sessionId: "sid-pre-1",
            paneId: nil,
            toolName: "Edit",
            reason: .toolBurst,
            correlationCount: 3
        )
        let flagId1 = db.recordTrustFlag(flag1, score: 5)
        #expect(flagId1 > 0)

        let flag2 = FragmentationDetector.Flag(
            createdAt: Date(timeIntervalSince1970: 1700000001),
            sessionId: "sid-pre-2",
            paneId: "pane-x",
            toolName: "Write",
            reason: .toolBurst,
            correlationCount: 4
        )
        let flagId2 = db.recordTrustFlag(flag2, score: 7)
        #expect(flagId2 > flagId1)

        let labelId = db.recordTrustLabel(flagId: flagId1, label: .fp, labeledBy: "operator")
        #expect(labelId > flagId2)
        db.flushWrites()

        // v25 segment: first promotion lazy-opens the migration-v25
        // anchor; subsequent rows (including a flag + an override)
        // chain under the new anchor with the 14-column shape.
        let promotionId = db.recordTrustPromotion(
            from: "softFlag", to: "blocking",
            fpRateMax: 0.05, minLabeledSample: 200,
            observedRate: 0.03, observedSample: 250,
            promotedBy: "operator"
        )
        #expect(promotionId > labelId)

        let flag3 = FragmentationDetector.Flag(
            createdAt: Date(timeIntervalSince1970: 1700000100),
            sessionId: "sid-post",
            paneId: nil,
            toolName: "Bash",
            reason: .toolBurst,
            correlationCount: 5
        )
        let flagId3 = db.recordTrustFlag(flag3, score: 9)
        #expect(flagId3 > promotionId)

        let overrideId = db.recordTrustOverride(
            callId: "call-post-v25",
            flagId: flagId3,
            operator: "operator",
            justification: "post-burst allowlist"
        )
        #expect(overrideId > flagId3)
        db.flushWrites()

        // Whole chain verifies across both segments.
        let r = ChainVerifier.verifyTrustAudits(db)
        switch r {
        case .ok: break
        case .noChain: Issue.record("expected chain across both segments; got .noChain")
        case .brokenAt(let table, let rowid, let exp, let act):
            Issue.record("chain broken across pre/post-v25 boundary at \(table):\(rowid) expected=\(exp) actual=\(act)")
        }

        // Confirm the row-by-anchor split actually happened: at least
        // one row lives under the pre-v25 anchor and at least one lives
        // under the migration-v25 anchor. Otherwise the test silently
        // passes a single-anchor chain (which would be a meaningless
        // green).
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle for segment check")
            return
        }
        defer { sqlite3_close(handle) }
        let segSQL = """
            SELECT a.reason, COUNT(t.id)
              FROM chain_anchors a
              LEFT JOIN trust_audits t ON t.chain_anchor_id = a.id
             WHERE a.table_name = 'trust_audits'
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
        #expect((counts["fresh-install-pre-v25"] ?? 0) >= 3,
                "expected ≥3 rows under legacy anchor (2 flags + 1 label); got \(counts)")
        #expect((counts["migration-v25"] ?? 0) >= 3,
                "expected ≥3 rows under v25 anchor (1 promotion + 1 flag + 1 override); got \(counts)")
    }

    // MARK: - 3. Tamper detection of observed_rate

    @Test("Post-write UPDATE of observed_rate on a v25-anchor promotion row is detected by ChainVerifier")
    func observedRateTamperDetected() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Fresh install path — no pre-v25 anchor seeded. ChainState
        // lazy-creates a `fresh-install` anchor on first write, which
        // under the v28-aware writer uses the v25 canonical shape.
        let promotionId = db.recordTrustPromotion(
            from: "softFlag", to: "blocking",
            fpRateMax: 0.05, minLabeledSample: 200,
            observedRate: 0.03, observedSample: 250,
            promotedBy: "operator"
        )
        #expect(promotionId > 0)
        db.flushWrites()

        // Sanity: chain green pre-tamper.
        let pre = ChainVerifier.verifyTrustAudits(db)
        if case .brokenAt = pre {
            Issue.record("chain broken pre-tamper; v25 shape mismatch")
        }

        // Tamper: flip the stored observed_rate via a secondary handle.
        // Pre-v28 this would have been undetected (the column wasn't
        // in the canonical hash map); the v25 shape now folds it in,
        // so the verifier MUST catch it.
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle for tamper")
            return
        }
        defer { sqlite3_close(handle) }
        let updateSQL = "UPDATE trust_audits SET observed_rate = 0.99 WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, updateSQL, -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("failed to prepare UPDATE")
            return
        }
        sqlite3_bind_int64(stmt, 1, promotionId)
        let stepRC = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        #expect(stepRC == SQLITE_DONE, "UPDATE step rc=\(stepRC)")

        // Verifier now sees the row's stored hash diverge from the
        // recomputed hash because the v25 canonical shape inputs
        // observed_rate.
        let post = ChainVerifier.verifyTrustAudits(db)
        switch post {
        case .brokenAt(let table, let rowid, _, _):
            #expect(table == "trust_audits")
            #expect(rowid == promotionId, "expected break at the tampered row id \(promotionId); got \(rowid)")
        case .ok:
            Issue.record("tamper of observed_rate was NOT detected — v25 shape regression")
        case .noChain:
            Issue.record("no chain to verify (test setup bug)")
        }
    }
}
