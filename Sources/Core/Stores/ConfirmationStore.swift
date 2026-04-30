import Foundation
import SQLite3

/// Owns the `confirmations` table — Phase T.6a round 1.
///
/// Append-only audit log of every `ConfirmationGate` decision. Each row
/// records a write/exec-tagged tool call, the decision (`approve` /
/// `deny` / `auto`), and who decided it (`operator` / `policy` /
/// `auto`). Chained via the T.5 audit chain so post-hoc tampering with
/// the decision log is detectable by `senkani doctor --verify-chain`.
///
/// The chain is wired the same way `TokenEventStore` wires it — one
/// `ChainState` instance per table, the canonical-byte input excludes
/// the three chain columns, and the cache is updated only after a
/// successful insert.
final class ConfirmationStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    // T.5 chain state for this table.
    private let chain = ChainState(table: "confirmations")

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Drop the chain cache after a `--repair-chain` motion. Caller
    /// must be on `parent.queue`.
    func invalidateChainCache() { chain.invalidate() }

    // MARK: - Schema

    /// Idempotent — Migration v11 owns the canonical schema. The store
    /// init pattern matches the other chained stores.
    func setupSchema() {
        parent.queue.sync {
            execSilent("""
                CREATE TABLE IF NOT EXISTS confirmations (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    tool_name       TEXT NOT NULL,
                    requested_at    REAL NOT NULL,
                    decided_at      REAL NOT NULL,
                    decision        TEXT NOT NULL,
                    decided_by      TEXT NOT NULL,
                    reason          TEXT,
                    prev_hash       TEXT,
                    entry_hash      TEXT,
                    chain_anchor_id INTEGER
                );
            """)
            execSilent("CREATE INDEX IF NOT EXISTS idx_confirmations_tool ON confirmations(tool_name, requested_at DESC);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_confirmations_decision ON confirmations(decision, requested_at DESC);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_confirmations_anchor ON confirmations(chain_anchor_id, id);")
        }
    }

    // MARK: - Writes

    /// Insert one confirmation row. Returns the new rowid, or -1 on
    /// failure. Synchronous on `parent.queue` — the gate calls this
    /// inline because the decision must persist before the caller
    /// proceeds.
    @discardableResult
    func record(_ row: ConfirmationRow) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return -1 }

            let anchorId = chain.resolveAnchorId(db: db)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            let columns: [String: ChainHasher.CanonicalValue] = [
                "tool_name":    .text(row.toolName),
                "requested_at": .real(row.requestedAt.timeIntervalSince1970),
                "decided_at":   .real(row.decidedAt.timeIntervalSince1970),
                "decision":     .text(row.decision.rawValue),
                "decided_by":   .text(row.decidedBy.rawValue),
                "reason":       row.reason.map { .text($0) } ?? .null,
            ]
            let entryHash = ChainHasher.entryHash(
                table: "confirmations", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO confirmations
                    (tool_name, requested_at, decided_at, decision,
                     decided_by, reason,
                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (row.toolName as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, row.requestedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, row.decidedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, (row.decision.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (row.decidedBy.rawValue as NSString).utf8String, -1, nil)
            Self.bindOptionalText(stmt, 6, row.reason)
            Self.bindOptionalText(stmt, 7, prevHash)
            sqlite3_bind_text(stmt, 8, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 9, anchorId)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
            chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            return sqlite3_last_insert_rowid(db)
        }
    }

    // MARK: - Reads

    func count() -> Int {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM confirmations;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    /// Recent confirmation rows, newest first. For tests + diagnostics.
    func recent(limit: Int = 50) -> [ConfirmationRow] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, tool_name, requested_at, decided_at,
                       decision, decided_by, reason
                FROM confirmations
                ORDER BY id DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(max(0, limit)))

            var out: [ConfirmationRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let decisionRaw = String(cString: sqlite3_column_text(stmt, 4))
                let byRaw = String(cString: sqlite3_column_text(stmt, 5))
                guard
                    let decision = ConfirmationDecision(rawValue: decisionRaw),
                    let decidedBy = ConfirmationDecidedBy(rawValue: byRaw)
                else { continue }
                let reason: String? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(stmt, 6))
                out.append(ConfirmationRow(
                    id: sqlite3_column_int64(stmt, 0),
                    toolName: String(cString: sqlite3_column_text(stmt, 1)),
                    requestedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    decidedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    decision: decision,
                    decidedBy: decidedBy,
                    reason: reason
                ))
            }
            return out
        }
    }

    // MARK: - Helpers

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, (val as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func execSilent(_ sql: String) {
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err { sqlite3_free(err) }
    }
}

// MARK: - Public model

/// What the gate decided about a write/exec call.
public enum ConfirmationDecision: String, Sendable, Codable, Equatable, CaseIterable {
    case approve
    case deny
    /// The gate auto-approved without operator interaction (default
    /// production policy in round 1, since the Settings UI has no
    /// "block by default" mode yet). Distinguished from `approve` so
    /// post-hoc audits can tell operator-confirmed calls apart from
    /// policy-skipped ones.
    case auto
}

/// Who decided.
public enum ConfirmationDecidedBy: String, Sendable, Codable, Equatable, CaseIterable {
    /// A human acted on a Settings prompt.
    case `operator`
    /// A pre-configured policy made the decision (e.g. "never confirm
    /// reads from a trusted project").
    case policy
    /// The default auto-approve path fired — no operator, no policy.
    case auto
}

/// One row of the `confirmations` table.
public struct ConfirmationRow: Sendable, Equatable {
    public let id: Int64
    public let toolName: String
    public let requestedAt: Date
    public let decidedAt: Date
    public let decision: ConfirmationDecision
    public let decidedBy: ConfirmationDecidedBy
    public let reason: String?

    public init(
        id: Int64 = -1,
        toolName: String,
        requestedAt: Date,
        decidedAt: Date,
        decision: ConfirmationDecision,
        decidedBy: ConfirmationDecidedBy,
        reason: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.requestedAt = requestedAt
        self.decidedAt = decidedAt
        self.decision = decision
        self.decidedBy = decidedBy
        self.reason = reason
    }
}
