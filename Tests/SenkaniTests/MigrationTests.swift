import Testing
import Foundation
import SQLite3
@testable import Core

/// Tests for the P1-4 schema migration system. Uses in-memory SQLite and programmatic
/// fixture setup — cleaner than committing binary `.db` files and keeps each state's
/// construction transparent to the reader.
@Suite("MigrationRunner")
struct MigrationRunnerTests {

    // MARK: - Helpers

    /// Open an in-memory DB. Caller closes.
    private static func openMemory() -> OpaquePointer {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        return db!
    }

    /// Create the `commands` and `sessions` tables without the historical ALTER'd columns
    /// — simulates a DB from before the three ALTER migrations shipped.
    private static func buildLegacyPreAlterSchema(_ db: OpaquePointer) {
        exec(db, """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                started_at REAL NOT NULL
            );
        """)
        exec(db, """
            CREATE TABLE commands (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                tool_name TEXT NOT NULL
            );
        """)
    }

    /// Create the full current-production schema: base + all 3 ALTER'd columns
    /// but NO schema_migrations table. This is what existing users' DBs look like.
    private static func buildCurrentProductionSchema(_ db: OpaquePointer) {
        buildLegacyPreAlterSchema(db)
        exec(db, "ALTER TABLE commands ADD COLUMN budget_decision TEXT;")
        exec(db, "ALTER TABLE sessions ADD COLUMN project_root TEXT;")
        exec(db, "ALTER TABLE sessions ADD COLUMN agent_type TEXT;")
    }

    /// Execute a SQL statement; fail the test if it returns non-OK.
    private static func exec(_ db: OpaquePointer, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err {
            let msg = String(cString: err)
            sqlite3_free(err)
            Issue.record("SQL failed: \(msg)")
        }
        #expect(rc == SQLITE_OK)
    }

