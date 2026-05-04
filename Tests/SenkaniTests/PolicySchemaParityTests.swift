import Testing
import Foundation
import SQLite3
@testable import Core

/// `policy_snapshots` is created by TWO independent paths today:
///   • `PolicyStore.setupSchema()` (`Sources/Core/Stores/PolicyStore.swift`)
///   • `MigrationRegistry.all` v15 + v17 (`Sources/Core/Migrations.swift`)
///
/// `CREATE TABLE IF NOT EXISTS` silently masks divergence: a future schema
/// change in only one path produces "works on fresh DBs, breaks on
/// migrated ones" or vice versa. Until the session-DB schema-authority
/// cleanup ships (see `spec/architecture.md` → "Schema authority
/// (decided 2026-05-04)"), this test is the guardrail.
///
/// Three PRAGMA dimensions are compared — the divergence modes
/// `CREATE TABLE IF NOT EXISTS` masks:
///   • `table_info`         — column count, names, types, NOT NULL,
///                            DEFAULT values, PK declarations.
///   • `index_list` +
///     `index_info`         — index names, uniqueness, origin (CREATE
///                            INDEX vs autoindex), and the column
///                            ordering inside each compound index.
///   • `foreign_key_list`   — `REFERENCES sessions(id)` and any other
///                            FK metadata.
@Suite("policy_snapshots schema parity — setupSchema vs migrations")
struct PolicySchemaParityTests {

    // MARK: - PRAGMA capture types

    private struct ColumnInfo: Equatable, Hashable, CustomStringConvertible {
        let cid: Int
        let name: String
        let type: String
        let notNull: Bool
        let defaultValue: String?  // SQLite renders dflt_value as the literal text
        let primaryKey: Int        // 0 = not PK, 1+ = position in compound PK

        var description: String {
            "cid=\(cid) name=\(name) type=\(type) notNull=\(notNull) default=\(defaultValue ?? "<nil>") pk=\(primaryKey)"
        }
    }

    private struct IndexEntry: Equatable, Hashable, CustomStringConvertible {
        let name: String
        let unique: Bool
        let origin: String  // 'c' = CREATE INDEX, 'pk' = primary key, 'u' = UNIQUE constraint
        let partial: Bool
        let columns: [String]  // columns in seqno order

        var description: String {
            "name=\(name) unique=\(unique) origin=\(origin) partial=\(partial) columns=\(columns)"
        }
    }

    private struct ForeignKey: Equatable, Hashable, CustomStringConvertible {
        let id: Int
        let seq: Int
        let table: String
        let from: String
        let to: String
        let onUpdate: String
        let onDelete: String
        let match: String

        var description: String {
            "fk=\(id):\(seq) table=\(table) from=\(from) to=\(to) onUpdate=\(onUpdate) onDelete=\(onDelete) match=\(match)"
        }
    }

    // MARK: - Helpers

    /// Open an in-memory DB. Caller closes via `sqlite3_close`.
    private static func openMemory() -> OpaquePointer {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        return db!
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if let err {
            let msg = String(cString: err)
            sqlite3_free(err)
            Issue.record("SQL failed: \(msg)\nSQL=\(sql)")
        }
        #expect(rc == SQLITE_OK)
    }

    /// Build a DB whose `policy_snapshots` schema came from `PolicyStore.setupSchema`.
    /// Uses the static `PolicyStore.schemaSQL` constant directly so the test
    /// shares the SAME source of truth as production setupSchema.
    private static func makeSetupSchemaOnlyDB() -> OpaquePointer {
        let db = openMemory()
        // setupSchema declares `REFERENCES sessions(id)`. SQLite resolves
        // FK targets lazily at write-time (only when foreign_keys=ON), so
        // the absent `sessions` table is irrelevant for this CREATE.
        for sql in PolicyStore.schemaSQL { exec(db, sql) }
        return db
    }

    /// Build a DB whose `policy_snapshots` schema came from `MigrationRunner`
    /// alone — no setupSchema. Runs the full registry so v15 + v17 (and
    /// every prerequisite, including v4's `chain_anchors`) land in their
    /// production order.
    private static func makeMigrationsOnlyDB() throws -> OpaquePointer {
        let db = openMemory()
        _ = try MigrationRunner.run(db: db, dbPath: ":memory:")
        return db
    }

