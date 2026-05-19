import Foundation

/// Session DB façade for the eval-results audit log (Phase T.2b-1).
/// Mirrors `SessionDatabase+EgressAPI` shape — T.2b-2's PII-Masking-300k
/// harness writes via these methods.
extension SessionDatabase {

    /// Record one model-evaluation row. Best-effort: a SQLite write
    /// failure does not propagate — the harness must keep running
    /// even if the audit DB is offline. Returns `true` on a successful
    /// chained insert.
    @discardableResult
    public func recordEvalResult(
        modelId: String,
        fixtureId: String,
        precision: Double,
        recall: Double,
        f1: Double,
        durationMs: Int64
    ) -> Bool {
        evalResultsStore.record(
            modelId: modelId,
            fixtureId: fixtureId,
            precision: precision,
            recall: recall,
            f1: f1,
            durationMs: durationMs
        )
    }

    /// Most recent eval row for the given model id, or nil if none.
    public func latestEvalResult(modelId: String) -> EvalResultsStore.Row? {
        evalResultsStore.latest(modelId: modelId)
    }

    /// Most recent eval rows in descending id order.
    public func recentEvalResults(limit: Int = 100) -> [EvalResultsStore.Row] {
        evalResultsStore.recent(limit: limit)
    }

    /// Total eval row count.
    public func evalResultsCount() -> Int64 {
        evalResultsStore.count()
    }
}
