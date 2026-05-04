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

    // T.5 chain state for this table — wired the same way
    // ConfirmationStore wires it. Migration v17 added the columns +
    // a 'migration-v17' anchor for any pre-existing rows.
    private let chain = ChainState(table: "policy_snapshots")

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Drop the chain cache after a `--repair-chain` motion. Caller
    /// must be on `parent.queue`. Mirrors ConfirmationStore.
    func invalidateChainCache() { chain.invalidate() }

    // MARK: - Schema

    /// Idempotent. Migrations v15 + v17 own the canonical schema;
    /// this method stays so the store init pattern matches every other
    /// store (each calls `setupSchema()` after construction). The SQL
    /// is exposed as a static so `PolicySchemaParityTests` can apply it
    /// to a setupSchema-only DB and assert byte-identical parity with
    /// the migrations-only path; until the session-DB schema-authority
    /// cleanup ships (see `spec/architecture.md` → "Schema authority"),
    /// the parity test is the guardrail against silent divergence.
    static let schemaSQL: [String] = [
        """
        CREATE TABLE IF NOT EXISTS policy_snapshots (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id      TEXT NOT NULL REFERENCES sessions(id),
            captured_at     REAL NOT NULL,
            policy_hash     TEXT NOT NULL,
            policy_json     TEXT NOT NULL,
            prev_hash       TEXT,
            entry_hash      TEXT,
            chain_anchor_id INTEGER,
            UNIQUE(session_id, policy_hash)
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_policy_snapshots_session ON policy_snapshots(session_id, captured_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_policy_snapshots_anchor ON policy_snapshots(chain_anchor_id, id);",
    ]

    func setupSchema() {
        parent.queue.sync {
            for sql in Self.schemaSQL { execSilent(sql) }
        }
    }

    // MARK: - Writes

    /// Persist `config` against `sessionId`. Returns `true` if a new
    /// row was inserted, `false` if the (session_id, policy_hash) pair
    /// already existed (no-op via `ON CONFLICT DO NOTHING`) **or** if
    /// hash computation / JSON serialization failed — in the failure
    /// case the call also bumps `event_counters("security.policy.hash_failed")`
    /// so the breach surfaces in `senkani stats --security` rather than
    /// silently colliding on `policy_hash = ""`.
    @discardableResult
    func capture(sessionId: String, config: PolicyConfig) -> Bool {
        let hash: String
        do {
            hash = try config.policyHash()
        } catch {
            parent.recordEvent(type: "security.policy.hash_failed")
            return false
        }
        guard let json = try? config.prettyJSON() else {
            parent.recordEvent(type: "security.policy.hash_failed")
            return false
        }
        return parent.queue.sync {
            guard let db = parent.db else { return false }

            // Resolve the current chain segment + prior tip BEFORE
            // computing the entry hash. The prior tip becomes this
            // row's prev_hash; the entry hash is computed over the
            // four data columns (the chain columns are excluded by
            // ChainHasher.excludedColumns contract).
            let anchorId = chain.resolveAnchorId(db: db)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            let columns: [String: ChainHasher.CanonicalValue] = [
                "session_id":  .text(sessionId),
                "captured_at": .real(config.capturedAt.timeIntervalSince1970),
                "policy_hash": .text(hash),
                "policy_json": .text(json),
            ]
            let entryHash = ChainHasher.entryHash(
                table: "policy_snapshots", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO policy_snapshots
                    (session_id, captured_at, policy_hash, policy_json,
                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id, policy_hash) DO NOTHING;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, config.capturedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (hash as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (json as NSString).utf8String, -1, nil)
            if let prevHash {
                sqlite3_bind_text(stmt, 5, (prevHash as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_text(stmt, 6, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 7, anchorId)

            let rc = sqlite3_step(stmt)
            // Dedup-no-advance: ON CONFLICT DO NOTHING returns DONE
            // with `sqlite3_changes(db) == 0`. The cache MUST NOT
            // advance in that case — a subsequent genuinely-new row
            // still chains off the previous tip, and verification
            // stays consistent.
            let inserted = rc == SQLITE_DONE && sqlite3_changes(db) > 0
            if inserted {
                chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            }
            return inserted
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
        dispatchPrecondition(condition: .onQueue(parent.queue))
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
