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
    ]
}
