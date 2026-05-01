import Testing
import Foundation
@testable import Core

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-tierdist-test-\(UUID().uuidString).sqlite"
    return (SessionDatabase(path: path), path)
}

private func cleanupTempDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func makeRow(
    key: String = UUID().uuidString,
    tier: String? = nil,
    ladderPosition: Int? = nil,
    startedAt: Date = Date()
) -> AgentTraceEvent {
    AgentTraceEvent(
        idempotencyKey: key,
        pane: "kb", project: "/tmp/p", model: "claude-haiku-4-5",
        tier: tier, ladderPosition: ladderPosition, feature: "search",
        result: "success",
        startedAt: startedAt, completedAt: startedAt.addingTimeInterval(0.1),
        latencyMs: 25, tokensIn: 80, tokensOut: 30, costCents: 1
    )
}

@Suite("U.1c — Tier-distribution chart store API")
struct TierDistributionTests {

    @Test("Distribution counts rows per tier within window")
    func distributionByTier() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        let now = Date()

        db.recordAgentTraceEvent(makeRow(key: "a1", tier: "simple", ladderPosition: 0, startedAt: now))
        db.recordAgentTraceEvent(makeRow(key: "a2", tier: "simple", ladderPosition: 0, startedAt: now))
        db.recordAgentTraceEvent(makeRow(key: "a3", tier: "complex", ladderPosition: 0, startedAt: now))
        db.recordAgentTraceEvent(makeRow(key: "a4", tier: "reasoning", ladderPosition: 0, startedAt: now))

        let buckets = db.agentTraceTierDistribution(since: now.addingTimeInterval(-3600))
        let totals = Dictionary(grouping: buckets, by: \.tier).mapValues { $0.reduce(0) { $0 + $1.count } }

        #expect(totals["simple"] == 2)
        #expect(totals["complex"] == 1)
        #expect(totals["reasoning"] == 1)
        #expect(totals["standard"] == nil)
    }

    @Test("Distribution splits buckets by ladder position when present")
    func distributionByLadderPosition() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        let now = Date()

        db.recordAgentTraceEvent(makeRow(key: "b1", tier: "standard", ladderPosition: 0, startedAt: now))
        db.recordAgentTraceEvent(makeRow(key: "b2", tier: "standard", ladderPosition: 0, startedAt: now))
        db.recordAgentTraceEvent(makeRow(key: "b3", tier: "standard", ladderPosition: 1, startedAt: now))

        let buckets = db.agentTraceTierDistribution(since: now.addingTimeInterval(-3600))
            .filter { $0.tier == "standard" }
            .sorted { ($0.ladderPosition ?? -1) < ($1.ladderPosition ?? -1) }

        #expect(buckets.count == 2)
        #expect(buckets[0].ladderPosition == 0)
        #expect(buckets[0].count == 2)
        #expect(buckets[1].ladderPosition == 1)
        #expect(buckets[1].count == 1)
    }

    @Test("Distribution excludes rows whose tier is NULL")
    func distributionExcludesNullTier() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        let now = Date()

        db.recordAgentTraceEvent(makeRow(key: "n1", tier: nil, startedAt: now))
        db.recordAgentTraceEvent(makeRow(key: "n2", tier: nil, startedAt: now))
        db.recordAgentTraceEvent(makeRow(key: "n3", tier: "simple", ladderPosition: 0, startedAt: now))

        let buckets = db.agentTraceTierDistribution(since: now.addingTimeInterval(-3600))
        #expect(buckets.count == 1)
        #expect(buckets.first?.tier == "simple")
    }

    @Test("Empty state — no rows in window returns empty bucket list")
    func emptyWindow() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        let now = Date()

        // A row well outside the window should not appear.
        db.recordAgentTraceEvent(makeRow(
            key: "old", tier: "simple", ladderPosition: 0,
            startedAt: now.addingTimeInterval(-30 * 86400)
        ))

        let buckets = db.agentTraceTierDistribution(since: now.addingTimeInterval(-86400))
        #expect(buckets.isEmpty)
    }

    @Test("Distribution honors `since` cutoff")
    func sinceCutoff() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        let now = Date()

        db.recordAgentTraceEvent(makeRow(
            key: "fresh", tier: "complex", ladderPosition: 0, startedAt: now
        ))
        db.recordAgentTraceEvent(makeRow(
            key: "stale", tier: "complex", ladderPosition: 0,
            startedAt: now.addingTimeInterval(-10 * 86400)
        ))

        let day = db.agentTraceTierDistribution(since: now.addingTimeInterval(-86400))
        let week = db.agentTraceTierDistribution(since: now.addingTimeInterval(-7 * 86400))
        let month = db.agentTraceTierDistribution(since: now.addingTimeInterval(-30 * 86400))

        #expect(day.reduce(0) { $0 + $1.count } == 1)
        #expect(week.reduce(0) { $0 + $1.count } == 1)
        #expect(month.reduce(0) { $0 + $1.count } == 2)
    }

    @Test("Drill-down returns the matching tier rows in DESC order, capped by limit")
    func drillDownLimit() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        let base = Date()

        for i in 0..<5 {
            db.recordAgentTraceEvent(makeRow(
                key: "r\(i)", tier: "complex", ladderPosition: i % 2,
                startedAt: base.addingTimeInterval(Double(i))
            ))
        }
        // Off-tier control row that must NOT appear.
        db.recordAgentTraceEvent(makeRow(
            key: "off", tier: "simple", ladderPosition: 0, startedAt: base
        ))

        let rows = db.agentTraceRowsForTier("complex", since: base.addingTimeInterval(-60), limit: 3)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.tier == "complex" })
        // DESC by startedAt → newest (i=4) first.
        #expect(rows.first?.idempotencyKey == "r4")
    }
}
