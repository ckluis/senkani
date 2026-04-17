import Foundation
import SQLite3

/// A single schema migration. Future migrations APPEND to `MigrationRegistry.all`
/// with incrementing `version`. Never modify a migration that has shipped — migrations
/// are idempotent by transaction wrapping, not by rewriting history.
public struct Migration: Sendable {
    public let version: Int
    public let description: String
    public let up: @Sendable (OpaquePointer) throws -> Void

    public init(
        version: Int,
        description: String,
        up: @escaping @Sendable (OpaquePointer) throws -> Void
    ) {
        self.version = version
        self.description = description
        self.up = up
    }
}

/// Registry of schema migrations in version order.
///
/// Version 1 is the historical "baseline" — the schema shape that existed immediately
/// before `schema_migrations` was introduced. Fresh DBs reach version 1 via
/// `SessionDatabase.createTables()` + `execSilent` ALTERs; existing DBs are already
/// at version 1 and are stamped by the baselining pass.
///
/// Future migrations add entries here with version 2, 3, ....
public enum MigrationRegistry {
    public static let all: [Migration] = [
        Migration(version: 1, description: "initial schema baseline") { _ in
            // No-op: for fresh DBs, createTables() + execSilent ALTERs already
            // produced the version-1 shape. For pre-existing DBs, the baselining
            // pass stamps this as applied without re-running `up`.
        },
        Migration(version: 2, description: "event_counters for security + observability") { db in
            // Observability wave: incrementing counters for every defense
            // site (injection detections, SSRF blocks, retention pruning,
            // migrations applied, socket handshake rejections, command
            // redactions). Queryable via SessionDatabase.eventCounts and
            // surfaced through senkani_session stats + senkani stats
            // --security. project_root is "" for process-global events
            // that aren't tied to a project (e.g. socket handshake).
            let sql = """
                CREATE TABLE IF NOT EXISTS event_counters (
                    project_root TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    count INTEGER NOT NULL DEFAULT 0,
                    first_seen_at REAL NOT NULL,
                    last_seen_at REAL NOT NULL,
                    PRIMARY KEY (project_root, event_type)
                );
                CREATE INDEX IF NOT EXISTS idx_event_counters_type
                    ON event_counters(event_type);
                """
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &err)
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let err = err { sqlite3_free(err) }
            guard rc == SQLITE_OK else {
                throw MigrationError.sqlFailed(stage: "v2", detail: msg)
            }
        },
    ]
}
