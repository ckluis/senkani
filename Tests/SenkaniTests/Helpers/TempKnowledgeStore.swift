import Foundation
@testable import Core

/// Centralized close-then-cleanup for tests that create `KnowledgeStore`.
///
/// Background. Swift fires a function's `defer` blocks BEFORE its local
/// variables are released. A test shaped:
///
///   let (store, root) = makeKBRoot()
///   defer { try? FileManager.default.removeItem(atPath: root) }
///   // … body schedules async writes through `store.queue.async` …
///
/// unlinks the project root **before** `KnowledgeStore.deinit` drains its
/// queue and closes the sqlite handle. Any in-flight `BEGIN` / `COMMIT`
/// from `batchIncrementMentions` / `upsertCoupling` / `appendEvidence`
/// then lands on a deleted file → `[KnowledgeStore] SQL error: BEGIN
/// failed: disk I/O error` (SQLITE_IOERR).
///
/// `KnowledgeStore.close()` is a `queue.sync { sqlite3_close(db) }`, so
/// it both drains pending async work on the serial queue AND releases
/// the file handle. Calling it before unlink eliminates the race.
///
/// Mirrors `TempSessionDatabase.close(_:path:)` (the SessionDatabase
/// precedent for the same defer-vs-deinit ordering hazard).
enum TempKnowledgeStore {
    /// Close the store (drains the queue + `sqlite3_close`) and unlink
    /// the .sqlite file plus its WAL/SHM sidecars. Use with tests that
    /// construct `KnowledgeStore(path: ...)` against a `/tmp/...sqlite`
    /// path.
    static func close(_ store: KnowledgeStore, path: String) {
        store.close()
        TempSessionDatabase.cleanup(path: path)
    }

    /// Close the store and remove the project root tree. Use with tests
    /// that construct `KnowledgeStore(projectRoot: ...)` against a
    /// `/tmp/...` directory containing `.senkani/vault.db`.
    static func close(_ store: KnowledgeStore, projectRoot: String) {
        store.close()
        try? FileManager.default.removeItem(atPath: projectRoot)
    }
}
