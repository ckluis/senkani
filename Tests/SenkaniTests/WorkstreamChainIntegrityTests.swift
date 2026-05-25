import Testing
import Foundation
import SQLite3
@testable import Core

/// U.11-pre a-3 — `workstream.<event>` chained-row writer + v38
/// anchor + ChainVerifier extension. Three chain-integrity tests
/// covering the three acceptance bullets:
///
///   1. `chainIntegrityHoldsAcross100LifecycleEvents` — single
///      workstream, 100 chained events (1 start + 49×pause/resume +
///      1 archive), `ChainVerifier.verifyTokenEvents` returns `.ok`.
///   2. `chainVerifiesAcrossMixedPreV38AndPostV38Anchors` — seed
///      rows under the post-v38 `fresh-install` anchor, then open a
///      second `migration-v38` anchor manually, write workstream
///      rows under it, and verify both anchor segments chain cleanly.
///   3. `driverEmittedRowsVerifyUnderV38Anchor` — exercise the
///      `PaneSessionDriver` actor end-to-end (`start` → `pause` →
///      `resume` → `archive`); for each transition, assert one
///      chained `workstream.<event>` row landed in `token_events`
///      under the v38 anchor, and `ChainVerifier.verifyTokenEvents`
///      returns `.ok`. Proves a-2's untested driver wiring
///      (operator Q3 = rely-on-a-1+a-3) actually emits chained rows.
@Suite("WorkstreamChainIntegrity (U.11-pre a-3)")
struct WorkstreamChainIntegrityTests {

    // MARK: - Helpers

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u11-a3-test-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    /// Flush queued async writes by issuing a sync probe through
    /// `SessionDatabase.queue`.
    private static func flushQueue(_ db: SessionDatabase) {
        _ = db.tokenEventExists(source: "u11-a3-flush", feature: "noop")
    }

