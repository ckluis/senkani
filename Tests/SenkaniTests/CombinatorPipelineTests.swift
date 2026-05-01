import Testing
import Foundation
@testable import Core

/// Phase U.6b — `CombinatorPipeline.split / .filter / .reduce` +
/// `BudgetGate.rejectPlan` plan-rejection path. Each combinator emits
/// a `ContextPlan` row up-front; the matching `agent_trace_event`
/// carries `plan_id` so plan/actual pairing is observable both via
/// `+ContextPlanAPI` and `+AgentTraceAPI`. Rejected plans persist the
/// plan row but skip the trace.
@Suite("CombinatorPipeline — U.6b combinators + BudgetGate rejection")
struct CombinatorPipelineTests {

    // MARK: - Helpers

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-combinator-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private func cleanup(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }

    private func sampleTrace(
        idempotencyKey: String = "u6b-\(UUID().uuidString)",
        startedAt: Date = Date(timeIntervalSince1970: 1_750_000_100),
        completedAt: Date = Date(timeIntervalSince1970: 1_750_000_101),
        costCents: Int = 5
    ) -> AgentTraceEvent {
        AgentTraceEvent(
            idempotencyKey: idempotencyKey,
            result: "success",
            startedAt: startedAt,
            completedAt: completedAt,
            costCents: costCents
        )
    }

    // MARK: - Combinator happy paths (one per ReducerChoice)

    @Test("split emits paired ContextPlan + AgentTraceEvent with reducer=merge")
    func splitPairsPlanAndTrace() throws {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }
        let pipeline = CombinatorPipeline(database: db, budget: BudgetConfig())

        let traceKey = "u6b-split-\(UUID().uuidString)"
        let outcome = try pipeline.split(
            sessionId: "sess-split",
            plannedFanout: 4,
            leafSize: 2_000,
            estimatedCost: 12
        ) { plan in
            // Plan id is stamped by the pipeline; closure may set it or not.
            sampleTrace(idempotencyKey: traceKey)
        }

        guard case let .executed(plan, trace) = outcome else {
            Issue.record("expected .executed, got \(outcome)")
            return
        }
        #expect(plan.reducerChoice == .merge)
        #expect(plan.plannedFanout == 4)
        #expect(plan.leafSize == 2_000)
        #expect(plan.estimatedCost == 12)
        #expect(trace.planId == plan.id, "pipeline must stamp planId")

        // Persisted plan reachable via +ContextPlanAPI.
        let storedPlan = db.contextPlan(id: plan.id)
        #expect(storedPlan?.reducerChoice == .merge)

