import Foundation
import SQLite3

/// Per-table tamper-evident chain state. Owns:
///   - Lazy-create logic for the table's `chain_anchors` row
///     (`fresh-install` reason on first write into a fresh DB).
///   - In-memory cache of `(anchorId, lastEntryHash)` so the insert hot path
///     doesn't round-trip the DB for `prev_hash` on every write.
///
/// Cold-start path: first write after process start hits the cache miss
/// path and reads the latest `entry_hash` from the DB once, then populates
/// the cache.
///
/// Concurrency: callers must invoke `resolveAnchorId` and `latestEntryHash`
/// inside `SessionDatabase.queue` — the single-writer invariant is what
/// makes the read-then-write step (look up prev → compute hash → write)
/// race-free against another insert. Tests verify this with the
/// "process restart cold-start recovery" case in `ChainVerifierTests`.
///
/// Each store that participates in the chain (TokenEventStore,
/// ValidationStore, SandboxStore, CommandStore) owns one `ChainState` keyed
/// by its table name.
final class ChainState: @unchecked Sendable {
    let table: String
    private var cachedAnchorId: Int64?
    private var cachedLastEntryHash: String?

    init(table: String) {
        self.table = table
    }

    /// Resolve the current chain anchor for this table. The migration pass
    /// may have created a `migration-v4` (or `migration-v5`) anchor for
    /// backfilled history; new writes continue under the same anchor with
    /// rowid > `started_at_rowid`, which `ChainVerifier` uses to skip
    /// pre-migration rows. On a fresh DB no anchor exists at all — open a
    /// `fresh-install` anchor on first write with `started_at_rowid = 0`
    /// (so every subsequent row is verified).
    ///
    /// Caller MUST already be on `SessionDatabase.queue`.
    func resolveAnchorId(db: OpaquePointer) -> Int64 {
        if let cached = cachedAnchorId { return cached }

        var stmt: OpaquePointer?
        let lookup = "SELECT MAX(id) FROM chain_anchors WHERE table_name = ?;"
        if sqlite3_prepare_v2(db, lookup, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW,
               sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                let id = sqlite3_column_int64(stmt, 0)
                cachedAnchorId = id
                return id
            }
        }

        let now = Date().timeIntervalSince1970
        let insert = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES (?, ?, 0, 'fresh-install', NULL);
        """
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insert, -1, &insertStmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(insertStmt) }
        sqlite3_bind_text(insertStmt, 1, (table as NSString).utf8String, -1, nil)
        sqlite3_bind_double(insertStmt, 2, now)
        guard sqlite3_step(insertStmt) == SQLITE_DONE else { return 0 }

        let newId = sqlite3_last_insert_rowid(db)
        cachedAnchorId = newId
        return newId
    }

    /// Latest `entry_hash` under the given anchor for this table. Cached
    /// after the first hit; cold-start cost is one indexed lookup per
    /// process. Pre-T.5 backfilled rows have NULL hashes by design — this
    /// query naturally skips them via `entry_hash IS NOT NULL`.
    ///
    /// Caller MUST already be on `SessionDatabase.queue`.
    func latestEntryHash(db: OpaquePointer, anchorId: Int64) -> String? {
        if cachedAnchorId == anchorId, let cached = cachedLastEntryHash {
            return cached
        }

        let sql = """
            SELECT entry_hash FROM \(table)
             WHERE chain_anchor_id = ? AND entry_hash IS NOT NULL
             ORDER BY id DESC LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, anchorId)
        if sqlite3_step(stmt) == SQLITE_ROW,
           let cstr = sqlite3_column_text(stmt, 0) {
            let hash = String(cString: cstr)
            cachedLastEntryHash = hash
            return hash
        }
        return nil
    }

    /// Update the cache after a successful insert. Call this immediately
    /// after `sqlite3_step` returns `SQLITE_DONE`; the queue serialization
    /// guarantees no other write can interleave.
    func recordWrite(anchorId: Int64, entryHash: String) {
        cachedAnchorId = anchorId
        cachedLastEntryHash = entryHash
    }

    /// Drop the cache. Used by `ChainRepairer` (round 4) — after a repair
    /// opens a new anchor and wipes hashes, the next insert needs to
    /// resolve the new anchor and start with `prev_hash = nil`. Caller
    /// MUST be on `SessionDatabase.queue`.
    func invalidate() {
        cachedAnchorId = nil
        cachedLastEntryHash = nil
    }
}
