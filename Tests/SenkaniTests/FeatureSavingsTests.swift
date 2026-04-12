import Testing
import Foundation
@testable import Core

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-feature-savings-test-\(UUID().uuidString).sqlite"
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
    projectRoot: String = "/tmp/test-project",
    feature: String,
    savedTokens: Int,
    inputTokens: Int = 100,
    outputTokens: Int = 50
) {
    db.recordTokenEvent(
        sessionId: "test-session",
        paneId: nil,
        projectRoot: projectRoot,
        source: "mcp_tool",
        toolName: "read",
        model: nil,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        savedTokens: savedTokens,
        costCents: 1,
        feature: feature,
        command: "/tmp/test.swift"
    )
    // Flush async write
    _ = db.tokenStatsAllProjects()
}

@Suite("SessionDatabase — Feature Savings Breakdown")
struct FeatureSavingsTests {

    @Test func featureSavingsGroupsByFeature() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        // 3 filter events with saved_tokens=100 each
        for _ in 0..<3 { insertEvent(db: db, feature: "filter", savedTokens: 100) }
        // 2 cache events with saved_tokens=200 each
        for _ in 0..<2 { insertEvent(db: db, feature: "cache", savedTokens: 200) }

        let results = db.tokenStatsByFeature(projectRoot: "/tmp/test-project")

        #expect(results.count == 2, "Expected 2 features, got \(results.count)")
        // cache first (400 total > 300 total)
        #expect(results[0].feature == "cache")
        #expect(results[0].savedTokens == 400)
        #expect(results[0].eventCount == 2)
        #expect(results[1].feature == "filter")
        #expect(results[1].savedTokens == 300)
        #expect(results[1].eventCount == 3)
    }

    @Test func featureSavingsFiltersZeroSavings() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        // Events with saved_tokens=0 (hook-only)
        insertEvent(db: db, feature: "hook", savedTokens: 0)
        insertEvent(db: db, feature: "hook", savedTokens: 0)
        // Events with actual savings
        insertEvent(db: db, feature: "filter", savedTokens: 50)

        let results = db.tokenStatsByFeature(projectRoot: "/tmp/test-project")

        #expect(results.count == 1, "Zero-savings events should be excluded")
        #expect(results[0].feature == "filter")
    }

    @Test func featureSavingsScopesToProject() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        insertEvent(db: db, projectRoot: "/tmp/project-a", feature: "filter", savedTokens: 100)
        insertEvent(db: db, projectRoot: "/tmp/project-b", feature: "cache", savedTokens: 200)

        let resultsA = db.tokenStatsByFeature(projectRoot: "/tmp/project-a")
        let resultsB = db.tokenStatsByFeature(projectRoot: "/tmp/project-b")

        #expect(resultsA.count == 1)
        #expect(resultsA[0].feature == "filter")
        #expect(resultsB.count == 1)
        #expect(resultsB[0].feature == "cache")
    }

    @Test func featureSavingsRespectsSinceDate() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        // Insert some events (all at ~now)
        insertEvent(db: db, feature: "filter", savedTokens: 100)
        insertEvent(db: db, feature: "cache", savedTokens: 200)

        // Query with since = 1 hour ago — should find both
        let recent = db.tokenStatsByFeature(projectRoot: "/tmp/test-project", since: Date().addingTimeInterval(-3600))
        #expect(recent.count == 2, "Recent events should be found")

        // Query with since = 1 hour in the future — should find none
        let future = db.tokenStatsByFeature(projectRoot: "/tmp/test-project", since: Date().addingTimeInterval(3600))
        #expect(future.isEmpty, "Future since date should exclude all events")
    }

    @Test func featureSavingsEmptyReturnsEmpty() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let results = db.tokenStatsByFeature(projectRoot: "/tmp/nonexistent-project")
        #expect(results.isEmpty)
    }

    @Test func featureSavingsEquatable() {
        let a = SessionDatabase.FeatureSavings(feature: "filter", savedTokens: 100, inputTokens: 50, outputTokens: 25, eventCount: 3)
        let b = SessionDatabase.FeatureSavings(feature: "filter", savedTokens: 100, inputTokens: 50, outputTokens: 25, eventCount: 3)
        let c = SessionDatabase.FeatureSavings(feature: "cache", savedTokens: 100, inputTokens: 50, outputTokens: 25, eventCount: 3)

        #expect(a == b, "Identical FeatureSavings should be equal")
        #expect(a != c, "Different feature should not be equal")
    }
}
