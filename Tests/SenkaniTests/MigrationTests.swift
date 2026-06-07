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

    @Test("v21 backfills claude_session_cursors with reader='watcher' and rebuilds PK")
    func migration21BackfillsReaderColumn() throws {
        // Per claude-session-cursor-turn-index-ownership-conflict-2026-05-15:
        // Migration 21 must rebuild the legacy single-column-PK
        // `claude_session_cursors` table into a composite (path, reader)
        // PK, backfilling existing rows to reader='watcher' with
        // byte_offset, turn_index, and updated_at preserved bit-identical.
        let db = Self.openMemory()
        defer { sqlite3_close(db) }

        // Seed the legacy schema (pre-migration shape: PRIMARY KEY (path)).
        Self.exec(db, """
            CREATE TABLE claude_session_cursors (
                path TEXT PRIMARY KEY,
                byte_offset INTEGER NOT NULL DEFAULT 0,
                turn_index INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL
            );
        """)

        // Three rows with distinct (path, byte_offset, turn_index,
        // updated_at) — covers default values plus a non-trivial row.
        Self.exec(db, """
            INSERT INTO claude_session_cursors (path, byte_offset, turn_index, updated_at)
            VALUES
              ('/tmp/a.jsonl', 100, 1, 1700000000.0),
              ('/tmp/b.jsonl', 250, 5, 1700000100.5),
              ('/tmp/c.jsonl',   0, 0, 1700000200.25);
        """)

        // Run all migrations including v21. The runner walks v1..v21 in
        // order; v1-v20 are idempotent against the unrelated tables we
        // haven't created (CREATE … IF NOT EXISTS / ADD COLUMN guarded).
        _ = try MigrationRunner.run(db: db, dbPath: ":memory:", registry: MigrationRegistry.all)

        // Post-migration: `reader` column must exist with default 'watcher'.
        var hasReader = false
        var infoStmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "PRAGMA table_info(claude_session_cursors);", -1, &infoStmt, nil) == SQLITE_OK)
        while sqlite3_step(infoStmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(infoStmt, 1),
               String(cString: c) == "reader" {
                hasReader = true
            }
        }
        sqlite3_finalize(infoStmt)
        #expect(hasReader, "reader column missing after v21")

        // The composite PK must list (path, reader). PRAGMA index_list +
        // index_info would be the canonical check; the simpler shape
        // assertion is "every row has a non-NULL reader and the count
        // matches the seeded rows" — UNIQUE on (path) alone was the
        // pre-migration constraint, so a second row with the same path
        // but different reader must be insertable post-migration.
        var insertStmt: OpaquePointer?
        let insertSQL = """
            INSERT INTO claude_session_cursors (path, byte_offset, turn_index, updated_at, reader)
            VALUES ('/tmp/a.jsonl', 999, 99, 1700000300.0, 'reader');
        """
        #expect(sqlite3_exec(db, insertSQL, nil, nil, nil) == SQLITE_OK,
                "post-migration must permit (same path, different reader); composite PK absent")
        sqlite3_finalize(insertStmt)

        // Every pre-existing row backfilled to reader='watcher', with
        // byte_offset / turn_index / updated_at bit-identical to seed.
        var stmt: OpaquePointer?
        let sql = """
            SELECT path, byte_offset, turn_index, updated_at, reader
            FROM claude_session_cursors
            WHERE reader = 'watcher'
            ORDER BY path;
        """
        #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        struct Row { let path: String; let byteOffset: Int64; let turnIndex: Int64; let updatedAt: Double }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Row(
                path: String(cString: sqlite3_column_text(stmt, 0)),
                byteOffset: sqlite3_column_int64(stmt, 1),
                turnIndex: sqlite3_column_int64(stmt, 2),
                updatedAt: sqlite3_column_double(stmt, 3)
            ))
        }

        #expect(rows.count == 3, "expected 3 backfilled rows, got \(rows.count)")
        #expect(rows[0].path == "/tmp/a.jsonl")
        #expect(rows[0].byteOffset == 100)
        #expect(rows[0].turnIndex == 1)
        #expect(rows[0].updatedAt == 1700000000.0, "updated_at preserved bit-identical")
        #expect(rows[1].path == "/tmp/b.jsonl")
        #expect(rows[1].byteOffset == 250)
        #expect(rows[1].turnIndex == 5)
        #expect(rows[1].updatedAt == 1700000100.5)
        #expect(rows[2].path == "/tmp/c.jsonl")
        #expect(rows[2].byteOffset == 0)
        #expect(rows[2].turnIndex == 0)
        #expect(rows[2].updatedAt == 1700000200.25)
    }

    @Test("v21 is a no-op when claude_session_cursors does not exist (fresh-install path)")
    func migration21NoOpOnFreshInstall() throws {
        // Fresh installs: MigrationRunner runs BEFORE TokenEventStore.
        // setupSchema, so claude_session_cursors does not yet exist. v21
        // must no-op rather than fail. setupSchema then creates the
        // post-migration shape directly.
        let db = Self.openMemory()
        defer { sqlite3_close(db) }

        // Run all migrations against a database with no claude_session_cursors.
        _ = try MigrationRunner.run(db: db, dbPath: ":memory:", registry: MigrationRegistry.all)

        // Table should still not exist (v21 didn't create it — setupSchema does).
        #expect(!Self.tableExists(db, "claude_session_cursors"),
                "v21 must not create claude_session_cursors; setupSchema does that on fresh installs")
    }

    @Test("v21 is idempotent — running twice over an already-migrated table is a no-op")
    func migration21IdempotentReentry() throws {
        let db = Self.openMemory()
        defer { sqlite3_close(db) }

        // Seed the post-migration shape directly (simulates a DB that
        // already ran v21 but lost its schema_migrations row somehow —
        // matches the same defense ALTERs use elsewhere).
        Self.exec(db, """
            CREATE TABLE claude_session_cursors (
                path TEXT NOT NULL,
                byte_offset INTEGER NOT NULL DEFAULT 0,
                turn_index INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL,
                reader TEXT NOT NULL DEFAULT 'watcher',
                PRIMARY KEY (path, reader)
            );
        """)
        Self.exec(db, """
            INSERT INTO claude_session_cursors (path, byte_offset, turn_index, updated_at, reader)
            VALUES ('/tmp/already.jsonl', 42, 3, 1700000500.0, 'reader');
        """)

        _ = try MigrationRunner.run(db: db, dbPath: ":memory:", registry: MigrationRegistry.all)

        // Row survives unchanged — v21 hit the `hasReader` early-return path.
        var stmt: OpaquePointer?
        let sql = "SELECT byte_offset, turn_index, updated_at, reader FROM claude_session_cursors WHERE path = '/tmp/already.jsonl';"
        #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int64(stmt, 0) == 42)
        #expect(sqlite3_column_int64(stmt, 1) == 3)
        #expect(sqlite3_column_double(stmt, 2) == 1700000500.0)
        #expect(String(cString: sqlite3_column_text(stmt, 3)) == "reader",
                "reader-identity preserved through idempotent re-run")
    }

    // MARK: - U.2a-1 migration v22 (validation_results axes columns)

    /// Seed a populated `validation_results` table in its pre-v22 shape,
    /// then run all migrations to confirm v22 adds the five new columns
    /// without disturbing existing rows. The pre-v22 shape is the result
    /// of v3 + v5 (validation outcome metadata + T.5 chain extension).
    /// Seed a `trust_audits` table in its v12 / pre-v25 shape so
    /// migration v25 has a table to ALTER. v25 only adds three
    /// nullable columns (observed_rate, observed_sample, call_id);
    /// no rows are needed.
    private static func seedPreV25TrustAudits(_ db: OpaquePointer) {
        exec(db, """
            CREATE TABLE trust_audits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                created_at REAL NOT NULL,
                session_id TEXT,
                pane_id TEXT,
                tool_name TEXT,
                reason TEXT,
                score INTEGER,
                correlation_count INTEGER,
                flag_id INTEGER,
                label TEXT,
                labeled_by TEXT,
                prev_hash TEXT,
                entry_hash TEXT,
                chain_anchor_id INTEGER
            );
        """)
    }

    private static func seedPreV22ValidationResults(_ db: OpaquePointer) {
        exec(db, """
            CREATE TABLE validation_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                validator_name TEXT NOT NULL,
                category TEXT NOT NULL,
                exit_code INTEGER NOT NULL,
                raw_output TEXT,
                advisory TEXT NOT NULL,
                duration_ms INTEGER NOT NULL,
                created_at REAL NOT NULL,
                delivered INTEGER DEFAULT 0,
                outcome TEXT NOT NULL DEFAULT 'advisory',
                reason TEXT,
                surfaced_at REAL,
                prev_hash TEXT,
                entry_hash TEXT,
                chain_anchor_id INTEGER
            );
        """)
        exec(db, """
            INSERT INTO validation_results
              (session_id, file_path, validator_name, category, exit_code, advisory,
               duration_ms, created_at, outcome)
            VALUES
              ('s1', '/tmp/a.swift', 'swiftc', 'syntax', 1, 'lint fail',
               42, 1700000000.0, 'advisory'),
              ('s2', '/tmp/b.swift', 'swiftc', 'syntax', 0, 'ok',
               18, 1700000010.0, 'clean'),
              ('s3', '/tmp/c.swift', 'rubocop', 'lint', 2, 'forbid',
               99, 1700000020.0, 'blocking');
        """)
    }

    /// Seed a `egress_decisions` table in its post-v19 / pre-v23 shape so
    /// migration v23 has something to ALTER. Also seeds the `chain_anchors`
    /// table (originally created at v4) so v23's anchor-rename + anchor-
    /// open SQL has a destination.
    private static func seedPreV23EgressDecisions(_ db: OpaquePointer) {
        exec(db, """
            CREATE TABLE IF NOT EXISTS chain_anchors (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                table_name TEXT NOT NULL,
                started_at REAL NOT NULL,
                started_at_rowid INTEGER NOT NULL,
                reason TEXT NOT NULL,
                operator_note TEXT
            );
        """)
        exec(db, """
            CREATE TABLE egress_decisions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                host TEXT NOT NULL,
                method TEXT NOT NULL,
                decision TEXT NOT NULL,
                rule_id TEXT NOT NULL,
                latency_us INTEGER NOT NULL DEFAULT 0,
                pane_id TEXT,
                project_root TEXT,
                prev_hash TEXT,
                entry_hash TEXT,
                chain_anchor_id INTEGER
            );
        """)
    }

    @Test("v22 adds the five axes/runner columns to validation_results")
    func migration22AddsRunnerColumns() throws {
        let db = Self.openMemory()
        defer { sqlite3_close(db) }

        Self.seedPreV22ValidationResults(db)
        _ = try MigrationRunner.run(db: db, dbPath: ":memory:", registry: MigrationRegistry.all)

        let expected: Set<String> = [
            "axes", "target_url", "plan_steps", "result_status", "screenshot_path",
        ]
        var found: Set<String> = []
        var infoStmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "PRAGMA table_info(validation_results);", -1, &infoStmt, nil) == SQLITE_OK)
        while sqlite3_step(infoStmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(infoStmt, 1) {
                let name = String(cString: c)
                if expected.contains(name) { found.insert(name) }
            }
        }
        sqlite3_finalize(infoStmt)

        #expect(found == expected, "v22 must add axes/target_url/plan_steps/result_status/screenshot_path; missing: \(expected.subtracting(found))")
    }

    @Test("v22 preserves pre-existing validation_results rows with NOT NULL defaults applied")
    func migration22PreservesRowsWithDefaults() throws {
        let db = Self.openMemory()
        defer { sqlite3_close(db) }

        Self.seedPreV22ValidationResults(db)
        _ = try MigrationRunner.run(db: db, dbPath: ":memory:", registry: MigrationRegistry.all)

        var stmt: OpaquePointer?
        let sql = """
            SELECT axes, plan_steps, target_url, screenshot_path
              FROM validation_results
             ORDER BY id ASC;
        """
        #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        var rowCount = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowCount += 1
            #expect(String(cString: sqlite3_column_text(stmt, 0)) == "[]", "axes NOT NULL default '[]' must apply to legacy row")
            #expect(String(cString: sqlite3_column_text(stmt, 1)) == "[]", "plan_steps NOT NULL default '[]' must apply to legacy row")
            #expect(sqlite3_column_type(stmt, 2) == SQLITE_NULL, "target_url nullable; legacy row should be NULL")
            #expect(sqlite3_column_type(stmt, 3) == SQLITE_NULL, "screenshot_path nullable; legacy row should be NULL")
        }
        #expect(rowCount == 3, "all three seeded rows must survive v22 unmodified")
    }

    @Test("v22 backfills result_status from outcome — advisory/clean → pass, blocking → fail")
    func migration22BackfillsResultStatus() throws {
        let db = Self.openMemory()
        defer { sqlite3_close(db) }

        Self.seedPreV22ValidationResults(db)
        _ = try MigrationRunner.run(db: db, dbPath: ":memory:", registry: MigrationRegistry.all)

        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, """
            SELECT outcome, result_status
              FROM validation_results
             ORDER BY id ASC;
        """, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        struct Backfill { let outcome: String; let status: String }
        var rows: [Backfill] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Backfill(
                outcome: String(cString: sqlite3_column_text(stmt, 0)),
                status: String(cString: sqlite3_column_text(stmt, 1))
            ))
        }
        #expect(rows.count == 3)
        #expect(rows[0].outcome == "advisory" && rows[0].status == "pass")
        #expect(rows[1].outcome == "clean" && rows[1].status == "pass")
        #expect(rows[2].outcome == "blocking" && rows[2].status == "fail")
    }

    @Test("v22..v48 advance the migration ledger by exactly twenty-seven rows over a v21-baseline DB")
    func migration22And23AdvanceLedgerByTwo() throws {
        let db = Self.openMemory()
        defer { sqlite3_close(db) }

        // Seed schema_migrations to v21 + a pre-v22 validation_results AND
        // a pre-v23 egress_decisions (created at v19) AND a pre-v25
        // trust_audits (created at v12) so the runner sees exactly ten
        // pending migrations (v22 + v23 + v24 + v25 + v26 + v27 + v28 +
        // v29 + v30 + v31 — v24 ships eval_results self-contained, v25
        // ships trust_audits column ALTERs requiring the v12 table, v26
        // ships session_work_queue + session_event_stream substrate, v27
        // ships surrogate_writes for T.2c-2 AnonymizationProxy, v28
        // renames the trust_audits fresh-install anchor to
        // fresh-install-pre-v25 so the v25-added columns can fold
        // into the canonical hash map under a new migration-v25
        // anchor opened lazily by the writers, v29 mirrors that
        // rename for validation_results so the v22-added columns
        // can fold into the canonical hash map under a new
        // migration-v22 anchor opened lazily by the browser writer,
        // v30 adds runtime_telemetry_{dataset,span,log} for V.18a-1,
        // v31 adds per-table byte counters on runtime_telemetry_dataset
        // for V.18a-2 store + prune).
        Self.seedPreV22ValidationResults(db)
        Self.seedPreV23EgressDecisions(db)
        Self.seedPreV25TrustAudits(db)
        Self.exec(db, """
            CREATE TABLE schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL,
                description TEXT NOT NULL
            );
        """)
        for version in 1...21 {
            Self.exec(db, """
                INSERT INTO schema_migrations (version, applied_at, description)
                VALUES (\(version), 1700000000.0, 'baseline stamp');
            """)
        }
        Self.exec(db, "PRAGMA user_version = 21;")

        let before = Self.appliedCount(db)
        let report = try MigrationRunner.run(db: db, dbPath: ":memory:", registry: MigrationRegistry.all)
        let after = Self.appliedCount(db)

        #expect(after - before == 27, "ledger must advance by exactly twenty-seven rows (v22..v48); got \(after - before)")
        #expect(report.appliedVersions == [22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48], "runner must report v22..v48 as the newly-applied versions; got \(report.appliedVersions)")
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
