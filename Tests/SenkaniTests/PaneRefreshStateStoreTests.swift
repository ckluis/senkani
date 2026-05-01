import Testing
import Foundation
import SQLite3
@testable import Core

@Suite("PaneRefreshStateStore — V.1 round 2 persistence")
struct PaneRefreshStateStoreTests {

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-prss-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func cleanup(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }

    // MARK: - Migration shape

    @Test("Migration v6 creates pane_refresh_state with chain columns")
    func migrationCreatesTable() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        // Sanity: schema_version >= 6.
        #expect(db.currentSchemaVersion() >= 6)

        // Round-trip a row to confirm the table accepts the chain columns.
        let state = PaneRefreshState(
            cacheType: .duration, cacheDuration: 30,
            nextUpdate: Date(timeIntervalSince1970: 1_700_000_000),
            contentAvailable: true
        )
        db.recordPaneRefreshState(
            projectRoot: "/tmp/proj", tileId: "budget_burn", state: state
        )
        db.flushWrites()

        guard let read = db.paneRefreshState(projectRoot: "/tmp/proj", tileId: "budget_burn") else {
            Issue.record("expected a persisted state")
            return
        }
        #expect(read.cacheType == .duration)
        #expect(read.cacheDuration == 30)
        #expect(read.contentAvailable == true)
    }

    // MARK: - Append-only semantics + latest-per-tile

    @Test("Successive writes return the latest per (project_root, tile_id)")
    func appendOnlyLatestWins() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        let projectRoot = "/tmp/proj-latest"

        let s1 = PaneRefreshState(cacheType: .duration, cacheDuration: 5,
                                  nextUpdate: .distantPast, contentAvailable: false)
        let s2 = PaneRefreshState(cacheType: .duration, cacheDuration: 5,
                                  nextUpdate: Date(timeIntervalSince1970: 1_700_000_100),
                                  contentAvailable: true)

        db.recordPaneRefreshState(projectRoot: projectRoot, tileId: "validation_queue", state: s1)
        db.recordPaneRefreshState(projectRoot: projectRoot, tileId: "validation_queue", state: s2)
        db.flushWrites()

        guard let read = db.paneRefreshState(projectRoot: projectRoot, tileId: "validation_queue") else {
            Issue.record("missing state")
            return
        }
        #expect(read.contentAvailable == true)
        #expect(read.nextUpdate == s2.nextUpdate)
    }

    @Test("latestStates returns one row per tile")
    func bulkRehydrate() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        let projectRoot = "/tmp/proj-bulk"

        db.recordPaneRefreshState(
            projectRoot: projectRoot, tileId: "budget_burn",
            state: PaneRefreshState(cacheType: .duration, cacheDuration: 30, contentAvailable: true)
        )
        db.recordPaneRefreshState(
            projectRoot: projectRoot, tileId: "validation_queue",
            state: PaneRefreshState(cacheType: .duration, cacheDuration: 5,
                                    notice: "fixture notice", contentAvailable: true)
        )
        db.recordPaneRefreshState(
            projectRoot: projectRoot, tileId: "repo_dirty_state",
            state: PaneRefreshState(cacheType: .duration, cacheDuration: 10, contentAvailable: false)
        )
        // Second write under one tile to confirm the GROUP BY MAX(id) shape.
        db.recordPaneRefreshState(
            projectRoot: projectRoot, tileId: "validation_queue",
            state: PaneRefreshState(cacheType: .duration, cacheDuration: 5, contentAvailable: true)
        )
        db.flushWrites()

        let states = db.paneRefreshStates(projectRoot: projectRoot)
        #expect(states.count == 3)
        #expect(states["budget_burn"]?.contentAvailable == true)
        #expect(states["validation_queue"]?.notice == nil) // newer row had no notice
        #expect(states["repo_dirty_state"]?.contentAvailable == false)
    }

    // MARK: - Chain integration

    @Test("Chain verification is OK after a clean write sequence")
    func chainVerifiesAfterWrites() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        let projectRoot = "/tmp/proj-chain"
        for i in 0..<5 {
            db.recordPaneRefreshState(
                projectRoot: projectRoot, tileId: "budget_burn",
                state: PaneRefreshState(cacheType: .duration, cacheDuration: 30,
                                        retryCount: i, contentAvailable: true)
            )
        }
        db.flushWrites()

        let result = ChainVerifier.verifyPaneRefreshState(db)
        switch result {
        case .ok: break
        default: Issue.record("expected ok, got \(result)")
        }
    }

    @Test("Tampering a persisted column flips chain verification to brokenAt")
    func tamperFailsVerification() throws {
        let (db, path) = Self.makeDB()
        let projectRoot = "/tmp/proj-tamper"
        for i in 0..<3 {
            db.recordPaneRefreshState(
                projectRoot: projectRoot, tileId: "budget_burn",
                state: PaneRefreshState(cacheType: .duration, cacheDuration: 30,
                                        retryCount: i, contentAvailable: true)
            )
        }
        db.flushWrites()
        db.close()

        // Tamper with a separate raw connection so the next SessionDatabase
        // open sees the divergence.
        var rawDB: OpaquePointer?
        guard sqlite3_open(path, &rawDB) == SQLITE_OK else {
            Issue.record("could not open db for tamper")
            return
        }
        let sql = "UPDATE pane_refresh_state SET notice = 'tampered' WHERE id = 2;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(rawDB, sql, -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("prepare failed")
            sqlite3_close(rawDB)
            return
        }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)
        sqlite3_close(rawDB)

        let verify = SessionDatabase(path: path)
        defer { verify.close(); Self.cleanup(path) }

        let result = ChainVerifier.verifyPaneRefreshState(verify)
        switch result {
        case .brokenAt(_, let rowid, _, _):
            // The walker re-hashes from the first non-NULL row; the
            // divergence may surface at the tampered row OR at the next row
            // (whose prev_hash references the now-divergent entry hash).
            // Either is a correct positive detection.
            #expect(rowid == 2 || rowid == 3,
                    "expected tamper to surface at row 2 or 3, got \(rowid)")
        default:
            Issue.record("expected brokenAt, got \(result)")
        }
    }
}
