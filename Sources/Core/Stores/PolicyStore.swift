import Foundation
import SQLite3

/// Owns `policy_snapshots` — one row per (session, distinct policy) pair
/// captured at session start. The `policy_hash` UNIQUE constraint dedups
/// re-captures of the same configuration within one session so the
/// table doesn't accumulate noise on chatty bootstrap paths.
///
/// Phase prerequisite for counterfactual replay (`spec/testing.md`
/// → Mode 4). Without a recoverable per-session policy, "what would
/// have happened under a different policy?" has no baseline to diff
/// against.
final class PolicyStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    // MARK: - Schema

    /// Idempotent. Migration v15 owns the canonical schema; this method
    /// stays so the store init pattern matches every other store
    /// (each calls `setupSchema()` after construction).
    func setupSchema() {
        parent.queue.sync {
            execSilent("""
                CREATE TABLE IF NOT EXISTS policy_snapshots (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id   TEXT NOT NULL,
                    captured_at  REAL NOT NULL,
                    policy_hash  TEXT NOT NULL,
                    policy_json  TEXT NOT NULL,
                    UNIQUE(session_id, policy_hash)
                );
            """)
            execSilent("CREATE INDEX IF NOT EXISTS idx_policy_snapshots_session ON policy_snapshots(session_id, captured_at DESC);")
        }
    }

    // MARK: - Writes

    /// Persist `config` against `sessionId`. Returns `true` if a new
    /// row was inserted, `false` if the (session_id, policy_hash) pair
    /// already existed (no-op via `ON CONFLICT DO NOTHING`).
    @discardableResult
    func capture(sessionId: String, config: PolicyConfig) -> Bool {
        let hash = config.policyHash()
        guard let json = try? config.prettyJSON() else { return false }
        return parent.queue.sync {
            guard let db = parent.db else { return false }
            let sql = """
                INSERT INTO policy_snapshots (session_id, captured_at, policy_hash, policy_json)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(session_id, policy_hash) DO NOTHING;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, config.capturedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (hash as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (json as NSString).utf8String, -1, nil)
            let rc = sqlite3_step(stmt)
            return rc == SQLITE_DONE && sqlite3_changes(db) > 0
        }
    }

    // MARK: - Reads

    /// The most recently captured snapshot for a session, or nil when
    /// the session predates Phase X (this round) or the row is missing.
    func latest(sessionId: String) -> PolicySnapshotRow? {
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
            let sql = """
                SELECT id, captured_at, policy_hash, policy_json
                FROM policy_snapshots
                WHERE session_id = ?
                ORDER BY captured_at DESC
                LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return PolicySnapshotRow(
                id: Int(sqlite3_column_int64(stmt, 0)),
                sessionId: sessionId,
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                policyHash: String(cString: sqlite3_column_text(stmt, 2)),
                policyJSON: String(cString: sqlite3_column_text(stmt, 3))
            )
        }
    }

    /// All snapshots for a session, newest first. Used by audit surfaces
    /// that need to confirm config didn't shift mid-session.
    func all(sessionId: String) -> [PolicySnapshotRow] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, captured_at, policy_hash, policy_json
                FROM policy_snapshots
                WHERE session_id = ?
                ORDER BY captured_at DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            var out: [PolicySnapshotRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(PolicySnapshotRow(
                    id: Int(sqlite3_column_int64(stmt, 0)),
                    sessionId: sessionId,
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    policyHash: String(cString: sqlite3_column_text(stmt, 2)),
                    policyJSON: String(cString: sqlite3_column_text(stmt, 3))
                ))
            }
            return out
        }
    }

    // MARK: - Helpers

    private func execSilent(_ sql: String) {
        guard let db = parent.db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

/// One row of `policy_snapshots`. The decoded `PolicyConfig` is exposed
/// via `decoded()` to keep the row model SQL-shaped and the policy
/// model JSON-shaped — same separation as `agent_trace_event` rows.
public struct PolicySnapshotRow: Sendable, Codable {
    public let id: Int
    public let sessionId: String
    public let capturedAt: Date
    public let policyHash: String
    public let policyJSON: String

    public init(
        id: Int,
        sessionId: String,
        capturedAt: Date,
        policyHash: String,
        policyJSON: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.capturedAt = capturedAt
        self.policyHash = policyHash
        self.policyJSON = policyJSON
    }

    public func decoded() -> PolicyConfig? {
        guard let data = policyJSON.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PolicyConfig.self, from: data)
    }
}
