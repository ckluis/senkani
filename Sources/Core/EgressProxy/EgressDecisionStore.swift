import Foundation
import SQLite3

/// Owns `egress_decisions` end-to-end: schema (migration v19), chained
/// writes, recent-row reads. Mirrors `TokenEventStore`'s shape so the
/// chain mechanics are uniform across participants.
///
/// Concurrency: every `sqlite3_*` call against `parent.db` runs on
/// `parent.queue` (the SessionDatabase queue-affinity invariant from
/// the 2026-05-04 audit). The chain state cache lives inside
/// `ChainState` which is shared with the other chain participants.
public final class EgressDecisionStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase
    private let chain = ChainState(table: "egress_decisions")

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Drop the chain cache after a `--repair-chain` motion. Caller
    /// must already be on `parent.queue`.
    func invalidateChainCache() { chain.invalidate() }

    /// Record a decision. Synchronous-on-queue so unit tests can read
    /// the row back immediately after writing — the live listener
    /// (T.1a.2) calls this through the same dispatch path and gets the
    /// same guarantee. Returns true on success, false on any SQLite
    /// failure (logged, not thrown — egress decisions are best-effort
    /// from the daemon's point of view: a write failure must NOT
    /// crash the listener).
    @discardableResult
    public func record(
        host: String,
        method: String,
        decision: EgressRule.Decision,
        ruleId: String,
        latencyUs: Int64,
        paneId: String? = nil,
        projectRoot: String? = nil
    ) -> Bool {
        let normalizedRoot = SessionDatabase.normalizePath(projectRoot)
        let now = Date().timeIntervalSince1970
        return parent.queue.sync { [parent, chain] in
            guard let db = parent.db else { return false }
            let anchorId = chain.resolveAnchorId(db: db)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            let columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":     .real(now),
                "host":          .text(host),
                "method":        .text(method),
                "decision":      .text(decision.rawValue),
                "rule_id":       .text(ruleId),
                "latency_us":    .integer(latencyUs),
                "pane_id":       paneId.map { .text($0) } ?? .null,
                "project_root":  normalizedRoot.map { .text($0) } ?? .null,
            ]
            let entryHash = ChainHasher.entryHash(
                table: "egress_decisions", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO egress_decisions
                    (timestamp, host, method, decision, rule_id, latency_us,
                     pane_id, project_root,
                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, (host as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (method as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (decision.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (ruleId as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 6, latencyUs)
            if let paneId {
                sqlite3_bind_text(stmt, 7, (paneId as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            if let normalizedRoot {
                sqlite3_bind_text(stmt, 8, (normalizedRoot as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            if let prevHash {
                sqlite3_bind_text(stmt, 9, (prevHash as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            sqlite3_bind_text(stmt, 10, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 11, anchorId)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            return true
        }
    }

    /// Decision row as read back from the table.
    public struct Row: Sendable, Equatable {
        public let id: Int64
        public let timestamp: Date
        public let host: String
        public let method: String
        public let decision: EgressRule.Decision
        public let ruleId: String
        public let latencyUs: Int64
        public let paneId: String?
        public let projectRoot: String?
    }

    /// Return the N most recent rows in descending id order. Used by
    /// `senkani egress status --decisions` (T.1a.2 follow-up CLI work
    /// hangs off this) and by the doctor check that reports decision
    /// count.
    public func recent(limit: Int = 100) -> [Row] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, timestamp, host, method, decision, rule_id,
                       latency_us, pane_id, project_root
                  FROM egress_decisions
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
                let ts = sqlite3_column_double(stmt, 1)
                let host = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let method = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let decisionStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "deny"
                let ruleId = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                let latency = sqlite3_column_int64(stmt, 6)
                let paneId: String? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(stmt, 7).map { String(cString: $0) }
                let projectRoot: String? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(stmt, 8).map { String(cString: $0) }
                let decision = EgressRule.Decision(rawValue: decisionStr) ?? .deny
                out.append(Row(
                    id: id, timestamp: Date(timeIntervalSince1970: ts),
                    host: host, method: method, decision: decision, ruleId: ruleId,
                    latencyUs: latency, paneId: paneId, projectRoot: projectRoot
                ))
            }
            return out
        }
    }

    /// Total decision count. Cheap — uses COUNT(*) on the table. Doctor
    /// check surfaces this in the status line.
    public func count() -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM egress_decisions;", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
    }
}
