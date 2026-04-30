import Foundation

// MARK: - PlanRejection

/// Structured deny returned by `CombinatorPipeline` when `BudgetGate`
/// rules a plan's `estimatedCost` over the active `BudgetConfig`
/// daily-equivalent ceiling. Routine outcome — surfaced as a value, not
/// thrown. The plan row is still persisted so analytics can pivot on
/// rejected plans separately from executed plans.
public struct PlanRejection: Sendable, Equatable, Error {
    public let reason: String
    public let ceilingCents: Int
    public let estimatedCost: Int
    public let planId: String

    public init(reason: String, ceilingCents: Int, estimatedCost: Int, planId: String) {
        self.reason = reason
        self.ceilingCents = ceilingCents
        self.estimatedCost = estimatedCost
        self.planId = planId
    }
}

// MARK: - CombinatorOutcome

/// Result of one `CombinatorPipeline` operator call. `executed` carries
/// both the persisted `ContextPlan` and the matching `AgentTraceEvent`
/// (with `planId` already stamped). `rejected` carries the persisted
/// plan + the rejection reason; no trace was written.
///
/// Either way the plan row exists in `context_plans` — the absence or
/// presence of a paired `agent_trace_event` is the on-disk signal.
public enum CombinatorOutcome: Sendable, Equatable {
    case executed(plan: ContextPlan, trace: AgentTraceEvent)
    case rejected(plan: ContextPlan, rejection: PlanRejection)

    public var plan: ContextPlan {
        switch self {
        case .executed(let plan, _): return plan
        case .rejected(let plan, _): return plan
        }
    }
}

// MARK: - CombinatorPipeline

/// Phase U.6b — pairs a planned `ContextPlan` row with its matching
/// `agent_trace_event` actual via `plan_id`. Three named operators
/// (`split` / `filter` / `reduce`) map to the three `ReducerChoice`
/// cases. Each call:
///
///   1. builds + persists a `ContextPlan` row (always — even on reject).
///   2. asks `BudgetGate.rejectPlan` whether the plan fits the budget.
///      If not: returns `.rejected` with the reason; no trace written.
///   3. otherwise runs the caller's `execute` closure, stamps `planId`
///      onto the returned `AgentTraceEvent`, persists it, and returns
///      `.executed`.
///
/// The closure may throw a real error — in that case the plan stays
/// persisted (no trace written) and the throw propagates. This matches
/// the reality of mid-execution crashes; analytics in u6c filters
/// `plan_id IS NOT NULL` for the pairing percentage.
///
/// Caller surface: thin enough to wire from future `OptimizationPipeline`
/// callers without changing their signatures — the closure receives the
/// fresh `ContextPlan` so it can build the matching trace however it
/// wants. `withPlanId` stamps the id so callers can't accidentally drop
/// the pairing.
///
/// Reference: `spec/inspirations/prompt-orchestration/lambda-rlm.md`.
public struct CombinatorPipeline: Sendable {
    private let database: SessionDatabase
    private let budget: BudgetConfig
    private let clock: @Sendable () -> Date

    public init(
        database: SessionDatabase,
        budget: BudgetConfig = BudgetConfig.load(),
        clock: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.database = database
        self.budget = budget
        self.clock = clock
    }

    /// Default `split` — fan a context out into N leaves and merge.
    /// `ReducerChoice.merge`.
    public func split(
        sessionId: String,
        plannedFanout: Int,
        leafSize: Int,
        estimatedCost: Int,
        execute: (ContextPlan) throws -> AgentTraceEvent
    ) throws -> CombinatorOutcome {
        try run(
            reducer: .merge,
            sessionId: sessionId,
            plannedFanout: plannedFanout,
            leafSize: leafSize,
            estimatedCost: estimatedCost,
            execute: execute
        )
    }

    /// `filter` — fan out into N candidates and pick exactly one.
    /// `ReducerChoice.select`.
    public func filter(
        sessionId: String,
        plannedFanout: Int,
        leafSize: Int,
        estimatedCost: Int,
        execute: (ContextPlan) throws -> AgentTraceEvent
    ) throws -> CombinatorOutcome {
        try run(
            reducer: .select,
            sessionId: sessionId,
            plannedFanout: plannedFanout,
            leafSize: leafSize,
            estimatedCost: estimatedCost,
            execute: execute
        )
    }

    /// `reduce` — fan out into N leaves and LLM-summarize the result.
    /// `ReducerChoice.summarize`.
    public func reduce(
        sessionId: String,
        plannedFanout: Int,
        leafSize: Int,
        estimatedCost: Int,
        execute: (ContextPlan) throws -> AgentTraceEvent
    ) throws -> CombinatorOutcome {
        try run(
            reducer: .summarize,
            sessionId: sessionId,
            plannedFanout: plannedFanout,
            leafSize: leafSize,
            estimatedCost: estimatedCost,
            execute: execute
        )
    }

    // MARK: - Shared path

    private func run(
        reducer: ReducerChoice,
        sessionId: String,
        plannedFanout: Int,
        leafSize: Int,
        estimatedCost: Int,
        execute: (ContextPlan) throws -> AgentTraceEvent
    ) throws -> CombinatorOutcome {
        let plan = ContextPlan(
            sessionId: sessionId,
            plannedFanout: plannedFanout,
            leafSize: leafSize,
            reducerChoice: reducer,
            estimatedCost: estimatedCost,
            createdAt: clock()
        )
        database.recordContextPlan(plan)

        if let rejection = BudgetGate.rejectPlan(
            estimatedCost: estimatedCost,
            budget: budget,
            planId: plan.id
        ) {
            return .rejected(plan: plan, rejection: rejection)
        }

        let event = try execute(plan)
        let stamped = event.withPlanId(plan.id)
        database.recordAgentTraceEvent(stamped)
        return .executed(plan: plan, trace: stamped)
    }
}

// MARK: - AgentTraceEvent.withPlanId

extension AgentTraceEvent {
    /// Return a copy with `planId` set. Used by `CombinatorPipeline` to
    /// stamp the plan id on the closure's returned trace so callers
    /// can't accidentally drop the pairing.
    public func withPlanId(_ planId: String) -> AgentTraceEvent {
        return AgentTraceEvent(
            idempotencyKey: idempotencyKey,
            pane: pane,
            project: project,
            model: model,
            tier: tier,
            ladderPosition: ladderPosition,
            feature: feature,
            result: result,
            startedAt: startedAt,
            completedAt: completedAt,
            latencyMs: latencyMs,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            costCents: costCents,
            redactionCount: redactionCount,
            validationStatus: validationStatus,
            confirmationRequired: confirmationRequired,
            egressDecisions: egressDecisions,
            planId: planId
        )
    }
}
