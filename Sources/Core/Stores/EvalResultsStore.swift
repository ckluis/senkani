import Foundation
import SQLite3

/// Owns `eval_results` end-to-end: schema (migration v24), chained
/// writes, recent-row reads. Mirrors `EgressDecisionStore`'s shape so
/// the chain mechanics are uniform across participants.
///
/// T.2b-1 ships the writer; T.2b-2 (PII-Masking-300k eval harness)
/// is the first caller of `record(...)`. The `senkani doctor` Layer 3
/// F1 suffix surfaces `latest(modelId:)` once T.2b-2 lands.
///
/// Concurrency: every `sqlite3_*` call against `parent.db` runs on
/// `parent.queue` (the SessionDatabase queue-affinity invariant from
/// the 2026-05-04 audit). The chain state cache lives inside
/// `ChainState` which is shared with the other chain participants.
public final class EvalResultsStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase
    private let chain = ChainState(table: "eval_results")

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Drop the chain cache after a `--repair-chain` motion. Caller
    /// must already be on `parent.queue`.
    func invalidateChainCache() { chain.invalidate() }

    /// Record an eval result. Synchronous-on-queue so the eval harness
    /// can read the row back immediately. Returns true on success,
    /// false on any SQLite failure (logged, not thrown — eval-result
    /// writes are best-effort: a write failure must NOT crash the
    /// harness or the doctor command).
    @discardableResult
    public func record(
        modelId: String,
        fixtureId: String,
        precision: Double,
        recall: Double,
        f1: Double,
        durationMs: Int64
    ) -> Bool {
        let now = Date().timeIntervalSince1970
        return parent.queue.sync { [parent, chain] in
            guard let db = parent.db else { return false }
            let anchorId = chain.resolveAnchorId(db: db)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            let columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":   .real(now),
                "model_id":    .text(modelId),
                "fixture_id":  .text(fixtureId),
                "precision":   .real(precision),
                "recall":      .real(recall),
                "f1":          .real(f1),
                "duration_ms": .integer(durationMs),
            ]
            let entryHash = ChainHasher.entryHash(
                table: "eval_results", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO eval_results
                    (timestamp, model_id, fixture_id,
                     precision, recall, f1, duration_ms,
                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, (modelId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 3, (fixtureId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_double(stmt, 4, precision)
            sqlite3_bind_double(stmt, 5, recall)
            sqlite3_bind_double(stmt, 6, f1)
            sqlite3_bind_int64(stmt, 7, durationMs)
            if let prevHash {
                sqlite3_bind_text(stmt, 8, (prevHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_bind_text(stmt, 9, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 10, anchorId)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            return true
        }
    }

    /// Eval row as read back from the table.
    public struct Row: Sendable, Equatable {
        public let id: Int64
        public let timestamp: Date
        public let modelId: String
        public let fixtureId: String
        public let precision: Double
        public let recall: Double
        public let f1: Double
        public let durationMs: Int64
    }

    /// Most recent eval row for a model, or nil if no rows have been
    /// written. Used by `senkani doctor` Layer 3 F1 suffix (lands in
    /// T.2b-2 once the harness writes rows).
    public func latest(modelId: String) -> Row? {
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
            let sql = """
                SELECT id, timestamp, model_id, fixture_id,
                       precision, recall, f1, duration_ms
                  FROM eval_results
                 WHERE model_id = ?
                 ORDER BY id DESC
                 LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (modelId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return decodeRow(stmt)
        }
    }

    /// Return the N most recent rows in descending id order.
    public func recent(limit: Int = 100) -> [Row] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, timestamp, model_id, fixture_id,
                       precision, recall, f1, duration_ms
                  FROM eval_results
                 ORDER BY id DESC
                 LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [Row] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(decodeRow(stmt))
            }
            return out
        }
    }

    /// Total eval row count.
    public func count() -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM eval_results;", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    private func decodeRow(_ stmt: OpaquePointer?) -> Row {
        let id = sqlite3_column_int64(stmt, 0)
        let ts = sqlite3_column_double(stmt, 1)
        let modelId = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let fixtureId = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let precision = sqlite3_column_double(stmt, 4)
        let recall = sqlite3_column_double(stmt, 5)
        let f1 = sqlite3_column_double(stmt, 6)
        let duration = sqlite3_column_int64(stmt, 7)
        return Row(
            id: id,
            timestamp: Date(timeIntervalSince1970: ts),
            modelId: modelId,
            fixtureId: fixtureId,
            precision: precision,
            recall: recall,
            f1: f1,
            durationMs: duration
        )
    }
}
