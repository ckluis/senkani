import Foundation

/// One planned context-orchestration shape, written by a combinator
/// (`split` / `filter` / `reduce`) at plan time so the matching
/// `agent_trace_event` row can be paired with its plan via `plan_id`.
///
/// Phase U.6a — pure-Swift schema slice. The combinator API + BudgetGate
/// rejection path land in U.6b; the variance histogram + corpus eval
/// land in U.6c. See `spec/inspirations/prompt-orchestration/lambda-rlm.md`.
///
/// `id` is a UUID string so the FK on `agent_trace_event.plan_id` is a
/// portable TEXT column (same convention as `sandboxed_results.id`). The
/// FK is declared via `REFERENCES context_plans(id)` for documented
/// intent — SQLite `PRAGMA foreign_keys` is left at its default (off) to
/// match the rest of the schema; tampering is detectable downstream.
public struct ContextPlan: Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionId: String
    public let plannedFanout: Int
    public let leafSize: Int
    public let reducerChoice: ReducerChoice
    public let estimatedCost: Int
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        plannedFanout: Int,
        leafSize: Int,
        reducerChoice: ReducerChoice,
        estimatedCost: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.plannedFanout = plannedFanout
        self.leafSize = leafSize
        self.reducerChoice = reducerChoice
        self.estimatedCost = estimatedCost
        self.createdAt = createdAt
    }
}

/// Reducer the combinator will apply over the leaves it produces. The
/// vocabulary is closed at U.6a (extending it requires a migration only
/// if a new ReducerChoice case ships persisted); U.6b's `split` /
/// `filter` / `reduce` operators each map to one of these.
public enum ReducerChoice: String, Sendable, Equatable, Codable, CaseIterable {
    /// Concatenate / sum / pick-last over leaves. Default for `split`.
    case merge
    /// LLM-summarize the leaves into a single condensed payload.
    case summarize
    /// Pick exactly one leaf out of N (e.g. best-of-N filter).
    case select
}
