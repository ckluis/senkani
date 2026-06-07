import Testing
import Foundation
import SQLite3
@testable import Core

/// V.9a follow-up sub-2 — SprintReview lineage chain tests.
///
/// Six tests:
///   1. Migration v34 runs cleanly; sprint_review_snapshots schema +
///      indexes present; ledger advances by one.
///   2. SprintReviewViewModel.snapshot(db:now:snapshot:) writes one
///      row per SprintReviewRow with shared captured_at.
///   3. SprintReviewArtifactProvider.versions(of:) returns the chain
///      sorted captured_at ASC with monotonic 1-based version +
///      previousVersion populated.
///   4. Retention default (30 days) prunes old snapshots on next write.
///   5. Retention env override (SENKANI_SPRINT_REVIEW_RETENTION_DAYS=7)
///      prunes an 8-day-old snapshot.
///   6. ChainVerifier no-regression smoke: verifyTokenEvents passes
///      against a fresh post-v34 DB.
@Suite("SprintReviewLineage") struct SprintReviewLineageTests {

    // MARK: - Fixtures

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-sprint-review-lineage-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private func cleanupDB(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-shm")
        try? fm.removeItem(atPath: path + "-wal")
    }

    private func makeRow(
        id: String,
        kind: SprintReviewArtifactKind = .filterRule,
        title: String = "title",
        subtitle: String = "subtitle",
        recurrence: Int = 3,
        confidence: Double = 0.75,
        lastSeen: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SprintReviewRow {
        SprintReviewRow(
            id: id, kind: kind, title: title, subtitle: subtitle,
            recurrenceCount: recurrence, confidence: confidence, lastSeenAt: lastSeen)
    }

    private func makeSnapshot(_ rows: [SprintReviewRow], windowDays: Int = 14) -> SprintReviewSnapshot {
        var byKind: [SprintReviewArtifactKind: [SprintReviewRow]] = [:]
        for r in rows { byKind[r.kind, default: []].append(r) }
        let sections = byKind.map { SprintReviewSection(kind: $0.key, rows: $0.value) }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
        return SprintReviewSnapshot(sections: sections, stalenessFlags: [], windowDays: windowDays)
    }

    private func snapshotsCount(db: SessionDatabase) -> Int {
        db.queue.sync {
            guard let h = db.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "SELECT COUNT(*) FROM sprint_review_snapshots;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int64(stmt, 0))
            }
            return 0
        }
    }

    // MARK: - 1. Migration shape

    @Test("Migration v34 creates sprint_review_snapshots with expected schema + indexes")
    func migrationCreatesTableAndIndexes() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        #expect(db.currentSchemaVersion() >= 34, "schema version should be ≥ 34 after init, got \(db.currentSchemaVersion())")

        let cols: Set<String> = db.queue.sync {
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "PRAGMA table_info(sprint_review_snapshots);", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var set: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                set.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return set
        }
        let expected: Set<String> = [
            "snapshot_id", "captured_at", "kind", "row_id", "title",
            "subtitle", "recurrence_count", "confidence", "last_seen_at",
            "window_days",
        ]
        #expect(cols == expected, "table_info columns: \(cols.sorted())")

        // Auxiliary table — must NOT carry chained-row columns.
        #expect(!cols.contains("entry_hash"))
        #expect(!cols.contains("prev_hash"))
        #expect(!cols.contains("chain_anchor_id"))