    private static func captureColumns(_ db: OpaquePointer, table: String) -> [ColumnInfo] {
        var out: [ColumnInfo] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return out
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cid = Int(sqlite3_column_int(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let type = String(cString: sqlite3_column_text(stmt, 2))
            let notNull = sqlite3_column_int(stmt, 3) != 0
            let dflt: String? = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let pk = Int(sqlite3_column_int(stmt, 5))
            out.append(ColumnInfo(cid: cid, name: name, type: type,
                                  notNull: notNull, defaultValue: dflt,
                                  primaryKey: pk))
        }
        return out.sorted { $0.cid < $1.cid }
    }

    private static func captureIndexes(_ db: OpaquePointer, table: String) -> [IndexEntry] {
        var indexes: [IndexEntry] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA index_list(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return indexes
        }
        // PRAGMA index_list columns: seq, name, unique, origin, partial.
        var rows: [(name: String, unique: Bool, origin: String, partial: Bool)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let unique = sqlite3_column_int(stmt, 2) != 0
            let origin = String(cString: sqlite3_column_text(stmt, 3))
            let partial = sqlite3_column_int(stmt, 4) != 0
            rows.append((name, unique, origin, partial))
        }
        sqlite3_finalize(stmt)

        for row in rows {
            // PRAGMA index_info columns per index: seqno, cid, name.
            var infoStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA index_info(\(row.name));", -1, &infoStmt, nil) == SQLITE_OK else {
                continue
            }
            var cols: [(seqno: Int, name: String)] = []
            while sqlite3_step(infoStmt) == SQLITE_ROW {
                let seqno = Int(sqlite3_column_int(infoStmt, 0))
                let colName = String(cString: sqlite3_column_text(infoStmt, 2))
                cols.append((seqno, colName))
            }
            sqlite3_finalize(infoStmt)
            let ordered = cols.sorted { $0.seqno < $1.seqno }.map(\.name)
            indexes.append(IndexEntry(name: row.name, unique: row.unique,
                                      origin: row.origin, partial: row.partial,
                                      columns: ordered))
        }
        // Sort by name so the comparison is order-insensitive — both paths
        // create the same indexes but creation order is an implementation
        // detail, not part of the schema contract.
        return indexes.sorted { $0.name < $1.name }
    }

    private static func captureForeignKeys(_ db: OpaquePointer, table: String) -> [ForeignKey] {
        var out: [ForeignKey] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA foreign_key_list(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return out
        }
        defer { sqlite3_finalize(stmt) }
        // PRAGMA foreign_key_list columns: id, seq, table, from, to, on_update, on_delete, match.
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(stmt, 0))
            let seq = Int(sqlite3_column_int(stmt, 1))
            let tbl = String(cString: sqlite3_column_text(stmt, 2))
            let from = String(cString: sqlite3_column_text(stmt, 3))
            let to = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let onUpdate = String(cString: sqlite3_column_text(stmt, 5))
            let onDelete = String(cString: sqlite3_column_text(stmt, 6))
            let match = String(cString: sqlite3_column_text(stmt, 7))
            out.append(ForeignKey(id: id, seq: seq, table: tbl, from: from, to: to,
                                  onUpdate: onUpdate, onDelete: onDelete, match: match))
        }
        return out.sorted { ($0.id, $0.seq) < ($1.id, $1.seq) }
    }

    // MARK: - Tests

    @Test("PRAGMA table_info parity — column count, types, NOT NULL, DEFAULTs match")
    func tableInfoMatches() throws {
        let setupDB = Self.makeSetupSchemaOnlyDB()
        defer { sqlite3_close(setupDB) }
        let migDB = try Self.makeMigrationsOnlyDB()
        defer { sqlite3_close(migDB) }

        let setupCols = Self.captureColumns(setupDB, table: "policy_snapshots")
        let migCols = Self.captureColumns(migDB, table: "policy_snapshots")

        #expect(!setupCols.isEmpty,
                "setupSchema path must produce a non-empty policy_snapshots table_info")
        #expect(!migCols.isEmpty,
                "migrations path must produce a non-empty policy_snapshots table_info")
        #expect(setupCols == migCols,
                "policy_snapshots column shape diverges between setupSchema and migrations.\n\nsetupSchema:\n\(setupCols.map(\.description).joined(separator: "\n"))\n\nmigrations:\n\(migCols.map(\.description).joined(separator: "\n"))")
    }

    @Test("PRAGMA index_list + index_info parity — names, uniqueness, origin, column order match")
    func indexShapeMatches() throws {
        let setupDB = Self.makeSetupSchemaOnlyDB()
        defer { sqlite3_close(setupDB) }
        let migDB = try Self.makeMigrationsOnlyDB()
        defer { sqlite3_close(migDB) }

        let setupIdx = Self.captureIndexes(setupDB, table: "policy_snapshots")
        let migIdx = Self.captureIndexes(migDB, table: "policy_snapshots")

        #expect(!setupIdx.isEmpty,
                "setupSchema path must produce a non-empty policy_snapshots index_list")
        #expect(!migIdx.isEmpty,
                "migrations path must produce a non-empty policy_snapshots index_list")
        #expect(setupIdx == migIdx,
                "policy_snapshots index shape diverges between setupSchema and migrations.\n\nsetupSchema:\n\(setupIdx.map(\.description).joined(separator: "\n"))\n\nmigrations:\n\(migIdx.map(\.description).joined(separator: "\n"))")
    }

    @Test("PRAGMA foreign_key_list parity — REFERENCES sessions(id) preserved on both paths")
    func foreignKeyListMatches() throws {
        let setupDB = Self.makeSetupSchemaOnlyDB()
        defer { sqlite3_close(setupDB) }
        let migDB = try Self.makeMigrationsOnlyDB()
        defer { sqlite3_close(migDB) }

        let setupFKs = Self.captureForeignKeys(setupDB, table: "policy_snapshots")
        let migFKs = Self.captureForeignKeys(migDB, table: "policy_snapshots")

        #expect(setupFKs == migFKs,
                "policy_snapshots foreign-key list diverges between setupSchema and migrations.\n\nsetupSchema:\n\(setupFKs.map(\.description).joined(separator: "\n"))\n\nmigrations:\n\(migFKs.map(\.description).joined(separator: "\n"))")
    }
}
