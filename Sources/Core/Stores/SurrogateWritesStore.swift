import Foundation
import SQLite3

/// Owns `surrogate_writes` end-to-end: chained writes, recent-row
/// reads. Mirrors `PackAuditStore`'s shape so chain mechanics stay
/// uniform across participants.
///
/// T.2c-2 — one row per surrogate ALLOCATION (NOT per reuse). Chain
/// rows carry `(engagement_id, surrogate_id, category, at)`. The
/// original PII value is NEVER written to this table — the encrypted
/// at-rest copy in `SurrogateVault` is the privacy boundary; this
/// row is the integrity boundary.
public final class SurrogateWritesStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase
    private let chain = ChainState(table: "surrogate_writes")

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    func invalidateChainCache() { chain.invalidate() }

    /// Record one allocation. Returns `true` on a clean write,
    /// `false` if the SQLite step failed (caller treats as audit
    /// regression but the surrogate itself stays valid in the vault).
    @discardableResult
    public func record(
        engagementID: String,
        surrogateID: String,
        category: String,
        at: Date = Date()
    ) -> Bool {
        let ts = at.timeIntervalSince1970
        return parent.queue.sync { [parent, chain] in
            guard let db = parent.db else { return false }
            let anchorId = chain.resolveAnchorId(db: db)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            let columns: [String: ChainHasher.CanonicalValue] = [
                "engagement_id": .text(engagementID),
                "surrogate_id":  .text(surrogateID),
                "category":      .text(category),
                "at":            .real(ts),
            ]
            let entryHash = ChainHasher.entryHash(
                table: "surrogate_writes", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO surrogate_writes
                    (engagement_id, surrogate_id, category, at,
                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (engagementID as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 2, (surrogateID as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 3, (category as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_double(stmt, 4, ts)
            if let prevHash {
                sqlite3_bind_text(stmt, 5, (prevHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_text(stmt, 6, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 7, anchorId)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            return true
        }
    }

    public struct Row: Sendable, Equatable {
        public let id: Int64
        public let engagementID: String
        public let surrogateID: String
        public let category: String
        public let at: Date
    }

    public func recent(limit: Int = 100) -> [Row] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, engagement_id, surrogate_id, category, at
                  FROM surrogate_writes
                 ORDER BY id DESC
                 LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [Row] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let eng = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let sur = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let cat = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let at = sqlite3_column_double(stmt, 4)
                out.append(Row(
                    id: id,
                    engagementID: eng,
                    surrogateID: sur,
                    category: cat,
                    at: Date(timeIntervalSince1970: at)
                ))
            }
            return out
        }
    }

    public func count() -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT COUNT(*) FROM surrogate_writes;", -1, &stmt, nil
            ) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
    }
}