    /// Count rows in schema_migrations.
    private static func appliedCount(_ db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM schema_migrations;", -1, &stmt, nil) == SQLITE_OK
        else { return -1 }
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Check if a table exists.
    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;",
                -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Fixtures (test matrix per the plan)

    /// Registry shipping in the product at test-authoring time.
    /// `MigrationRegistry.all` contains every shipped migration, so the
    /// assertion "v1 baseline + v2 event_counters" is the current-truth
    /// baseline. Tests that want to isolate v1-only behavior use
    /// `[v1Only]` explicitly.
    private static let v1Only: [Migration] = [MigrationRegistry.all.first { $0.version == 1 }!]

    @Test("fresh DB at current version after baseline")
    func freshDBBaselines() throws {
        let db = Self.openMemory()
        defer { sqlite3_close(db) }

        Self.buildCurrentProductionSchema(db)
        let report = try MigrationRunner.run(db: db, dbPath: ":memory:")

        #expect(Self.tableExists(db, "schema_migrations"))
        // Baseline stamps v1 (legacy columns present), then runner applies
        // any newer migrations in the registry (currently v2 = event_counters).
        #expect(Self.appliedCount(db) == MigrationRegistry.all.count,
                "baseline v1 + every post-v1 migration must land")
        #expect(MigrationRunner.currentVersion(db: db)
                == MigrationRegistry.all.map(\.version).max()!)
        #expect(report.appliedVersions == MigrationRegistry.all
                    .map(\.version).filter { $0 >= 2 },
                "appliedVersions reports only the >=v2 migrations that actually ran up()")
    }

    @Test("legacy pre-ALTER DB is NOT baselined — v1 runs via runner, not as stamped baseline")
    func legacyDBNotBaselined() throws {
        let db = Self.openMemory()
        defer { sqlite3_close(db) }

        Self.buildLegacyPreAlterSchema(db) // missing all 3 ALTER'd columns
        let report = try MigrationRunner.run(db: db, dbPath: ":memory:", registry: Self.v1Only)

        // Baselining didn't fire (legacy columns absent), so v1 ran through the runner
        // and appears in report.appliedVersions. Scoped to v1Only so the test is
        // insulated from future migrations added to MigrationRegistry.all.
        #expect(Self.tableExists(db, "schema_migrations"))
        #expect(report.appliedVersions == [1], "v1 must run as a migration, not as a baseline stamp")
        #expect(Self.appliedCount(db) == 1)
        #expect(MigrationRunner.currentVersion(db: db) == 1)
    }

    @Test("partially-migrated DB is NOT baselined — conservative fallthrough to runner")
    func partiallyMigratedDBNotBaselined() throws {
        let db = Self.openMemory()
        defer { sqlite3_close(db) }

        Self.buildLegacyPreAlterSchema(db)
        Self.exec(db, "ALTER TABLE commands ADD COLUMN budget_decision TEXT;")
        // Missing sessions.project_root and sessions.agent_type — partial state.
        // Scoped to v1Only for the same "insulate from future migrations" reason.
        let report = try MigrationRunner.run(db: db, dbPath: ":memory:", registry: Self.v1Only)

        #expect(report.appliedVersions == [1],
                "partial state must run v1 via the runner, not via baseline stamping")
        #expect(Self.appliedCount(db) == 1)
    }

    @Test("second run is idempotent")
    func secondRunIsIdempotent() throws {
        let db = Self.openMemory()
        defer { sqlite3_close(db) }

        Self.buildCurrentProductionSchema(db)
        _ = try MigrationRunner.run(db: db, dbPath: ":memory:")
        let firstCount = Self.appliedCount(db)

        _ = try MigrationRunner.run(db: db, dbPath: ":memory:")
        let secondCount = Self.appliedCount(db)

        #expect(firstCount == secondCount,
                "re-running the migration runner must not duplicate rows in schema_migrations")
    }

    @Test("future migration applies atomically and stamps both log + user_version")
    func futureMigrationAppliesAtomically() throws {
        let db = Self.openMemory()
        defer { sqlite3_close(db) }

        Self.buildCurrentProductionSchema(db)
        _ = try MigrationRunner.run(db: db, dbPath: ":memory:")

        // Hypothetical future migration numbered ONE past the currently-shipped
        // max so it doesn't collide with real v2 (event_counters).
        let futureVersion = (MigrationRegistry.all.map(\.version).max() ?? 1) + 1
        let future = Migration(version: futureVersion,
                               description: "add example_table (test)") { db in
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, "CREATE TABLE example_table (id INTEGER PRIMARY KEY);", nil, nil, &err)
            if let err = err { sqlite3_free(err) }
            if rc != SQLITE_OK {
                throw MigrationError.sqlFailed(stage: "future", detail: "CREATE TABLE failed")
            }
        }
        let registry = MigrationRegistry.all + [future]
        let report = try MigrationRunner.run(db: db, dbPath: ":memory:", registry: registry)

        #expect(report.appliedVersions == [futureVersion],
                "only the un-applied future migration runs")
        #expect(Self.tableExists(db, "example_table"))
        #expect(MigrationRunner.currentVersion(db: db) == futureVersion)
        #expect(Self.appliedCount(db) == MigrationRegistry.all.count + 1,
                "schema_migrations has every shipped migration + our future one")
    }

    @Test("failed migration triggers rollback, lockfile, and re-throws")
    func failedMigrationRollsBackAndWritesLockfile() throws {
        let tmpDir = NSTemporaryDirectory() + "migration-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let dbPath = tmpDir + "test.db"

        var db: OpaquePointer?
        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        Self.buildCurrentProductionSchema(db!)
        _ = try MigrationRunner.run(db: db!, dbPath: dbPath)
        let baselineApplied = Self.appliedCount(db!)
        let baselineVersion = MigrationRunner.currentVersion(db: db!)

        let futureVersion = (MigrationRegistry.all.map(\.version).max() ?? 1) + 1
        let badMigration = Migration(version: futureVersion,
                                     description: "guaranteed to fail") { db in
            // Reference a non-existent table — SQLite raises "no such table".
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, "DELETE FROM ghost_table;", nil, nil, &err)
            if let err = err { sqlite3_free(err) }
            if rc != SQLITE_OK {
                throw MigrationError.sqlFailed(stage: "bad", detail: "no such table")
            }
        }
        let registry = MigrationRegistry.all + [badMigration]

        var threw = false
        do {
            _ = try MigrationRunner.run(db: db!, dbPath: dbPath, registry: registry)
        } catch {
            threw = true
        }
        #expect(threw, "bad migration must throw")
        #expect(FileManager.default.fileExists(atPath: dbPath + ".schema.lock"),
                "lockfile must be written on failure")
        #expect(Self.appliedCount(db!) == baselineApplied,
                "failed migration must not leave a row")
        #expect(MigrationRunner.currentVersion(db: db!) == baselineVersion,
                "user_version must not advance on failure")
    }

    /// Bach G2: the P1-4 plan required verifying the `flock` sidecar
    /// coordinates multi-process migration. Intra-process validation is
    /// infeasible here because macOS flock is a per-process advisory lock:
    /// two `Task.detached` handles in the same test process hold the same
    /// process-level lock and both proceed concurrently, triggering
    /// SQLite "table already exists" on the second DDL. That behavior is
    /// correct for production (MCP server and GUI app are separate
    /// processes), but not exercisable in-process.
    ///
    /// What we CAN verify in-process: sequential runners on the same DB
    /// are idempotent, and the flock file is actually opened and locked
    /// during a run. The true cross-process race is a follow-up test
    /// that requires spawning a helper subprocess (see Bach findings
    /// doc, G2 note).
    @Test("sequential runners on same DB: second is a no-op after first")
    func sequentialRunnersAreIdempotent() async throws {
        let tmpDir = NSTemporaryDirectory() + "mig-seq-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let dbPath = tmpDir + "seq.db"

        var seed: OpaquePointer?
        #expect(sqlite3_open(dbPath, &seed) == SQLITE_OK)
        sqlite3_exec(seed, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_busy_timeout(seed, 5000)
        Self.buildCurrentProductionSchema(seed!)
        sqlite3_close(seed)

        // Use a version past the currently-shipped max so we don't collide
        // with the real v2 (event_counters) in MigrationRegistry.all.
        let futureVersion = (MigrationRegistry.all.map(\.version).max() ?? 1) + 1
        let futureMig = Migration(version: futureVersion, description: "seq-add-table") { db in
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, "CREATE TABLE seq_future (id INTEGER PRIMARY KEY);", nil, nil, &err)
            if let err = err { sqlite3_free(err) }
            guard rc == SQLITE_OK else {
                throw MigrationError.sqlFailed(stage: "seq-future", detail: "create failed rc=\(rc)")
            }
        }
        let registry = MigrationRegistry.all + [futureMig]

        // Runner A — applies all un-applied migrations (including futureMig).
        var dbA: OpaquePointer?
        #expect(sqlite3_open(dbPath, &dbA) == SQLITE_OK)
        sqlite3_busy_timeout(dbA, 5000)
        let reportA = try MigrationRunner.run(db: dbA!, dbPath: dbPath, registry: registry)
        sqlite3_close(dbA)
        #expect(reportA.appliedVersions.contains(futureVersion),
                "first runner applies futureMig, got \(reportA.appliedVersions)")

        // Runner B — fresh connection, reads everything applied, does nothing.
        var dbB: OpaquePointer?
        #expect(sqlite3_open(dbPath, &dbB) == SQLITE_OK)
        sqlite3_busy_timeout(dbB, 5000)
        let reportB = try MigrationRunner.run(db: dbB!, dbPath: dbPath, registry: registry)
        #expect(reportB.appliedVersions.isEmpty,
                "second runner is a no-op, got \(reportB.appliedVersions)")
        #expect(MigrationRunner.currentVersion(db: dbB!) == futureVersion)
        #expect(Self.tableExists(dbB!, "seq_future"))
        sqlite3_close(dbB)

        // Sidecar flock file is created during run().
        #expect(FileManager.default.fileExists(atPath: dbPath + ".migrating"),
                "flock sidecar must exist after a run() call")
    }

    @Test("lockfile refuses subsequent runs until removed")
    func lockfileRefusesRun() throws {
        let tmpDir = NSTemporaryDirectory() + "migration-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let dbPath = tmpDir + "test.db"
        let lockPath = dbPath + ".schema.lock"

        // Plant a lockfile.
        try "failed".data(using: .utf8)!.write(to: URL(fileURLWithPath: lockPath))

        var db: OpaquePointer?
        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        var threw = false
        do {
            _ = try MigrationRunner.run(db: db!, dbPath: dbPath)
        } catch MigrationError.lockfilePresent {
            threw = true
        } catch {
            Issue.record("Expected lockfilePresent, got \(error)")
        }
        #expect(threw)
    }
}
