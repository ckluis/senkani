import Foundation

/// Public façade for `context_plans` (Phase U.6a). Forwards to
/// `ContextPlanStore`; matches the per-feature `+API.swift` convention
/// used by `SessionDatabase+AgentTraceAPI`, `+CommandAPI`, etc.
extension SessionDatabase {

    /// Insert one plan row. Idempotent on `id` — a retry with the
    /// same UUID dedups in the DB. Returns `true` if a new row was
    /// written, `false` on duplicate-id (UUID collision).
    @discardableResult
    public func recordContextPlan(_ plan: ContextPlan) -> Bool {
        return contextPlanStore.insert(plan)
    }

    /// Fetch one plan by its UUID.
    public func contextPlan(id: String) -> ContextPlan? {
        return contextPlanStore.fetchById(id)
    }

    /// Fetch all plans for a session, newest-first.
    public func contextPlans(forSession sessionId: String) -> [ContextPlan] {
        return contextPlanStore.fetchBySession(sessionId)
    }

    /// Total count of plan rows. For tests + diagnostics.
    public func contextPlanCount() -> Int {
        return contextPlanStore.countAll()
    }
}
