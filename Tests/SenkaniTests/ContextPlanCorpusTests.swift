import Testing
import Foundation
@testable import Core

// MARK: - Corpus loader

private struct CorpusMeta: Codable, Sendable {
    let phase: String
    let purpose: String
    let ceiling_dollars_daily: Int?
    let gate: String?
}

private struct CorpusItem: Codable, Sendable, Equatable {
    let id: String
    let `operator`: String
    let planned_fanout: Int
    let leaf_size: Int
    let estimated_cost: Int
    let actual_cost: Int
    let should_execute: Bool
    let `throws`: Bool
}

private struct Corpus: Codable, Sendable {
    let _meta: CorpusMeta
    let items: [CorpusItem]
}

private func loadCorpus() -> Corpus? {
    guard let url = Bundle.module.url(forResource: "context-plan-corpus", withExtension: "json"),
          let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Corpus.self, from: data)
}

// MARK: - Driver

private struct DriverError: Error {}

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-u6c-corpus-\(UUID().uuidString).sqlite"
    return (SessionDatabase(path: path), path)
}

private func cleanup(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func makeTrace(idempotencyKey: String, costCents: Int) -> AgentTraceEvent {
    AgentTraceEvent(
        idempotencyKey: idempotencyKey,
        result: "success",
        startedAt: Date(timeIntervalSince1970: 1_750_000_000),
        completedAt: Date(timeIntervalSince1970: 1_750_000_001),
        costCents: costCents
    )
}

@discardableResult
private func runItem(
    _ item: CorpusItem,
    pipeline: CombinatorPipeline
) throws -> CombinatorOutcome? {
    let traceKey = "u6c-corpus-\(item.id)"
    let exec: (ContextPlan) throws -> AgentTraceEvent = { _ in
        if item.throws { throw DriverError() }
        return makeTrace(idempotencyKey: traceKey, costCents: item.actual_cost)
    }
    do {
        switch item.`operator` {
        case "split":
            return try pipeline.split(
                sessionId: "corpus",
                plannedFanout: item.planned_fanout,
                leafSize: item.leaf_size,
                estimatedCost: item.estimated_cost,
                execute: exec
            )
        case "filter":
            return try pipeline.filter(
                sessionId: "corpus",
                plannedFanout: item.planned_fanout,
                leafSize: item.leaf_size,
                estimatedCost: item.estimated_cost,
                execute: exec
            )
        case "reduce":
            return try pipeline.reduce(
                sessionId: "corpus",
                plannedFanout: item.planned_fanout,
                leafSize: item.leaf_size,
                estimatedCost: item.estimated_cost,
                execute: exec
            )
        default:
            Issue.record("Unknown operator '\(item.`operator`)' in corpus item \(item.id)")
            return nil
        }
    } catch is DriverError {
        // Expected for items declaring throws: true. Plan persists, no trace.
        return nil
    }
}

// MARK: - Corpus tests

@Suite("ContextPlanCorpus — U.6c pairing eval (≥ 90 % of corpus operations paired)")
struct ContextPlanCorpusTests {

    @Test("Corpus loads with at least 15 items")
    func corpusLoads() throws {
        let corpus = try #require(loadCorpus(),
                                  "context-plan-corpus.json must be bundled with the test target")
        #expect(corpus.items.count >= 15,
                "Corpus needs ≥ 15 items to exercise split / filter / reduce paths")
    }

    @Test("Corpus exercises every ReducerChoice path")
    func corpusCoversEveryReducer() throws {
        let corpus = try #require(loadCorpus())
        let ops = Set(corpus.items.map { $0.`operator` })
        #expect(ops.contains("split"))
        #expect(ops.contains("filter"))
        #expect(ops.contains("reduce"))
    }

    /// The parent acceptance metric: ≥ 90 % of corpus operations have
    /// a paired plan + actual after a synthetic run. The denominator is
    /// the count of items declared `should_execute: true && throws: false`
    /// — those are the items expected to land both sides. Rejected items
    /// and explicit throws are tracked separately so a regression in
    /// either path can't silently inflate the headline number.
    @Test("≥ 90 % of executable corpus operations land paired plan + trace rows")
    func pairingEvalGate() throws {
        let corpus = try #require(loadCorpus())
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        // Daily ceiling per fixture meta — keeps rejected items
        // observably rejected (estimated_cost > ceiling_cents) and
        // executable items observably under (estimated_cost ≤ ceiling).
        let ceilingDollars = corpus._meta.ceiling_dollars_daily ?? 50
        let budget = BudgetConfig(dailyLimitCents: ceilingDollars * 100)
        let pipeline = CombinatorPipeline(database: db, budget: budget)

        for item in corpus.items {
            try runItem(item, pipeline: pipeline)
        }

        // Pull pairs and partition.
        let pairs = db.contextPlanPairs(since: Date.distantPast)
        let executableExpected = corpus.items.filter { $0.should_execute && !$0.`throws` }

        let pairedExecutable = pairs.filter { pair in
            pair.isPaired
        }

        let denom = executableExpected.count
        #expect(denom > 0, "Corpus must have at least one executable item")
        let paired = pairedExecutable.count
        let fraction = Double(paired) / Double(denom)
        #expect(fraction >= 0.90,
                "Pairing fraction \(String(format: "%.2f", fraction)) below 0.90 gate (\(paired) / \(denom))")
    }

    @Test("Rejected corpus items land plan rows but no traces")
    func rejectedItemsPersistPlanWithoutTrace() throws {
        let corpus = try #require(loadCorpus())
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let ceilingDollars = corpus._meta.ceiling_dollars_daily ?? 50
        let budget = BudgetConfig(dailyLimitCents: ceilingDollars * 100)
        let pipeline = CombinatorPipeline(database: db, budget: budget)

        let rejectedItems = corpus.items.filter { !$0.should_execute }
        // Sanity — corpus must include at least one rejection so this
        // test isn't a no-op.
        try #require(!rejectedItems.isEmpty,
                     "Corpus must include at least one should_execute=false item")

        for item in rejectedItems {
            let outcome = try runItem(item, pipeline: pipeline)
            guard case .rejected(let plan, let rejection) = outcome else {
                Issue.record("Item \(item.id) expected rejection, got \(String(describing: outcome))")
                continue
            }
            #expect(rejection.estimatedCost == item.estimated_cost)
            #expect(plan.estimatedCost == item.estimated_cost)
        }

        let pairs = db.contextPlanPairs(since: Date.distantPast)
        for pair in pairs {
            // Every rejected pair should be unpaired (no trace).
            #expect(!pair.isPaired,
                    "Rejected plan \(pair.planId) unexpectedly has a trace row")
        }
        #expect(pairs.count == rejectedItems.count)
    }

    @Test("Closure-thrown corpus items leave plan persisted, trace absent")
    func throwingItemsPersistPlanOnly() throws {
        let corpus = try #require(loadCorpus())
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let pipeline = CombinatorPipeline(database: db, budget: BudgetConfig())
        let throwers = corpus.items.filter { $0.`throws` }
        try #require(!throwers.isEmpty,
                     "Corpus must include at least one throws=true item")

        for item in throwers {
            try runItem(item, pipeline: pipeline)
        }

        let pairs = db.contextPlanPairs(since: Date.distantPast)
        #expect(pairs.count == throwers.count)
        for pair in pairs {
            #expect(!pair.isPaired,
                    "Closure-thrown plan \(pair.planId) unexpectedly has a trace row")
        }
    }

    // MARK: - Histogram bin shape (Tufte / Munzner)

    @Test("VarianceHistogram.bins assigns under / exact / over correctly")
    func histogramBinsClassify() {
        let pairs: [PlanActualPair] = [
            mockPair(planned: 100, actual:  50),  // residual −50 → under
            mockPair(planned: 100, actual:  90),  // residual −10 → bin 3 [-10,0) under
            mockPair(planned: 100, actual: 100),  // residual   0 → bin 4 [0,10) exact
            mockPair(planned: 100, actual: 105),  // residual   5 → bin 4 exact
            mockPair(planned: 100, actual: 150),  // residual  50 → over
            mockPair(planned: 100, actual: 250),  // residual 150 → tail over
            mockPair(planned: 100, actual: nil),   // unpaired — must NOT count
        ]
        let bins = VarianceHistogram.bins(pairs: pairs)
        let totalCounted = bins.reduce(0) { $0 + $1.count }
        #expect(totalCounted == 6, "unpaired pairs must be excluded from the histogram")

        let exactCount = bins.filter { $0.kind == .exact }.reduce(0) { $0 + $1.count }
        #expect(exactCount == 2, "residuals 0 and 5 land in the exact bin")

        let underCount = bins.filter { $0.kind == .under }.reduce(0) { $0 + $1.count }
        #expect(underCount == 2, "residuals −50 and −10 land in under bins")

        let overCount = bins.filter { $0.kind == .over }.reduce(0) { $0 + $1.count }
        #expect(overCount == 2, "residuals 50 and 150 land in over bins")
    }

    @Test("VarianceHistogram.median follows Karpathy's signed definition")
    func medianResidualSigned() {
        let residuals = [-30, -10, 0, 5, 50] // sorted, n=5, median=0
        #expect(VarianceHistogram.median(of: residuals) == 0)
        let underHeavy = [-100, -80, -60, -40, -20]
        #expect(VarianceHistogram.median(of: underHeavy) == -60)
        let empty: [Int] = []
        #expect(VarianceHistogram.median(of: empty) == 0)
    }
}

// Local helper — mock paired (or unpaired) PlanActualPair for bin tests.
private func mockPair(planned: Int? = 100, actual: Int? = nil) -> PlanActualPair {
    PlanActualPair(
        planId: UUID().uuidString,
        sessionId: "test",
        plannedFanout: 1,
        leafSize: 100,
        reducerChoice: .merge,
        plannedCost: planned ?? 0,
        actualCostCents: actual,
        createdAt: Date(timeIntervalSince1970: 1_750_000_000)
    )
}
