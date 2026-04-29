import Foundation
import SQLite3

/// Owns `agent_trace_event` — the Stripe-style canonical trace row that
/// holds every conformed dimension a query would otherwise stitch from
/// raw `token_events`. One row per tool call, written at completion time.
///
/// Idempotency: every write goes through `INSERT ... ON CONFLICT
/// (idempotency_key) DO NOTHING`. The call site is responsible for
/// fingerprinting its inputs into a stable `idempotency_key` (Schneier:
/// not caller-supplied, derived). A retry of the same tool call with the
/// same inputs lands one row, not two.
///
/// Phase V.2 of the roadmap. The `tier` column is populated by U.1
/// (TierScorer) once that round lands; until then it is NULL.
///
/// Audit chain note: this store does NOT participate in the chain (V.2's
/// scope keeps it derived). Source rows in `token_events` ARE chain-
/// anchored, so tampering the canonical row is detectable by re-deriving
/// from the source. See `spec/architecture.md` → "Canonical Trace Rows".
final class AgentTraceEventStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    // MARK: - Schema

    /// Idempotent — Migration v8 owns the canonical schema. This method
    /// stays so the store init pattern matches the other stores (every
    /// store calls `setupSchema()` after construction).
    func setupSchema() {
        parent.queue.sync {
            execSilent("""
                CREATE TABLE IF NOT EXISTS agent_trace_event (
                    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
                    idempotency_key       TEXT NOT NULL UNIQUE,
                    pane                  TEXT,
                    project               TEXT,
                    model                 TEXT,
                    tier                  TEXT,
                    feature               TEXT,
                    result                TEXT NOT NULL,
                    started_at            REAL NOT NULL,
                    completed_at          REAL NOT NULL,
                    latency_ms            INTEGER NOT NULL DEFAULT 0,
                    tokens_in             INTEGER NOT NULL DEFAULT 0,
                    tokens_out            INTEGER NOT NULL DEFAULT 0,
                    cost_cents            INTEGER NOT NULL DEFAULT 0,
                    redaction_count       INTEGER NOT NULL DEFAULT 0,
                    validation_status     TEXT,
                    confirmation_required INTEGER NOT NULL DEFAULT 0,
                    egress_decisions      INTEGER NOT NULL DEFAULT 0
                );
            """)
            execSilent("CREATE INDEX IF NOT EXISTS idx_agent_trace_project_started ON agent_trace_event(project, started_at);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_agent_trace_pane_started ON agent_trace_event(pane, started_at);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_agent_trace_feature_started ON agent_trace_event(feature, started_at);")
        }
    }

    // MARK: - Writes

    /// Record one canonical trace row. A retry with the same
    /// `idempotencyKey` is a no-op — the UNIQUE constraint + ON CONFLICT
    /// DO NOTHING dedup at the SQL layer. Returns `true` if the insert
    /// landed a new row, `false` if it was deduped.
    @discardableResult
    func record(_ row: AgentTraceEvent) -> Bool {
        return parent.queue.sync {
            guard let db = parent.db else { return false }
            let sql = """
                INSERT INTO agent_trace_event
                    (idempotency_key, pane, project, model, tier, feature, result,
                     started_at, completed_at, latency_ms, tokens_in, tokens_out,
                     cost_cents, redaction_count, validation_status,
                     confirmation_required, egress_decisions)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(idempotency_key) DO NOTHING;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (row.idempotencyKey as NSString).utf8String, -1, nil)
            Self.bindOptionalText(stmt, 2, row.pane)
            Self.bindOptionalText(stmt, 3, row.project)
            Self.bindOptionalText(stmt, 4, row.model)
            Self.bindOptionalText(stmt, 5, row.tier)
            Self.bindOptionalText(stmt, 6, row.feature)
            sqlite3_bind_text(stmt, 7, (row.result as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 8, row.startedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 9, row.completedAt.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 10, Int64(row.latencyMs))
            sqlite3_bind_int64(stmt, 11, Int64(row.tokensIn))
            sqlite3_bind_int64(stmt, 12, Int64(row.tokensOut))
            sqlite3_bind_int64(stmt, 13, Int64(row.costCents))
            sqlite3_bind_int64(stmt, 14, Int64(row.redactionCount))
            Self.bindOptionalText(stmt, 15, row.validationStatus)
            sqlite3_bind_int64(stmt, 16, row.confirmationRequired ? 1 : 0)
            sqlite3_bind_int64(stmt, 17, Int64(row.egressDecisions))

            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            return sqlite3_changes(db) > 0
        }
    }

    // MARK: - Counts + reads

    func countAll() -> Int {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM agent_trace_event;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    /// All rows with the given idempotency key — for tests / debugging.
    /// In normal operation this returns 0 or 1 row by construction.
    func rowsWithIdempotencyKey(_ key: String) -> Int {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM agent_trace_event WHERE idempotency_key = ?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    // MARK: - Pivots (canonical-first analytics)

    /// Pivot 1: per-project rollup (count, total cost, total tokens, mean latency).
    func pivotByProject(since: Date? = nil) -> [AgentTraceProjectRollup] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            var sql = """
                SELECT COALESCE(project, ''),
                       COUNT(*),
                       COALESCE(SUM(cost_cents), 0),
                       COALESCE(SUM(tokens_in), 0),
                       COALESCE(SUM(tokens_out), 0),
                       COALESCE(AVG(latency_ms), 0)
                FROM agent_trace_event
                """
            if since != nil { sql += " WHERE started_at >= ?" }
            sql += " GROUP BY project ORDER BY COUNT(*) DESC;"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let since { sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970) }

            var out: [AgentTraceProjectRollup] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(AgentTraceProjectRollup(
                    project: String(cString: sqlite3_column_text(stmt, 0)),
                    eventCount: Int(sqlite3_column_int64(stmt, 1)),
                    totalCostCents: Int(sqlite3_column_int64(stmt, 2)),
                    totalTokensIn: Int(sqlite3_column_int64(stmt, 3)),
                    totalTokensOut: Int(sqlite3_column_int64(stmt, 4)),
                    meanLatencyMs: sqlite3_column_double(stmt, 5)
                ))
            }
            return out
        }
    }

    /// Pivot 2: per-feature rollup with success/failure split.
    func pivotByFeature(since: Date? = nil) -> [AgentTraceFeatureRollup] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            var sql = """
                SELECT COALESCE(feature, ''),
                       COUNT(*),
                       SUM(CASE WHEN result = 'success' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN result != 'success' THEN 1 ELSE 0 END),
                       COALESCE(SUM(tokens_in), 0),
                       COALESCE(SUM(tokens_out), 0)
                FROM agent_trace_event
                """
            if since != nil { sql += " WHERE started_at >= ?" }
            sql += " GROUP BY feature ORDER BY COUNT(*) DESC;"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let since { sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970) }

            var out: [AgentTraceFeatureRollup] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(AgentTraceFeatureRollup(
                    feature: String(cString: sqlite3_column_text(stmt, 0)),
                    eventCount: Int(sqlite3_column_int64(stmt, 1)),
                    successCount: Int(sqlite3_column_int64(stmt, 2)),
                    failureCount: Int(sqlite3_column_int64(stmt, 3)),
                    totalTokensIn: Int(sqlite3_column_int64(stmt, 4)),
                    totalTokensOut: Int(sqlite3_column_int64(stmt, 5))
                ))
            }
            return out
        }
    }

    /// Pivot 3: per-result distribution (top-line "what's failing").
    func pivotByResult(since: Date? = nil) -> [AgentTraceResultRollup] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            var sql = """
                SELECT result,
                       COUNT(*),
                       COALESCE(AVG(latency_ms), 0),
                       COALESCE(SUM(cost_cents), 0)
                FROM agent_trace_event
                """
            if since != nil { sql += " WHERE started_at >= ?" }
            sql += " GROUP BY result ORDER BY COUNT(*) DESC;"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let since { sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970) }

            var out: [AgentTraceResultRollup] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(AgentTraceResultRollup(
                    result: String(cString: sqlite3_column_text(stmt, 0)),
                    eventCount: Int(sqlite3_column_int64(stmt, 1)),
                    meanLatencyMs: sqlite3_column_double(stmt, 2),
                    totalCostCents: Int(sqlite3_column_int64(stmt, 3))
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

/// One canonical trace row — every conformed dimension + measure for a
/// single tool call. Build at the call site once the tool call completes;
/// pass to `SessionDatabase.recordAgentTraceEvent`.
public struct AgentTraceEvent: Sendable, Equatable {
    /// Stable fingerprint of the call inputs. Required UNIQUE — a retry
    /// with the same key dedups in the DB. Schneier: derive from canonical
    /// inputs at the call site; never accept caller-supplied keys.
    public let idempotencyKey: String

    // Conformed dimensions (Kleppmann: documented in architecture.md
    // "Canonical Trace Rows" before merge).
    public let pane: String?
    public let project: String?
    public let model: String?
    /// Populated by U.1 (TierScorer) once that round lands; nil until then.
    public let tier: String?
    public let feature: String?
    /// One of: `success`, `error`, `timeout`, `denied`, `cached`. The store
    /// does not validate the vocabulary — pivots count distinct values.
    public let result: String

    public let startedAt: Date
    public let completedAt: Date

    // Measures.
    public let latencyMs: Int
    public let tokensIn: Int
    public let tokensOut: Int
    public let costCents: Int
    public let redactionCount: Int
    public let validationStatus: String?
    public let confirmationRequired: Bool
    public let egressDecisions: Int

    public init(
        idempotencyKey: String,
        pane: String? = nil,
        project: String? = nil,
        model: String? = nil,
        tier: String? = nil,
        feature: String? = nil,
        result: String,
        startedAt: Date,
        completedAt: Date,
        latencyMs: Int = 0,
        tokensIn: Int = 0,
        tokensOut: Int = 0,
        costCents: Int = 0,
        redactionCount: Int = 0,
        validationStatus: String? = nil,
        confirmationRequired: Bool = false,
        egressDecisions: Int = 0
    ) {
        self.idempotencyKey = idempotencyKey
        self.pane = pane
        self.project = project
        self.model = model
        self.tier = tier
        self.feature = feature
        self.result = result
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.latencyMs = latencyMs
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costCents = costCents
        self.redactionCount = redactionCount
        self.validationStatus = validationStatus
        self.confirmationRequired = confirmationRequired
        self.egressDecisions = egressDecisions
    }
}

public struct AgentTraceProjectRollup: Sendable, Equatable {
    public let project: String
    public let eventCount: Int
    public let totalCostCents: Int
    public let totalTokensIn: Int
    public let totalTokensOut: Int
    public let meanLatencyMs: Double
}

public struct AgentTraceFeatureRollup: Sendable, Equatable {
    public let feature: String
    public let eventCount: Int
    public let successCount: Int
    public let failureCount: Int
    public let totalTokensIn: Int
    public let totalTokensOut: Int
}

public struct AgentTraceResultRollup: Sendable, Equatable {
    public let result: String
    public let eventCount: Int
    public let meanLatencyMs: Double
    public let totalCostCents: Int
}