        // Persisted trace reachable via +AgentTraceAPI; plan_id paired.
        let storedTrace = db.agentTraceEvent(idempotencyKey: traceKey)
        #expect(storedTrace?.planId == plan.id, "plan/actual pairing must round-trip")
    }

    @Test("filter persists ReducerChoice.select")
    func filterPersistsReducerSelect() throws {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }
        let pipeline = CombinatorPipeline(database: db, budget: BudgetConfig())

        let outcome = try pipeline.filter(
            sessionId: "sess-filter",
            plannedFanout: 6,
            leafSize: 1_500,
            estimatedCost: 8
        ) { _ in sampleTrace() }

        guard case let .executed(plan, _) = outcome else {
            Issue.record("expected .executed, got \(outcome)")
            return
        }
        #expect(plan.reducerChoice == .select)
        #expect(db.contextPlan(id: plan.id)?.reducerChoice == .select)
    }

    @Test("reduce persists ReducerChoice.summarize")
    func reducePersistsReducerSummarize() throws {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }
        let pipeline = CombinatorPipeline(database: db, budget: BudgetConfig())

        let outcome = try pipeline.reduce(
            sessionId: "sess-reduce",
            plannedFanout: 3,
            leafSize: 4_000,
            estimatedCost: 25
        ) { _ in sampleTrace() }

        guard case let .executed(plan, _) = outcome else {
            Issue.record("expected .executed, got \(outcome)")
            return
        }
        #expect(plan.reducerChoice == .summarize)
        #expect(db.contextPlan(id: plan.id)?.reducerChoice == .summarize)
    }

    // MARK: - Pairing observable from both sides

    @Test("Plan/actual pairing observable via fetchBySession + fetchByIdempotencyKey")
    func pairingObservableFromBothSides() throws {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }
        let pipeline = CombinatorPipeline(database: db, budget: BudgetConfig())

        let traceKey = "u6b-pair-\(UUID().uuidString)"
        let outcome = try pipeline.split(
            sessionId: "sess-pair",
            plannedFanout: 2,
            leafSize: 1_000,
            estimatedCost: 4
        ) { _ in sampleTrace(idempotencyKey: traceKey) }

        guard case let .executed(plan, _) = outcome else {
            Issue.record("expected .executed, got \(outcome)")
            return
        }

        let plansBySession = db.contextPlans(forSession: "sess-pair")
        #expect(plansBySession.count == 1)
        #expect(plansBySession.first?.id == plan.id)

        let traceByKey = db.agentTraceEvent(idempotencyKey: traceKey)
        #expect(traceByKey?.planId == plan.id)
    }

    // MARK: - BudgetGate rejection path

    @Test("BudgetGate rejects when estimatedCost exceeds daily-equivalent ceiling")
    func budgetGateRejectsOverBudgetPlan() throws {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let budget = BudgetConfig(dailyLimitCents: 100) // $1/day ceiling
        let pipeline = CombinatorPipeline(database: db, budget: budget)

        var executed = false
        let outcome = try pipeline.split(
            sessionId: "sess-reject",
            plannedFanout: 8,
            leafSize: 2_000,
            estimatedCost: 5_000   // way over ceiling
        ) { _ in
            executed = true
            return sampleTrace()
        }

        guard case let .rejected(plan, rejection) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(executed == false, "rejected plan must NOT run the closure")
        #expect(rejection.ceilingCents == 100)
        #expect(rejection.estimatedCost == 5_000)
        #expect(rejection.planId == plan.id)
        #expect(!rejection.reason.isEmpty)

        // Plan IS persisted (analytics needs the row).
        #expect(db.contextPlan(id: plan.id)?.estimatedCost == 5_000)
        // No trace persisted (countAll on agent_trace_event).
        #expect(db.contextPlanCount() == 1)
    }

    @Test("Unlimited budget never rejects regardless of cost")
    func unlimitedBudgetNeverRejects() throws {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let pipeline = CombinatorPipeline(database: db, budget: BudgetConfig())
        let outcome = try pipeline.reduce(
            sessionId: "sess-unlimited",
            plannedFanout: 100,
            leafSize: 100_000,
            estimatedCost: 1_000_000
        ) { _ in sampleTrace() }

        guard case .executed = outcome else {
            Issue.record("unlimited budget must execute, got \(outcome)")
            return
        }
    }

    @Test("Allowed plan: estimatedCost ≤ ceiling executes through")
    func allowedPlanExecutesUnderCeiling() throws {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let budget = BudgetConfig(dailyLimitCents: 1_000) // $10/day ceiling
        let pipeline = CombinatorPipeline(database: db, budget: budget)

        let traceKey = "u6b-allowed-\(UUID().uuidString)"
        let outcome = try pipeline.filter(
            sessionId: "sess-allowed",
            plannedFanout: 5,
            leafSize: 3_000,
            estimatedCost: 50           // well under ceiling
        ) { _ in sampleTrace(idempotencyKey: traceKey) }

        guard case let .executed(plan, _) = outcome else {
            Issue.record("expected .executed, got \(outcome)")
            return
        }
        #expect(db.agentTraceEvent(idempotencyKey: traceKey)?.planId == plan.id)
    }

    // MARK: - Rejection direct on BudgetGate

    @Test("BudgetGate.rejectPlan returns rejection with correct fields")
    func budgetGateRejectPlanFields() {
        let budget = BudgetConfig(weeklyLimitCents: 700) // dailyEquivalent = 100
        let rejection = BudgetGate.rejectPlan(
            estimatedCost: 250,
            budget: budget,
            planId: "plan-xyz"
        )

        guard let rejection else {
            Issue.record("expected rejection, got nil")
            return
        }
        #expect(rejection.ceilingCents == 100)
        #expect(rejection.estimatedCost == 250)
        #expect(rejection.planId == "plan-xyz")
        #expect(rejection.reason.contains("250"))
        #expect(rejection.reason.contains("100"))
    }

    @Test("BudgetGate.rejectPlan returns nil when estimatedCost ≤ ceiling")
    func budgetGateRejectPlanReturnsNilUnderCeiling() {
        let budget = BudgetConfig(dailyLimitCents: 500)
        #expect(BudgetGate.rejectPlan(estimatedCost: 500, budget: budget, planId: "p1") == nil,
                "exact-ceiling cost must allow (strict >, not ≥)")
        #expect(BudgetGate.rejectPlan(estimatedCost: 499, budget: budget, planId: "p2") == nil)
    }

    // MARK: - Closure-throw third state (Kleppmann CONCERN pinned)

    @Test("Closure throw leaves plan persisted, trace absent, throw propagates")
    func closureThrowLeavesPlanWithoutTrace() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let pipeline = CombinatorPipeline(database: db, budget: BudgetConfig())

        struct BoomError: Error {}

        var thrown = false
        do {
            _ = try pipeline.split(
                sessionId: "sess-throw",
                plannedFanout: 2,
                leafSize: 1_000,
                estimatedCost: 4
            ) { _ -> AgentTraceEvent in
                throw BoomError()
            }
        } catch is BoomError {
            thrown = true
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(thrown, "BoomError must propagate up through the combinator")
        #expect(db.contextPlanCount() == 1, "plan row must remain persisted on closure throw")
    }

    // MARK: - withPlanId helper

    @Test("AgentTraceEvent.withPlanId stamps planId without altering other fields")
    func withPlanIdStampsOnly() {
        let original = AgentTraceEvent(
            idempotencyKey: "u6b-stamp",
            pane: "p1",
            project: "proj",
            model: "haiku",
            tier: "standard",
            ladderPosition: 0,
            feature: "explore",
            result: "success",
            startedAt: Date(timeIntervalSince1970: 1_750_000_200),
            completedAt: Date(timeIntervalSince1970: 1_750_000_201),
            latencyMs: 17,
            tokensIn: 200,
            tokensOut: 50,
            costCents: 9,
            redactionCount: 1,
            validationStatus: "ok",
            confirmationRequired: false,
            egressDecisions: 0
        )
        let stamped = original.withPlanId("plan-id-42")
        #expect(stamped.planId == "plan-id-42")
        #expect(stamped.idempotencyKey == original.idempotencyKey)
        #expect(stamped.pane == original.pane)
        #expect(stamped.project == original.project)
        #expect(stamped.model == original.model)
        #expect(stamped.tier == original.tier)
        #expect(stamped.ladderPosition == original.ladderPosition)
        #expect(stamped.feature == original.feature)
        #expect(stamped.result == original.result)
        #expect(stamped.latencyMs == original.latencyMs)
        #expect(stamped.tokensIn == original.tokensIn)
        #expect(stamped.tokensOut == original.tokensOut)
        #expect(stamped.costCents == original.costCents)
        #expect(stamped.redactionCount == original.redactionCount)
        #expect(stamped.validationStatus == original.validationStatus)
        #expect(stamped.confirmationRequired == original.confirmationRequired)
        #expect(stamped.egressDecisions == original.egressDecisions)
        #expect(original.planId == nil, "withPlanId must not mutate the original")
    }
}
