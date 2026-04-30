import Foundation
import SQLite3

/// Owns `context_plans` — one row per combinator-emitted plan. U.6a
/// ships only the persistence plumbing; U.6b adds the actual write
/// path from the `split` / `filter` / `reduce` operators, and U.6c
/// adds the variance-histogram analytics that pair plan with actual
/// via `agent_trace_event.plan_id`.
///
/// Append-only: once a plan is inserted it is never updated. The
/// matching `agent_trace_event` row carries the plan_id so plan/actual
/// pairing is observable from the trace side as well.
final class ContextPlanStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    // MARK: - Schema

    /// Idempotent — Migration v14 owns the canonical `context_plans`
    /// schema; this method matches the per-store init pattern (every
    /// store calls `setupSchema()` after construction so a fresh DB
    /// reaches the latest shape even before the migration runner
    /// applies the v14 row).
    func setupSchema() {
        parent.queue.sync {
            execSilent("""
                CREATE TABLE IF NOT EXISTS context_plans (
                    id              TEXT PRIMARY KEY,
                    session_id      TEXT NOT NULL,
                    planned_fanout  INTEGER NOT NULL,
                    leaf_size       INTEGER NOT NULL,
                    reducer_choice  TEXT NOT NULL,
                    estimated_cost  INTEGER NOT NULL,
                    created_at      REAL NOT NULL
                );
            """)
            execSilent("""
                CREATE INDEX IF NOT EXISTS idx_context_plans_session
                    ON context_plans(session_id, created_at DESC);
            """)
        }
    }

    // MARK: - Writes

    /// Insert one plan row. Returns `true` if the row was inserted,
    /// `false` if the `id` collided (UUID collision is astronomically
    /// unlikely; the `false` return exists for tests that exercise
    /// duplicate-id semantics).
    @discardableResult
    func insert(_ plan: ContextPlan) -> Bool {
        return parent.queue.sync {
            guard let db = parent.db else { return false }
            let sql = """
                INSERT INTO context_plans
                    (id, session_id, planned_fanout, leaf_size,
                     reducer_choice, estimated_cost, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (plan.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (plan.sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 3, Int64(plan.plannedFanout))
            sqlite3_bind_int64(stmt, 4, Int64(plan.leafSize))
            sqlite3_bind_text(stmt, 5, (plan.reducerChoice.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 6, Int64(plan.estimatedCost))
            sqlite3_bind_double(stmt, 7, plan.createdAt.timeIntervalSince1970)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            return sqlite3_changes(db) > 0
        }
    }

    // MARK: - Reads

    func fetchById(_ id: String) -> ContextPlan? {
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
            let sql = """
                SELECT id, session_id, planned_fanout, leaf_size,
                       reducer_choice, estimated_cost, created_at
                FROM context_plans
                WHERE id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            return Self.decodeRow(stmt)
        }
    }

    /// All plans for a session, newest-first by `created_at`.
    func fetchBySession(_ sessionId: String) -> [ContextPlan] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, session_id, planned_fanout, leaf_size,
                       reducer_choice, estimated_cost, created_at
                FROM context_plans
                WHERE session_id = ?
                ORDER BY created_at DESC, id;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)

            var out: [ContextPlan] = []
            while let row = Self.decodeRow(stmt) {
                out.append(row)
            }
            return out
        }
    }

    func countAll() -> Int {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM context_plans;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    /// U.6c — plan / actual pairs since `since`. One row per plan;
    /// `actualCostCents` is nil for plans with no matching
    /// `agent_trace_event` (rejected by BudgetGate or the closure threw
    /// before persistence). Drives the AnalyticsView variance histogram
    /// + the ≥ 90 % corpus pairing eval.
    ///
    /// Order: newest plans first, matching `fetchBySession`'s ordering.
    /// Bound by `created_at >= since` on the plan side so rejected plans
    /// (which have no trace) still surface in the window.
    func planActualPairs(since: Date) -> [PlanActualPair] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT p.id,
                       p.session_id,
                       p.planned_fanout,
                       p.leaf_size,
                       p.reducer_choice,
                       p.estimated_cost,
                       p.created_at,
                       t.cost_cents
                FROM context_plans p
                LEFT JOIN agent_trace_event t ON t.plan_id = p.id
                WHERE p.created_at >= ?
                ORDER BY p.created_at DESC, p.id;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)

            var out: [PlanActualPair] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let sessionId = String(cString: sqlite3_column_text(stmt, 1))
                let plannedFanout = Int(sqlite3_column_int64(stmt, 2))
                let leafSize = Int(sqlite3_column_int64(stmt, 3))
                let reducerRaw = String(cString: sqlite3_column_text(stmt, 4))
                let reducer = ReducerChoice(rawValue: reducerRaw) ?? .merge
                let estimated = Int(sqlite3_column_int64(stmt, 5))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                let actual: Int? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int64(stmt, 7))
                out.append(PlanActualPair(
                    planId: id,
                    sessionId: sessionId,
                    plannedFanout: plannedFanout,
                    leafSize: leafSize,
                    reducerChoice: reducer,
                    plannedCost: estimated,
                    actualCostCents: actual,
                    createdAt: createdAt
                ))
            }
            return out
        }
    }

    // MARK: - Helpers

    /// Step `stmt` once and decode the current row into a `ContextPlan`,
    /// or return `nil` if there is no further row. Caller drives the
    /// loop for multi-row reads.
    private static func decodeRow(_ stmt: OpaquePointer?) -> ContextPlan? {
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let sessionId = String(cString: sqlite3_column_text(stmt, 1))
        let plannedFanout = Int(sqlite3_column_int64(stmt, 2))
        let leafSize = Int(sqlite3_column_int64(stmt, 3))
        let reducerRaw = String(cString: sqlite3_column_text(stmt, 4))
        let reducer = ReducerChoice(rawValue: reducerRaw) ?? .merge
        let estimatedCost = Int(sqlite3_column_int64(stmt, 5))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        return ContextPlan(
            id: id,
            sessionId: sessionId,
            plannedFanout: plannedFanout,
            leafSize: leafSize,
            reducerChoice: reducer,
            estimatedCost: estimatedCost,
            createdAt: createdAt
        )
    }

    private func execSilent(_ sql: String) {
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err { sqlite3_free(err) }
    }
}
