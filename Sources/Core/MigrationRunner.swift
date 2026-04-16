import Foundation
import SQLite3

public enum MigrationError: Error, CustomStringConvertible {
    case lockfilePresent(path: String)
    case flockFailed(errno: Int32)
    case sqlFailed(stage: String, detail: String)
    case migrationFailed(version: Int, description: String, underlying: String)

    public var description: String {
        switch self {
        case .lockfilePresent(let path):
            return "Schema lockfile present at \(path) from a prior failed migration. Investigate the DB and remove the lockfile before retrying."
        case .flockFailed(let e):
            return "flock failed: \(String(cString: strerror(e)))"
        case .sqlFailed(let stage, let detail):
            return "SQL failure during \(stage): \(detail)"
        case .migrationFailed(let v, let d, let msg):
            return "migration v\(v) (\(d)) failed: \(msg)"
        }
    }
}

/// Schema migration runner.
///
/// Design (see /Users/clank/.claude/plans/ultrathink-about-each-of-binary-clover.md):
/// - Dual tracking: `PRAGMA user_version` is a 4-byte header cache; `schema_migrations`
///   is the audit log. Both updated in the same transaction.
/// - First-boot baselining: when `schema_migrations` is empty and the legacy ALTER'd
///   columns are present, stamp version 1 as applied without re-running.
/// - Cross-process coordination: `flock(2)` on `<dbPath>.migrating` so MCP server and
///   GUI app don't race a migration.
/// - Kill-switch: on failure, write `<dbPath>.schema.lock` and throw; next boot refuses
///   to run migrations so the user can inspect the DB.
public enum MigrationRunner {

    public struct RunReport: Sendable {
        public let appliedVersions: [Int]
        public let targetVersion: Int
    }

    /// Run migrations. `dbPath` is the on-disk path used to locate sidecar lock files;
    /// pass `":memory:"` (or any empty string) to disable file-based locking/kill-switch
    /// (useful in tests).
    @discardableResult
    public static func run(
        db: OpaquePointer,
        dbPath: String,
        registry: [Migration] = MigrationRegistry.all
    ) throws -> RunReport {
        let usesSidecar = !dbPath.isEmpty && dbPath != ":memory:"

        if usesSidecar {
            let lockfilePath = dbPath + ".schema.lock"
            if FileManager.default.fileExists(atPath: lockfilePath) {
                throw MigrationError.lockfilePresent(path: lockfilePath)
            }
        }

        // Acquire cross-process flock. Tests use in-memory DB and skip this.
        var flockFD: Int32 = -1
        if usesSidecar {
            let flockPath = dbPath + ".migrating"
            FileManager.default.createFile(atPath: flockPath, contents: nil)
            flockFD = open(flockPath, O_RDWR | O_CREAT, 0o600)
            guard flockFD >= 0 else { throw MigrationError.flockFailed(errno: errno) }
            while flock(flockFD, LOCK_EX) != 0 {
                if errno != EINTR {
                    close(flockFD)
                    throw MigrationError.flockFailed(errno: errno)
                }
            }
        }
        defer {
            if flockFD >= 0 {
                _ = flock(flockFD, LOCK_UN)
                close(flockFD)
            }
        }

        try ensureMigrationsTable(db: db)
        try baselineIfNeeded(db: db, registry: registry)

        let applied = try readAppliedVersions(db: db)
        let targetVersion = registry.map(\.version).max() ?? 0
        var justApplied: [Int] = []

        for mig in registry.sorted(by: { $0.version < $1.version }) where !applied.contains(mig.version) {
            do {
                try exec(db, "BEGIN IMMEDIATE;")
                try mig.up(db)
                try recordApplied(db: db, migration: mig)
                try exec(db, "PRAGMA user_version = \(mig.version);")
                try exec(db, "COMMIT;")
                justApplied.append(mig.version)
                Logger.log("schema.migration.applied", fields: [
                    "version": .int(mig.version),
                    "description": .string(mig.description),
                    "outcome": .string("success")
                ])
            } catch {
                _ = try? exec(db, "ROLLBACK;")
                let underlying = (error as? MigrationError)?.description ?? "\(error)"
                if usesSidecar {
                    let lockfilePath = dbPath + ".schema.lock"
                    let body = "version=\(mig.version)\ndescription=\(mig.description)\nerror=\(underlying)\nts=\(Date().timeIntervalSince1970)\n"
                    try? body.data(using: .utf8)?.write(to: URL(fileURLWithPath: lockfilePath))
                }
                Logger.log("schema.migration.failed", fields: [
                    "version": .int(mig.version),
                    "description": .string(mig.description),
                    "error": .string(underlying),
                    "outcome": .string("error")
                ])
                throw MigrationError.migrationFailed(
                    version: mig.version,
                    description: mig.description,
                    underlying: underlying
                )
            }
        }

        return RunReport(appliedVersions: justApplied, targetVersion: targetVersion)
    }

    // MARK: - Internals

    private static func ensureMigrationsTable(db: OpaquePointer) throws {
        try exec(db, """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                description TEXT NOT NULL,
                applied_at REAL NOT NULL
            );
        """)
    }

    /// If `schema_migrations` is empty but the DB already has the legacy ALTER'd columns
    /// (commands.budget_decision, sessions.project_root, sessions.agent_type), the user
    /// is upgrading from a pre-migration-system install — stamp version 1 as applied.
    private static func baselineIfNeeded(db: OpaquePointer, registry: [Migration]) throws {
        guard try readAppliedVersions(db: db).isEmpty else { return }

        let hasBudgetDecision = columnExists(db: db, table: "commands", column: "budget_decision")
        let hasProjectRoot    = columnExists(db: db, table: "sessions", column: "project_root")
        let hasAgentType      = columnExists(db: db, table: "sessions", column: "agent_type")

        guard hasBudgetDecision && hasProjectRoot && hasAgentType,
              let baseline = registry.first(where: { $0.version == 1 })
        else { return }

        try exec(db, "BEGIN IMMEDIATE;")
        do {
            try recordApplied(db: db, migration: baseline)
            try exec(db, "PRAGMA user_version = 1;")
            try exec(db, "COMMIT;")
        } catch {
            _ = try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private static func readAppliedVersions(db: OpaquePointer) throws -> Set<Int> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT version FROM schema_migrations;", -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(stage: "readAppliedVersions", detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: Set<Int> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.insert(Int(sqlite3_column_int(stmt, 0)))
        }
        return out
    }

    private static func recordApplied(db: OpaquePointer, migration: Migration) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO schema_migrations(version, description, applied_at) VALUES (?, ?, ?);",
            -1, &stmt, nil
        ) == SQLITE_OK else {
            throw MigrationError.sqlFailed(stage: "recordApplied prepare", detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(migration.version))
        sqlite3_bind_text(stmt, 2, (migration.description as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MigrationError.sqlFailed(stage: "recordApplied step", detail: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func columnExists(db: OpaquePointer, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 1) {
                if String(cString: cstr) == column { return true }
            }
        }
        return false
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let err = err { sqlite3_free(err) }
            throw MigrationError.sqlFailed(stage: "exec", detail: msg)
        }
    }

    /// Public helper for SessionDatabase diagnostics and the upcoming senkani_version tool.
    public static func currentVersion(db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }
}
