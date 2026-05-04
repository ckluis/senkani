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

    /// Idempotent — Migration v8 owns the original canonical schema;
    /// migration v10 (Phase U.1b) appends `ladder_position`. This method
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
                    ladder_position       INTEGER,
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
                    egress_decisions      INTEGER NOT NULL DEFAULT 0,
                    plan_id               TEXT REFERENCES context_plans(id),
                    cost_ledger_version   INTEGER
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
                    (idempotency_key, pane, project, model, tier, ladder_position,
                     feature, result, started_at, completed_at, latency_ms,
                     tokens_in, tokens_out, cost_cents, redaction_count,
                     validation_status, confirmation_required, egress_decisions,
                     plan_id, cost_ledger_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            Self.bindOptionalInt(stmt, 6, row.ladderPosition)
            Self.bindOptionalText(stmt, 7, row.feature)
            sqlite3_bind_text(stmt, 8, (row.result as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 9, row.startedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 10, row.completedAt.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 11, Int64(row.latencyMs))
            sqlite3_bind_int64(stmt, 12, Int64(row.tokensIn))
            sqlite3_bind_int64(stmt, 13, Int64(row.tokensOut))
            sqlite3_bind_int64(stmt, 14, Int64(row.costCents))
            sqlite3_bind_int64(stmt, 15, Int64(row.redactionCount))
            Self.bindOptionalText(stmt, 16, row.validationStatus)
            sqlite3_bind_int64(stmt, 17, row.confirmationRequired ? 1 : 0)
            sqlite3_bind_int64(stmt, 18, Int64(row.egressDecisions))
            Self.bindOptionalText(stmt, 19, row.planId)
            // Default to the live ledger version so callers don't need
            // to thread it through every call site. Replays and
            // back-dated writes pass an explicit value.
            sqlite3_bind_int64(stmt, 20, Int64(row.costLedgerVersion ?? CostLedger.currentVersion))

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

    /// Read back the full row for an idempotency key. Returns `nil` if
    /// no row matches. U.6a uses this to verify `plan_id` round-trips
    /// through the write path; later phases may grow first-class
    /// pivots that include `plan_id` directly.
    func fetchByIdempotencyKey(_ key: String) -> AgentTraceEvent? {
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
            let sql = """
                SELECT idempotency_key, pane, project, model, tier, ladder_position,
                       feature, result, started_at, completed_at, latency_ms,
                       tokens_in, tokens_out, cost_cents, redaction_count,
                       validation_status, confirmation_required, egress_decisions,
                       plan_id, cost_ledger_version
                FROM agent_trace_event
                WHERE idempotency_key = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            func text(_ i: Int32) -> String? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(stmt, i))
            }
            func int(_ i: Int32) -> Int? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int64(stmt, i))
            }
            return AgentTraceEvent(
                idempotencyKey: String(cString: sqlite3_column_text(stmt, 0)),
                pane: text(1),
                project: text(2),
                model: text(3),
                tier: text(4),
                ladderPosition: int(5),
                feature: text(6),
                result: String(cString: sqlite3_column_text(stmt, 7)),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
                completedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)),
                latencyMs: Int(sqlite3_column_int64(stmt, 10)),
                tokensIn: Int(sqlite3_column_int64(stmt, 11)),
                tokensOut: Int(sqlite3_column_int64(stmt, 12)),
                costCents: Int(sqlite3_column_int64(stmt, 13)),
                redactionCount: Int(sqlite3_column_int64(stmt, 14)),
                validationStatus: text(15),
                confirmationRequired: sqlite3_column_int64(stmt, 16) != 0,
                egressDecisions: Int(sqlite3_column_int64(stmt, 17)),
                planId: text(18),
                costLedgerVersion: int(19)
            )
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

    /// W.4: token usage rollup for the ContextSaturationGate. Sums
    /// `tokens_in + tokens_out` over an optional pane / project / time
    /// window. The gate divides this by the configured budget to derive
    /// a saturation percent.
    func tokenUsage(pane: String? = nil, project: String? = nil, since: Date? = nil) -> AgentTraceTokenUsage {
        return parent.queue.sync {
            guard let db = parent.db else { return AgentTraceTokenUsage(eventCount: 0, totalTokensIn: 0, totalTokensOut: 0) }
            var sql = """
                SELECT COUNT(*),
                       COALESCE(SUM(tokens_in), 0),
                       COALESCE(SUM(tokens_out), 0)
                FROM agent_trace_event
                """
            var clauses: [String] = []
            if pane != nil { clauses.append("pane = ?") }
            if project != nil { clauses.append("project = ?") }
            if since != nil { clauses.append("started_at >= ?") }
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            sql += ";"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return AgentTraceTokenUsage(eventCount: 0, totalTokensIn: 0, totalTokensOut: 0)
            }
            defer { sqlite3_finalize(stmt) }

            var idx: Int32 = 1
            if let pane { sqlite3_bind_text(stmt, idx, (pane as NSString).utf8String, -1, nil); idx += 1 }
            if let project { sqlite3_bind_text(stmt, idx, (project as NSString).utf8String, -1, nil); idx += 1 }
            if let since { sqlite3_bind_double(stmt, idx, since.timeIntervalSince1970); idx += 1 }

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return AgentTraceTokenUsage(eventCount: 0, totalTokensIn: 0, totalTokensOut: 0)
            }
            return AgentTraceTokenUsage(
                eventCount: Int(sqlite3_column_int64(stmt, 0)),
                totalTokensIn: Int(sqlite3_column_int64(stmt, 1)),
                totalTokensOut: Int(sqlite3_column_int64(stmt, 2))
            )
        }
    }

    /// W.4: most-recent N idempotency keys for a pane / project window.
    /// Used by `PreCompactHandoffWriter` to record the trace tail in the
    /// handoff card so the next session can resume diagnostics.
    func recentTraceKeys(pane: String? = nil, project: String? = nil, limit: Int = 10) -> [String] {
        return parent.queue.sync {
            guard let db = parent.db, limit > 0 else { return [] }
            var sql = """
                SELECT idempotency_key
                FROM agent_trace_event
                """
            var clauses: [String] = []
            if pane != nil { clauses.append("pane = ?") }
            if project != nil { clauses.append("project = ?") }
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            sql += " ORDER BY started_at DESC LIMIT ?;"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var idx: Int32 = 1
            if let pane { sqlite3_bind_text(stmt, idx, (pane as NSString).utf8String, -1, nil); idx += 1 }
            if let project { sqlite3_bind_text(stmt, idx, (project as NSString).utf8String, -1, nil); idx += 1 }
            sqlite3_bind_int64(stmt, idx, Int64(limit))

            var out: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return out
        }
    }

    /// Mode 4 (counterfactual replay): full rows for a project window in
    /// chronological order. Replay needs every dimension and measure on
    /// every row (to project a per-row counterfactual), not a pivot. The
    /// query is a forward scan on the existing `(project, started_at)`
    /// index so it stays cheap even on long sessions.
    func rowsInWindow(project: String?, since: Date?, limit: Int = 10_000) -> [AgentTraceEvent] {
        return parent.queue.sync {
            guard let db = parent.db, limit > 0 else { return [] }
            var sql = """
                SELECT idempotency_key, pane, project, model, tier, ladder_position,
                       feature, result, started_at, completed_at, latency_ms,
                       tokens_in, tokens_out, cost_cents, redaction_count,
                       validation_status, confirmation_required, egress_decisions,
                       plan_id, cost_ledger_version
                FROM agent_trace_event
                """
            var clauses: [String] = []
            if project != nil { clauses.append("project = ?") }
            if since != nil { clauses.append("started_at >= ?") }
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            sql += " ORDER BY started_at ASC LIMIT ?;"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var idx: Int32 = 1
            if let project { sqlite3_bind_text(stmt, idx, (project as NSString).utf8String, -1, nil); idx += 1 }
            if let since { sqlite3_bind_double(stmt, idx, since.timeIntervalSince1970); idx += 1 }
            sqlite3_bind_int64(stmt, idx, Int64(limit))

            func text(_ i: Int32) -> String? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i))
            }
            func intOpt(_ i: Int32) -> Int? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
            }

            var out: [AgentTraceEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(AgentTraceEvent(
                    idempotencyKey: String(cString: sqlite3_column_text(stmt, 0)),
                    pane: text(1),
                    project: text(2),
                    model: text(3),
                    tier: text(4),
                    ladderPosition: intOpt(5),
                    feature: text(6),
                    result: String(cString: sqlite3_column_text(stmt, 7)),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
                    completedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)),
                    latencyMs: Int(sqlite3_column_int64(stmt, 10)),
                    tokensIn: Int(sqlite3_column_int64(stmt, 11)),
                    tokensOut: Int(sqlite3_column_int64(stmt, 12)),
                    costCents: Int(sqlite3_column_int64(stmt, 13)),
                    redactionCount: Int(sqlite3_column_int64(stmt, 14)),
                    validationStatus: text(15),
                    confirmationRequired: sqlite3_column_int64(stmt, 16) != 0,
                    egressDecisions: Int(sqlite3_column_int64(stmt, 17)),
                    planId: text(18),
                    costLedgerVersion: intOpt(19)
                ))
            }
            return out
        }
    }

    /// U.1c: tier-distribution rollup over a time window. Counts rows
    /// per `tier` and per `(tier, ladderPosition)` so the AnalyticsView
    /// can render either a stacked bar (tier-only) or a grouped bar
    /// (tier × primary-vs-fallback) without re-querying.
    ///
    /// Rows whose `tier` is NULL (pre-U.1 traces and non-routed paths)
    /// are excluded — the chart's empty-state copy explains why.
    func tierDistribution(since: Date) -> [AgentTraceTierBucket] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT tier,
                       COALESCE(ladder_position, -1),
                       COUNT(*)
                FROM agent_trace_event
                WHERE tier IS NOT NULL AND started_at >= ?
                GROUP BY tier, COALESCE(ladder_position, -1)
                ORDER BY tier;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)

            var out: [AgentTraceTierBucket] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tier = String(cString: sqlite3_column_text(stmt, 0))
                let rawLadder = Int(sqlite3_column_int64(stmt, 1))
                let ladder: Int? = rawLadder < 0 ? nil : rawLadder
                let count = Int(sqlite3_column_int64(stmt, 2))
                out.append(AgentTraceTierBucket(tier: tier, ladderPosition: ladder, count: count))
            }
            return out
        }
    }

    /// U.1c: list trace rows matching `tier` within a time window. Powers
    /// the drill-down sheet — operator clicks a bar, sees the underlying
    /// rows. Capped at `limit` to keep the sheet responsive on busy days.
    func tracesForTier(_ tier: String, since: Date, limit: Int = 200) -> [AgentTraceTierRow] {
        return parent.queue.sync {
            guard let db = parent.db, limit > 0 else { return [] }
            let sql = """
                SELECT idempotency_key, pane, project, model, tier, ladder_position,
                       feature, result, started_at, latency_ms, tokens_in, tokens_out,
                       cost_cents, cost_ledger_version
                FROM agent_trace_event
                WHERE tier = ? AND started_at >= ?
                ORDER BY started_at DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (tier as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 3, Int64(limit))

            var out: [AgentTraceTierRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(stmt, 0))
                let pane = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 1))
                let project = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 2))
                let model = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3))
                let tierVal = String(cString: sqlite3_column_text(stmt, 4))
                let ladder: Int? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 5))
                let feature = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 6))
                let result = String(cString: sqlite3_column_text(stmt, 7))
                let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
                let ledgerVersion: Int? = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 13))
                out.append(AgentTraceTierRow(
                    idempotencyKey: key,
                    pane: pane, project: project, model: model,
                    tier: tierVal, ladderPosition: ladder, feature: feature,
                    result: result, startedAt: startedAt,
                    latencyMs: Int(sqlite3_column_int64(stmt, 9)),
                    tokensIn: Int(sqlite3_column_int64(stmt, 10)),
                    tokensOut: Int(sqlite3_column_int64(stmt, 11)),
                    costCents: Int(sqlite3_column_int64(stmt, 12)),
                    costLedgerVersion: ledgerVersion
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

    private static func bindOptionalInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let val = value {
            sqlite3_bind_int64(stmt, index, Int64(val))
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
    /// TaskTier (intent) the router chose for this call, e.g. "simple",
    /// "standard", "complex", "reasoning". Populated by U.1; nil for
    /// non-routed paths.
    public let tier: String?
    /// Which rung of the FallbackLadder produced the resolved
    /// ModelTier. 0 = primary, 1 = first fallback, etc. nil for
    /// non-routed paths. Phase U.1b — paired with `tier` so the
    /// analytics chart can split "primary used" from "fell back".
    public let ladderPosition: Int?
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
    /// U.6a — UUID of the `ContextPlan` row this trace was paired with.
    /// nil for trace rows produced outside the combinator path; the
    /// FK is declared via `REFERENCES context_plans(id)` for documented
    /// intent.
    public let planId: String?
    /// Cost-ledger version under which `costCents` was priced. nil
    /// means "not specified at write time" — the store will default to
    /// `CostLedger.currentVersion`. Replays and back-dated writes pass
    /// an explicit value so historical rates aren't silently rebased
    /// when the live ledger advances.
    public let costLedgerVersion: Int?

    public init(
        idempotencyKey: String,
        pane: String? = nil,
        project: String? = nil,
        model: String? = nil,
        tier: String? = nil,
        ladderPosition: Int? = nil,
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
        egressDecisions: Int = 0,
        planId: String? = nil,
        costLedgerVersion: Int? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.pane = pane
        self.project = project
        self.model = model
        self.tier = tier
        self.ladderPosition = ladderPosition
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
        self.planId = planId
        self.costLedgerVersion = costLedgerVersion
    }
}

/// Token-usage rollup for the W.4 ContextSaturationGate. The sum is
/// across `tokens_in + tokens_out` of the matching rows; callers divide
/// by the configured context budget to get a saturation percent.
public struct AgentTraceTokenUsage: Sendable, Equatable {
    public let eventCount: Int
    public let totalTokensIn: Int
    public let totalTokensOut: Int
    public var totalTokens: Int { totalTokensIn + totalTokensOut }
    public init(eventCount: Int, totalTokensIn: Int, totalTokensOut: Int) {
        self.eventCount = eventCount
        self.totalTokensIn = totalTokensIn
        self.totalTokensOut = totalTokensOut
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

/// U.1c: one bucket of the tier-distribution rollup. `ladderPosition` is
/// nil for rows that pre-date the ladder column (kept for chart symmetry).
public struct AgentTraceTierBucket: Sendable, Equatable, Identifiable {
    public let tier: String
    public let ladderPosition: Int?
    public let count: Int
    public var id: String { "\(tier)#\(ladderPosition.map(String.init) ?? "nil")" }
    public init(tier: String, ladderPosition: Int?, count: Int) {
        self.tier = tier
        self.ladderPosition = ladderPosition
        self.count = count
    }
}

/// U.1c: a single trace row surfaced by the drill-down sheet.
public struct AgentTraceTierRow: Sendable, Equatable, Identifiable {
    public let idempotencyKey: String
    public let pane: String?
    public let project: String?
    public let model: String?
    public let tier: String
    public let ladderPosition: Int?
    public let feature: String?
    public let result: String
    public let startedAt: Date
    public let latencyMs: Int
    public let tokensIn: Int
    public let tokensOut: Int
    public let costCents: Int
    /// Ledger version stamped at write time. nil for rows written before
    /// migration v16. The drill-down view uses this to decide whether to
    /// surface a repriced number alongside the stored one.
    public let costLedgerVersion: Int?
    public var id: String { idempotencyKey }
    public init(
        idempotencyKey: String, pane: String?, project: String?, model: String?,
        tier: String, ladderPosition: Int?, feature: String?, result: String,
        startedAt: Date, latencyMs: Int, tokensIn: Int, tokensOut: Int, costCents: Int,
        costLedgerVersion: Int? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.pane = pane
        self.project = project
        self.model = model
        self.tier = tier
        self.ladderPosition = ladderPosition
        self.feature = feature
        self.result = result
        self.startedAt = startedAt
        self.latencyMs = latencyMs
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costCents = costCents
        self.costLedgerVersion = costLedgerVersion
    }
}
