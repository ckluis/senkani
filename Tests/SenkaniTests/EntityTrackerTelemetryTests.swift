import Testing
import Foundation
@testable import Core

@Suite("EntityTracker telemetry (F+2 Round 5)", .serialized)
struct EntityTrackerTelemetryTests {

    private func makeStore() throws -> (KnowledgeStore, String) {
        let root = NSTemporaryDirectory() + "senkani-f2-tracker-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/.senkani", withIntermediateDirectories: true)
        let store = KnowledgeStore(projectRoot: root)
        return (store, root)
    }

    private func makeDB() -> (SessionDatabase, String) {
        let path = NSTemporaryDirectory() + "senkani-f2-db-\(UUID().uuidString)/senkani.db"
        return (SessionDatabase(path: path), path)
    }

    private func totalCount(for prefix: String, in db: SessionDatabase) -> Int {
        db.eventCounts(prefix: prefix).reduce(0) { $0 + $1.count }
    }

    @Test func flushBumpsFlushCounter() throws {
        let (store, storeRoot) = try makeStore()
        let (db, dbPath) = makeDB()
        defer {
            try? FileManager.default.removeItem(atPath: storeRoot)
            try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent)
        }
        _ = store.upsertEntity(KnowledgeEntity(
            name: "Foo", entityType: "class",
            markdownPath: ".senkani/knowledge/Foo.md"))

        let tracker = EntityTracker(store: store)
        tracker.reloadEntities()

        _ = tracker.observe(text: "Uses Foo repeatedly.")
        tracker.flush(db: db, projectRoot: storeRoot)

        #expect(totalCount(for: "knowledge.tracker.flush", in: db) == 1)
    }

    @Test func logSessionSummaryBumpsThresholdCrossed() throws {
        let (store, storeRoot) = try makeStore()
        let (db, dbPath) = makeDB()
        defer {
            try? FileManager.default.removeItem(atPath: storeRoot)
            try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent)
        }
        _ = store.upsertEntity(KnowledgeEntity(
            name: "Foo", entityType: "class",
            markdownPath: ".senkani/knowledge/Foo.md"))

        // Threshold is 5 by default — observe 5× so Foo lands in the queue.
        let tracker = EntityTracker(store: store)
        tracker.reloadEntities()
        for _ in 0..<5 {
            _ = tracker.observe(text: "reference Foo here")
        }

        tracker.logSessionSummary(db: db, projectRoot: storeRoot)
        #expect(totalCount(for: "knowledge.tracker.threshold_crossed", in: db) == 1)
    }

    @Test func logSessionSummaryHandlesEmptyState() throws {
        let (store, storeRoot) = try makeStore()
        let (db, dbPath) = makeDB()
        defer {
            try? FileManager.default.removeItem(atPath: storeRoot)
            try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent)
        }
        let tracker = EntityTracker(store: store)
        // No observations — should not crash.
        tracker.logSessionSummary(db: db, projectRoot: storeRoot)
        #expect(totalCount(for: "knowledge.tracker.threshold_crossed", in: db) == 0)
    }
}