    /// Count `token_events` rows whose `source` starts with
    /// `workstream.` — i.e. the rows this round writes.
    private static func workstreamRowCount(_ db: SessionDatabase) -> Int64 {
        var count: Int64 = -1
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                rawDB,
                "SELECT COUNT(*) FROM token_events WHERE source LIKE 'workstream.%';",
                -1, &stmt, nil
            ) == SQLITE_OK else {
                Issue.record("count prepare failed")
                return
            }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = sqlite3_column_int64(stmt, 0)
            }
        }
        return count
    }

    /// Insert a `migration-v38` anchor row directly. Used by test 2
    /// to simulate a post-migration anchor opening after some rows
    /// have already accumulated under the prior `fresh-install`
    /// anchor. Mirrors the migration's anchor-opening SQL exactly.
    /// Returns the new anchor id.
    @discardableResult
    private static func openSecondV38Anchor(_ db: SessionDatabase) -> Int64 {
        var newAnchorId: Int64 = 0
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            let countSQL = "SELECT COUNT(*), COALESCE(MAX(id), 0) FROM token_events;"
            guard sqlite3_prepare_v2(rawDB, countSQL, -1, &stmt, nil) == SQLITE_OK else {
                Issue.record("count prepare failed")
                return
            }
            var rowCount: Int64 = 0
            var maxRowid: Int64 = 0
            if sqlite3_step(stmt) == SQLITE_ROW {
                rowCount = sqlite3_column_int64(stmt, 0)
                maxRowid = sqlite3_column_int64(stmt, 1)
            }
            sqlite3_finalize(stmt)
            guard rowCount > 0 else { return }

            let now = Date().timeIntervalSince1970
            let insertSQL = """
                INSERT INTO chain_anchors
                    (table_name, started_at, started_at_rowid, reason, operator_note)
                VALUES ('token_events', ?, ?, 'migration-v38', NULL);
            """
            var insertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(rawDB, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
                Issue.record("anchor insert prepare failed")
                return
            }
            defer { sqlite3_finalize(insertStmt) }
            sqlite3_bind_double(insertStmt, 1, now)
            sqlite3_bind_int64(insertStmt, 2, maxRowid)
            guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                Issue.record("anchor insert step failed")
                return
            }
            newAnchorId = sqlite3_last_insert_rowid(rawDB)
        }
        // Force the writer to re-resolve the active anchor on its next
        // call. Otherwise the cached `fresh-install` anchor id would
        // beat the freshly-inserted `migration-v38` one.
        db.tokenEventStore.invalidateChainCache()
        return newAnchorId
    }

    // MARK: - Tests

    @Test("T.5 chain integrity holds across 100 lifecycle events on a single workstream")
    func chainIntegrityHoldsAcross100LifecycleEvents() async throws {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let workstreamID = UUID()
        let slug = "u11-a3-storm-\(workstreamID.uuidString.prefix(8))"
        let driver = PaneSessionDriver(
            workstreamID: workstreamID,
            slug: slug,
            database: db)

        // 1 × start (initial insert, state=running)
        // 49 × (pause → resume) ends with state=running
        // 1 × archive
        // Total = 1 + 98 + 1 = 100 chained rows.
        try await driver.start()
        for _ in 0..<49 {
            try await driver.pause()
            try await driver.resume()
        }
        try await driver.archive()

        Self.flushQueue(db)

        // Verify exactly 100 workstream rows wrote.
        let actualCount = Self.workstreamRowCount(db)
        #expect(actualCount == 100,
                "expected 100 chained workstream.* rows after the storm; got \(actualCount)")

        // Chain must verify clean — every prev_hash links, every
        // entry_hash matches the canonical recomputation.
        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break
        default:
            Issue.record("expected .ok after 100 lifecycle events; got \(result)")
        }
    }

    @Test("ChainVerifier passes after migration v38 with mixed pre-v38 / post-v38 rows")
    func chainVerifiesAcrossMixedPreV38AndPostV38Anchors() async throws {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Segment 1: write a few regular token_events rows under the
        // post-v38 `fresh-install` anchor (lazy-created on first
        // write). These represent rows accumulated before any
        // `migration-v38` anchor opens.
        for i in 0..<4 {
            db.recordTokenEvent(
                sessionId: "u11-a3-mixed", paneId: nil, projectRoot: "/tmp/mixed",
                source: "test", toolName: "pre-v38", model: nil,
                inputTokens: i * 10, outputTokens: 0,
                savedTokens: 0, costCents: 0,
                feature: "pre-v38-\(i)", command: nil)
        }
        Self.flushQueue(db)

        // Segment 2: open a fresh `migration-v38` anchor at the
        // current MAX(id), then write workstream rows under it.
        let secondAnchorId = Self.openSecondV38Anchor(db)
        #expect(secondAnchorId > 0,
                "second migration-v38 anchor must be inserted; got id \(secondAnchorId)")

        let workstreamID = UUID()
        let slug = "mixed-anchors-\(workstreamID.uuidString.prefix(8))"
        let driver = PaneSessionDriver(
            workstreamID: workstreamID,
            slug: slug,
            database: db)
        try await driver.start()
        try await driver.pause()
        try await driver.resume()
        try await driver.archive()
        Self.flushQueue(db)

        // Both anchor segments should verify cleanly.
        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break
        default:
            Issue.record("expected .ok across pre-v38 + post-v38 anchor segments; got \(result)")
        }

        // Sanity check: the four workstream rows landed on the
        // second anchor (not the first), so the ChainVerifier
        // really did walk two anchors.
        var perAnchorCounts: [Int64: Int64] = [:]
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                rawDB,
                "SELECT chain_anchor_id, COUNT(*) FROM token_events GROUP BY chain_anchor_id;",
                -1, &stmt, nil
            ) == SQLITE_OK else {
                Issue.record("anchor distribution query prepare failed")
                return
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let anchorId = sqlite3_column_int64(stmt, 0)
                let count = sqlite3_column_int64(stmt, 1)
                perAnchorCounts[anchorId] = count
            }
        }
        let anchorsUsed = perAnchorCounts.count
        #expect(anchorsUsed >= 2,
                "rows must distribute across at least 2 anchors (got \(anchorsUsed) — \(perAnchorCounts))")
        #expect(perAnchorCounts[secondAnchorId] == 4,
                "all 4 workstream rows must land on the second v38 anchor (id \(secondAnchorId)); got \(perAnchorCounts[secondAnchorId] ?? -1)")
    }

    @Test("Driver-emitted rows verify under the v38 anchor — start → pause → resume → archive")
    func driverEmittedRowsVerifyUnderV38Anchor() async throws {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let workstreamID = UUID()
        let slug = "driver-emission-\(workstreamID.uuidString.prefix(8))"
        let driver = PaneSessionDriver(
            workstreamID: workstreamID,
            slug: slug,
            database: db)

        // Drive a complete happy-path lifecycle and confirm every
        // driver method call produces exactly one chained
        // `workstream.<event>` row. This is the test that proves
        // a-2's driver wiring (untested in a-2 per operator Q3 =
        // rely-on-a-1+a-3) actually emits chained rows.
        try await driver.start()
        Self.flushQueue(db)
        #expect(Self.workstreamRowCount(db) == 1, "after start: expected 1 chained row")

        try await driver.pause()
        Self.flushQueue(db)
        #expect(Self.workstreamRowCount(db) == 2, "after pause: expected 2 chained rows")

        try await driver.resume()
        Self.flushQueue(db)
        #expect(Self.workstreamRowCount(db) == 3, "after resume: expected 3 chained rows")

        try await driver.archive()
        Self.flushQueue(db)
        #expect(Self.workstreamRowCount(db) == 4, "after archive: expected 4 chained rows")

        // Verify the rows landed in event order with the correct
        // `source` values + identity columns.
        var rows: [(source: String, toolName: String, feature: String)] = []
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                rawDB,
                """
                SELECT source, tool_name, feature
                  FROM token_events
                 WHERE source LIKE 'workstream.%'
                 ORDER BY id ASC;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else {
                Issue.record("source listing prepare failed")
                return
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let src = String(cString: sqlite3_column_text(stmt, 0))
                let tool = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let feat = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                rows.append((src, tool, feat))
            }
        }
        let expectedSources: [String] = [
            "workstream.start", "workstream.pause",
            "workstream.resume", "workstream.archive",
        ]
        #expect(rows.map { $0.source } == expectedSources,
                "driver methods must produce events in order: \(expectedSources); got \(rows.map { $0.source })")
        let uuidString = workstreamID.uuidString
        for row in rows {
            #expect(row.toolName == uuidString,
                    "each workstream row's tool_name must hold the UUID string (\(uuidString)); got '\(row.toolName)'")
            #expect(row.feature == slug,
                    "each workstream row's feature must hold the slug ('\(slug)'); got '\(row.feature)'")
        }

        // Final chain integrity check across all 4 driver-emitted
        // rows under the v38 anchor.
        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break
        default:
            Issue.record("expected .ok after driver-emitted lifecycle; got \(result)")
        }
    }
}