        let indexes: Set<String> = db.queue.sync {
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "PRAGMA index_list(sprint_review_snapshots);", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var set: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                set.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return set
        }
        #expect(indexes.contains("idx_sprint_review_snapshots_kind_row"))
        #expect(indexes.contains("idx_sprint_review_snapshots_captured_at"))
    }

    // MARK: - 2. Snapshot write

    @Test("snapshot(db:now:snapshot:) writes one row per SprintReviewRow with shared captured_at")
    func snapshotWritesRowsWithSharedTimestamp() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [
            makeRow(id: "r1", kind: .filterRule, title: "t1"),
            makeRow(id: "r2", kind: .contextDoc, title: "t2"),
            makeRow(id: "r3", kind: .workflowPlaybook, title: "t3"),
        ]
        let snap = makeSnapshot(rows)
        SprintReviewViewModel.snapshot(db: db, now: now, snapshot: snap, env: [:])

        #expect(snapshotsCount(db: db) == 3)

        let (capturedAts, kinds): (Set<Int64>, Set<String>) = db.queue.sync {
            guard let h = db.db else { return ([], []) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "SELECT captured_at, kind FROM sprint_review_snapshots;", -1, &stmt, nil) == SQLITE_OK else { return ([], []) }
            defer { sqlite3_finalize(stmt) }
            var ats: Set<Int64> = []
            var ks: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ats.insert(sqlite3_column_int64(stmt, 0))
                ks.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return (ats, ks)
        }
        #expect(capturedAts.count == 1, "all rows in one snapshot batch share captured_at")
        #expect(capturedAts.first == Int64(now.timeIntervalSince1970 * 1000))
        #expect(kinds == ["filterRule", "contextDoc", "workflowPlaybook"])
    }

    // MARK: - 3. Chain walk

    @Test("Provider.versions returns chain sorted captured_at ASC with monotonic version + previousVersion")
    func providerVersionsReturnsChain() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let baseRow = makeRow(id: "stable-id", kind: .filterRule, title: "rule-X")
        let snap = makeSnapshot([baseRow])

        // Three successive snapshots of the same signal-id.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in [0, 60, 120] {
            SprintReviewViewModel.snapshot(
                db: db,
                now: t0.addingTimeInterval(TimeInterval(offset)),
                snapshot: snap,
                env: [:])
        }
        #expect(snapshotsCount(db: db) == 3)

        let provider = SprintReviewArtifactProvider(database: db)
        let id = ArtifactID(sourcePane: .sprintReview, surfaceKey: "filterRule", rowOrPath: "stable-id")
        let chain = provider.versions(of: id)
        #expect(chain.count == 3, "expected 3 records, got \(chain.count)")
        #expect(chain.map { $0.version } == [1, 2, 3])
        #expect(chain[0].previousVersion == nil)
        #expect(chain[1].previousVersion == chain[0].id)
        #expect(chain[2].previousVersion == chain[1].id)
        // captured_at ASC: each createdAt >= the prior.
        for i in 1..<chain.count {
            #expect(chain[i].createdAt >= chain[i - 1].createdAt)
        }
    }

    // MARK: - 4. Retention default

    @Test("snapshot prunes rows older than retentionDays default (30d) on next write")
    func retentionDefaultPrunesOldSnapshots() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = makeSnapshot([makeRow(id: "r")])
        SprintReviewViewModel.snapshot(db: db, now: t0, snapshot: snap, env: [:])
        #expect(snapshotsCount(db: db) == 1)

        // Advance by 31 days; the next snapshot's prune pass deletes
        // the original (now > 30d old).
        let t1 = t0.addingTimeInterval(86_400 * 31)
        SprintReviewViewModel.snapshot(db: db, now: t1, snapshot: snap, env: [:])

        let (kept, capturedAts): (Int, Set<Int64>) = db.queue.sync {
            guard let h = db.db else { return (0, []) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "SELECT captured_at FROM sprint_review_snapshots;", -1, &stmt, nil) == SQLITE_OK else { return (0, []) }
            defer { sqlite3_finalize(stmt) }
            var ats: Set<Int64> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ats.insert(sqlite3_column_int64(stmt, 0))
            }
            return (ats.count, ats)
        }
        #expect(kept == 1, "the older snapshot must be pruned")
        #expect(capturedAts.first == Int64(t1.timeIntervalSince1970 * 1000))
    }

    // MARK: - 5. Retention env override

    @Test("SENKANI_SPRINT_REVIEW_RETENTION_DAYS env override shrinks window")
    func retentionEnvOverridePrunes() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let env = ["SENKANI_SPRINT_REVIEW_RETENTION_DAYS": "7"]
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = makeSnapshot([makeRow(id: "r")])
        SprintReviewViewModel.snapshot(db: db, now: t0, snapshot: snap, env: env)
        #expect(snapshotsCount(db: db) == 1)

        // Advance by 8 days — under default 30 the original would
        // survive, under env=7 it's pruned.
        let t1 = t0.addingTimeInterval(86_400 * 8)
        SprintReviewViewModel.snapshot(db: db, now: t1, snapshot: snap, env: env)

        #expect(snapshotsCount(db: db) == 1)
        let capturedAts: Set<Int64> = db.queue.sync {
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "SELECT captured_at FROM sprint_review_snapshots;", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var ats: Set<Int64> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ats.insert(sqlite3_column_int64(stmt, 0))
            }
            return ats
        }
        #expect(capturedAts.first == Int64(t1.timeIntervalSince1970 * 1000))
    }

    // MARK: - 6. ChainVerifier no-regression smoke (corrigendum)

    @Test("ChainVerifier.verifyTokenEvents passes after v34 — auxiliary table did not perturb chain")
    func chainVerifierNoRegression() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        // Write a token_events row through the per-test db so a
        // chain anchor + entry_hash exist. Stays out of the shared
        // SessionDatabase.
        db.recordTokenEvent(
            sessionId: "test-session",
            paneId: nil,
            projectRoot: "/tmp/v34-chain",
            source: "test",
            toolName: "smoke",
            model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "smoke.test",
            command: nil,
            modelTier: nil)

        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break
        default:
            Issue.record("ChainVerifier expected .ok after v34 migration, got \(result)")
        }
    }
}
