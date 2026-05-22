import Testing
import Foundation
import SQLite3
@testable import Core

/// V.18a-1 schema/migration tests for the RuntimeTelemetryDataset tables.
///
/// Covers the four acceptance bullets from
/// `spec/autonomous/backlog/phase-v18a-1-schema-migration.md`:
///   1. Three tables + indexes present after migration v30.
///   2. Migration ledger advances by 1 for v30.
///   3. `PRAGMA page_size` = 8192 after SessionDatabase init.
///   4. `PRAGMA journal_mode` = "wal" + `PRAGMA auto_vacuum` = 2 (INCREMENTAL).
@Suite("RuntimeTelemetryMigration (V.18a-1)")
struct RuntimeTelemetryMigrationTests {

    // MARK: - Helpers

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-v18a-1-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "telemetry-\(UUID().uuidString).db"
    }

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;",
            -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func indexExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type='index' AND name=?;",
            -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func readIntPragma(_ db: OpaquePointer, _ name: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA \(name);", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return -1
    }

    private static func readTextPragma(_ db: OpaquePointer, _ name: String) -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA \(name);", -1, &stmt, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW,
           let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return ""
    }

    // MARK: - Acceptance bullet 1: three tables + indexes after v30

    @Test("v30 creates runtime_telemetry_{dataset,span,log} with the documented indexes")
    func v30CreatesTablesAndIndexes() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { if let db = db { sqlite3_close(db) } }
        guard let db = db else { return }

        #expect(Self.tableExists(db, "runtime_telemetry_dataset"))
        #expect(Self.tableExists(db, "runtime_telemetry_span"))
        #expect(Self.tableExists(db, "runtime_telemetry_log"))

        #expect(Self.indexExists(db, "idx_runtime_telemetry_span_dataset_start"))
        #expect(Self.indexExists(db, "idx_runtime_telemetry_span_trace"))
        #expect(Self.indexExists(db, "idx_runtime_telemetry_span_session_tool"))
        #expect(Self.indexExists(db, "idx_runtime_telemetry_span_validation_run"))
        #expect(Self.indexExists(db, "idx_runtime_telemetry_log_dataset_unix"))
        #expect(Self.indexExists(db, "idx_runtime_telemetry_log_trace_span"))
    }

    // MARK: - Acceptance bullet 2: migration ledger advances by 1 for v30

    @Test("v30 records exactly one new row in schema_migrations and bumps user_version to 30")
    func v30AdvancesMigrationLedger() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { if let db = db { sqlite3_close(db) } }
        guard let db = db else { return }

        // user_version should be at least 30 — fresh DBs run every
        // migration in MigrationRegistry.all in order, so user_version
        // equals the maximum registered version.
        let userVersion = Self.readIntPragma(db, "user_version")
        #expect(userVersion >= 30, "user_version was \(userVersion), expected >= 30 after v30 ships")

        // schema_migrations should contain exactly one row with version=30.
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(
            db,
            "SELECT COUNT(*), MAX(description) FROM schema_migrations WHERE version = 30;",
            -1, &stmt, nil
        ) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        let count = Int(sqlite3_column_int(stmt, 0))
        let desc = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        #expect(count == 1, "expected exactly one v30 ledger row, got \(count)")
        #expect(desc.contains("runtime_telemetry"), "v30 description should reference runtime_telemetry, got '\(desc)'")
    }

    // MARK: - Acceptance bullet 3: page_size = 8192

    @Test("PRAGMA page_size returns 8192 after SessionDatabase init")
    func pageSizeIs8K() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { if let db = db { sqlite3_close(db) } }
        guard let db = db else { return }

        let pageSize = Self.readIntPragma(db, "page_size")
        #expect(pageSize == 8192, "expected page_size=8192, got \(pageSize)")
    }

    // MARK: - Acceptance bullet 4: journal_mode=wal AND auto_vacuum=INCREMENTAL

    @Test("PRAGMA journal_mode=wal and PRAGMA auto_vacuum=INCREMENTAL after init")
    func journalAndAutoVacuumTuned() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { if let db = db { sqlite3_close(db) } }
        guard let db = db else { return }

        let journalMode = Self.readTextPragma(db, "journal_mode").lowercased()
        #expect(journalMode == "wal", "expected journal_mode='wal', got '\(journalMode)'")

        // SQLite auto_vacuum: 0=NONE, 1=FULL, 2=INCREMENTAL
        let autoVacuum = Self.readIntPragma(db, "auto_vacuum")
        #expect(autoVacuum == 2, "expected auto_vacuum=2 (INCREMENTAL), got \(autoVacuum)")
    }
}
