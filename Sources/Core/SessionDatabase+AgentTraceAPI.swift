import Foundation

/// Public API for the V.2 canonical trace row. Forwards to the store;
/// kept as an extension to match the per-feature `+API.swift` convention
/// used by `SessionDatabase+TokenEventAPI`, `+CommandAPI`, etc.
extension SessionDatabase {

    /// Record one canonical trace row. Idempotent on `idempotencyKey` —
    /// a retry with the same key dedups in the DB. Returns `true` if the
    /// row was inserted, `false` if it was a duplicate.
    @discardableResult
    public func recordAgentTraceEvent(_ row: AgentTraceEvent) -> Bool {
        return agentTraceEventStore.record(row)
    }

    /// Total count of canonical trace rows. For tests + diagnostics.
    public func agentTraceEventCount() -> Int {
        return agentTraceEventStore.countAll()
    }

    /// Pivot 1 — per-project rollup (count, total cost, total tokens, mean latency).
    public func agentTracePivotByProject(since: Date? = nil) -> [AgentTraceProjectRollup] {
        return agentTraceEventStore.pivotByProject(since: since)
    }

    /// Pivot 2 — per-feature rollup with success/failure split.
    public func agentTracePivotByFeature(since: Date? = nil) -> [AgentTraceFeatureRollup] {
        return agentTraceEventStore.pivotByFeature(since: since)
    }

    /// Pivot 3 — per-result distribution (top-line "what's failing").
    public func agentTracePivotByResult(since: Date? = nil) -> [AgentTraceResultRollup] {
        return agentTraceEventStore.pivotByResult(since: since)
    }
}
