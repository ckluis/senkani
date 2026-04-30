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

    /// Read back the full canonical trace row for an idempotency key.
    /// Round-trips every field including U.6a's `planId`. Returns nil
    /// if no row matches.
    public func agentTraceEvent(idempotencyKey: String) -> AgentTraceEvent? {
        return agentTraceEventStore.fetchByIdempotencyKey(idempotencyKey)
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

    /// W.4 — token usage in a pane / project / time window. Sums
    /// `tokens_in + tokens_out` across matching trace rows. The
    /// `ContextSaturationGate` divides this by the configured budget to
    /// derive a saturation percent.
    public func agentTraceTokenUsage(pane: String? = nil, project: String? = nil, since: Date? = nil) -> AgentTraceTokenUsage {
        return agentTraceEventStore.tokenUsage(pane: pane, project: project, since: since)
    }

    /// W.4 — most-recent N idempotency keys for a pane / project window.
    /// Used by the PreCompactHandoffWriter to record the trace tail in
    /// the handoff card so the next session can resume diagnostics.
    public func agentTraceRecentKeys(pane: String? = nil, project: String? = nil, limit: Int = 10) -> [String] {
        return agentTraceEventStore.recentTraceKeys(pane: pane, project: project, limit: limit)
    }

    /// U.1c — per-tier (and per-ladder-position) row counts since `since`.
    /// Powers the AnalyticsView tier-distribution chart. Rows with NULL
    /// `tier` are excluded; the chart renders an empty state when nothing
    /// returns.
    public func agentTraceTierDistribution(since: Date) -> [AgentTraceTierBucket] {
        return agentTraceEventStore.tierDistribution(since: since)
    }

    /// U.1c — drill-down rows for one tier within a window, capped at
    /// `limit`. Used by the chart's click-to-inspect sheet.
    public func agentTraceRowsForTier(_ tier: String, since: Date, limit: Int = 200) -> [AgentTraceTierRow] {
        return agentTraceEventStore.tracesForTier(tier, since: since, limit: limit)
    }
}
