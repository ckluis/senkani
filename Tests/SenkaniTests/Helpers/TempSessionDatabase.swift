import Foundation
@testable import Core

/// Centralized cleanup for tests that create `SessionDatabase(path:)`.
///
/// Background. `SessionDatabase` writes up to five sidecar files alongside
/// its primary `.sqlite` path:
///
///   - `<path>`             — the sqlite file itself
///   - `<path>-wal`         — SQLite write-ahead log
///   - `<path>-shm`         — SQLite shared-memory mapping
///   - `<path>.migrating`   — MigrationRunner's cross-process flock sidecar
///                            (Sources/Core/MigrationRunner.swift:74)
///   - `<path>.schema.lock` — pre-existence sentinel checked at the top of
///                            MigrationRunner.run(...)
///
/// MigrationRunner releases the flock on `.migrating` and closes its FD,
/// but it never unlinks the sidecar — that would race the inode-swap
/// semantics documented in MigrationRunner.swift:62-71. In production
/// the sidecar lives next to the singleton `~/Library/.../senkani.db`
/// and is harmless. In tests, every `SessionDatabase(path: "/tmp/...")`
/// leaks a fresh `.migrating` per call, which is why /tmp accumulated
/// 189 leftovers from `StoreExecTests` alone in the 2026-05-03 round.
///
/// The sidecar list mirrors `Sources/CLI/WipeCommand.swift:37` (the
/// production uninstall path) so test-side and prod-side cleanup stay
/// in lockstep when new sidecars are added.
enum TempSessionDatabase {
    /// All sidecar suffixes that `SessionDatabase` + its dependencies
    /// may create alongside the primary `.sqlite` path. Source of truth
    /// for both this helper and any test that rolls its own cleanup
    /// against the same paths.
    static let sidecarSuffixes = ["", "-wal", "-shm", ".migrating", ".schema.lock"]

    /// Unlink the primary file and every sidecar at `path`. Idempotent —
    /// missing files are silently ignored.
    static func cleanup(path: String) {
        let fm = FileManager.default
        for suffix in sidecarSuffixes {
            try? fm.removeItem(atPath: path + suffix)
        }
    }

    /// Close the database (drains the queue + `sqlite3_close`) and then
    /// unlink every sidecar. Prefer this over bare `cleanup(path:)` when
    /// the test holds a live `SessionDatabase` reference: a late
    /// `sqlite3_close` from `SessionDatabase`'s deinit otherwise lands
    /// on an already-deleted `-wal`/`-shm` and SIGSEGVs the
    /// swiftpm-testing-helper.
    static func close(_ db: SessionDatabase, path: String) {
        db.close()
        cleanup(path: path)
    }
}
