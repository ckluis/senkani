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

/// Phase U.6c — one plan paired with its (possibly absent) actual.
/// `actualCostCents == nil` means the plan was rejected by `BudgetGate`
/// or the executing closure threw before persistence. The variance
/// histogram in `AnalyticsView` plots `residual = actual − planned` for
/// the executed subset and surfaces the unpaired count separately.
public struct PlanActualPair: Sendable, Equatable, Identifiable {
    public let planId: String
    public let sessionId: String
    public let plannedFanout: Int
    public let leafSize: Int
    public let reducerChoice: ReducerChoice
    /// In the same units as `agent_trace_event.cost_cents`.
    public let plannedCost: Int
    /// nil when no matching `agent_trace_event` exists.
    public let actualCostCents: Int?
    public let createdAt: Date

    public var id: String { planId }

    /// `actualCostCents - plannedCost` when both are present. Negative =
    /// under-budget, positive = over-budget, zero = exact.
    public var residualCents: Int? {
        guard let actual = actualCostCents else { return nil }
        return actual - plannedCost
    }

    /// True iff the plan has a matching trace row (executed branch).
    public var isPaired: Bool { actualCostCents != nil }

    public init(
        planId: String,
        sessionId: String,
        plannedFanout: Int,
        leafSize: Int,
        reducerChoice: ReducerChoice,
        plannedCost: Int,
        actualCostCents: Int?,
        createdAt: Date
    ) {
        self.planId = planId
        self.sessionId = sessionId
        self.plannedFanout = plannedFanout
        self.leafSize = leafSize
        self.reducerChoice = reducerChoice
        self.plannedCost = plannedCost
        self.actualCostCents = actualCostCents
        self.createdAt = createdAt
    }
}

// MARK: - Variance histogram (Phase U.6c)

/// One bin of the planned-vs-actual variance histogram. Residuals are
/// in cents; the bin range is half-open `[lower, upper)` and the labels
/// follow the same convention. `kind` lets the chart paint under-budget,
/// exact, and over-budget bins distinct (Munzner: position-on-common-scale
/// + colour as redundant encoding for sign).
public struct VarianceHistogramBin: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case under, exact, over }
    public let index: Int
    public let label: String
    public let count: Int
    public let kind: Kind
    public var id: Int { index }

    public init(index: Int, label: String, count: Int, kind: Kind) {
        self.index = index
        self.label = label
        self.count = count
        self.kind = kind
    }
}

/// Pure histogram + median helpers for the U.6c variance chart and its
/// corpus eval. Lives in Core (not in the App view) so the autonomous-
/// loop test target can pin the bin shape without dragging in SwiftUI.
public enum VarianceHistogram {
    /// Fixed signed bins (in cents). Edges are chosen for the corpus's
    /// typical residual range; cents outside the outer edges fall into
    /// the open-ended `<` / `≥` end bins so the histogram never silently
    /// drops a row.
    public static let binEdges: [Int] = [-100, -50, -10, 0, 10, 50, 100]

    /// Bin paired plans by `residualCents`. Unpaired plans (no trace) are
    /// excluded — they are surfaced separately in the chart header.
    public static func bins(pairs: [PlanActualPair]) -> [VarianceHistogramBin] {
        let residuals = pairs.compactMap { $0.residualCents }
        var counts: [Int] = Array(repeating: 0, count: binEdges.count + 1)
        for r in residuals {
            counts[indexForResidual(r)] += 1
        }
        return zip(counts.indices, counts).map { (i, count) in
            VarianceHistogramBin(
                index: i,
                label: labelForBin(at: i),
                count: count,
                kind: kindForBin(at: i)
            )
        }
    }

    /// Median of an Int collection. Empty collection → 0; even count
    /// returns the lower-middle (no average — keeps result Int).
    public static func median(of values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func indexForResidual(_ r: Int) -> Int {
        for (i, edge) in binEdges.enumerated() {
            if r < edge { return i }
        }
        return binEdges.count
    }

    private static func labelForBin(at i: Int) -> String {
        let edges = binEdges
        if i == 0 { return "< \(edges.first!)¢" }
        if i == edges.count { return "≥ \(edges.last!)¢" }
        return "\(edges[i - 1])…\(edges[i])"
    }

    private static func kindForBin(at i: Int) -> VarianceHistogramBin.Kind {
        let edges = binEdges
        if i == 0 { return .under }
        if i == edges.count { return .over }
        let lower = edges[i - 1]
        let upper = edges[i]
        if upper <= 0 { return .under }
        if lower > 0 { return .over }
        return .exact
    }
}
