import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-dashboard-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func insertEvent(
    db: SessionDatabase,
    projectRoot: String,
    feature: String,
    inputTokens: Int = 100,
    savedTokens: Int = 50,
    costCents: Int = 1
) {
    let sid = db.createSession(projectRoot: projectRoot)
    db.recordTokenEvent(
        sessionId: sid, paneId: nil, projectRoot: projectRoot,
        source: "mcp_tool", toolName: "test", model: nil,
        inputTokens: inputTokens, outputTokens: 0, savedTokens: savedTokens,
        costCents: costCents, feature: feature, command: nil
    )
    Thread.sleep(forTimeInterval: 0.05)
}

// MARK: - Tests

@Suite("Dashboard — Data Aggregation")
struct DashboardDataTests {

    @Test func portfolioStatsAggregateAllProjects() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        insertEvent(db: db, projectRoot: "/tmp/A", feature: "filter", inputTokens: 1000, savedTokens: 300, costCents: 5)
        insertEvent(db: db, projectRoot: "/tmp/B", feature: "cache", inputTokens: 2000, savedTokens: 600, costCents: 10)

        let all = db.tokenStatsAllProjects()
        #expect(all.inputTokens == 3000, "Input tokens should sum: got \(all.inputTokens)")
        #expect(all.savedTokens == 900, "Saved tokens should sum: got \(all.savedTokens)")
        #expect(all.costCents == 15, "Cost should sum: got \(all.costCents)")
    }

    @Test func featureBreakdownAcrossAllProjects() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        insertEvent(db: db, projectRoot: "/tmp/A", feature: "filter", savedTokens: 200)
        insertEvent(db: db, projectRoot: "/tmp/A", feature: "cache", savedTokens: 100)
        insertEvent(db: db, projectRoot: "/tmp/B", feature: "filter", savedTokens: 150)

        let results = db.tokenStatsByFeatureAllProjects()
        #expect(results.count == 2, "Should have 2 features")
        let filter = results.first { $0.feature == "filter" }
        #expect(filter?.savedTokens == 350, "Filter should sum to 350 across projects")
    }

    @Test func monthFilterUsesCalendarBoundary() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        // Insert current event
        insertEvent(db: db, projectRoot: "/tmp/A", feature: "cache", savedTokens: 200)

        // Backdate another event to last month
        insertEvent(db: db, projectRoot: "/tmp/A", feature: "filter", savedTokens: 500)
        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        db.executeRawSQL("UPDATE token_events SET timestamp = \(lastMonth.timeIntervalSince1970) WHERE feature = 'filter'")
        Thread.sleep(forTimeInterval: 0.05)

        let startOfMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
        let stats = db.tokenStatsForProject("/tmp/A", since: startOfMonth)
        #expect(stats.savedTokens == 200, "Only current month should be included, got \(stats.savedTokens)")
    }

    @Test func topOptimizationPicksHighest() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        insertEvent(db: db, projectRoot: "/tmp/A", feature: "filter", savedTokens: 300)
        insertEvent(db: db, projectRoot: "/tmp/A", feature: "cache", savedTokens: 400)

        let features = db.tokenStatsByFeature(projectRoot: "/tmp/A")
        #expect(features.first?.feature == "cache", "Cache (400) should rank above filter (300)")
    }

    @Test func emptyDatabaseProducesZeroStats() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let all = db.tokenStatsAllProjects()
        #expect(all == .zero)

        let features = db.tokenStatsByFeatureAllProjects()
        #expect(features.isEmpty)

        let series = db.savingsTimeSeriesAllProjects()
        #expect(series.isEmpty)
    }

    @Test func timeSeriesAllProjectsReturnsSorted() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        insertEvent(db: db, projectRoot: "/tmp/A", feature: "filter", savedTokens: 100)
        Thread.sleep(forTimeInterval: 0.05)
        insertEvent(db: db, projectRoot: "/tmp/B", feature: "cache", savedTokens: 200)

        let series = db.savingsTimeSeriesAllProjects()
        #expect(series.count == 2, "Should have 2 data points")
        if series.count == 2 {
            #expect(series[0].timestamp <= series[1].timestamp, "Should be sorted ascending by time")
            #expect(series[1].cumulativeSaved > series[0].cumulativeSaved, "Cumulative should grow")
        }
    }
}
