import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempTracker(
    config: EntityTrackerConfig = .default
) throws -> (EntityTracker, KnowledgeStore, String) {
    let root = "/tmp/senkani-et-test-\(UUID().uuidString)"
    let store = KnowledgeStore(path: root + "/vault.db")
    let tracker = EntityTracker(store: store, config: config)
    return (tracker, store, root)
}

@discardableResult
private func insertEntity(_ name: String, into store: KnowledgeStore) -> Int64 {
    store.upsertEntity(KnowledgeEntity(
        name: name,
        markdownPath: ".senkani/knowledge/\(name).md"
    ))
}

private func cleanup(_ root: String) {
    try? FileManager.default.removeItem(atPath: root)
}

// MARK: - Suite

@Suite("EntityTracker")
struct EntityTrackerTests {

    // 1. Basic detection
    @Test func testObserveDetectsEntityName() throws {
        let (tracker, store, root) = try makeTempTracker()
        defer { cleanup(root) }

        insertEntity("Scheduler", into: store)
        tracker.reloadEntities()

        let detected = tracker.observe(text: "The Scheduler handles tasks")
        #expect(detected == ["Scheduler"], "Should detect 'Scheduler'")
        #expect(tracker.state().pendingDelta["Scheduler"] == 1)
    }

    // 2. Flush persists to store
    @Test func testFlushWritesToStore() throws {
        let (tracker, store, root) = try makeTempTracker()
        defer { cleanup(root) }

        insertEntity("Parser", into: store)
        tracker.reloadEntities()

        tracker.observe(text: "Parser text")
        tracker.flush()
        Thread.sleep(forTimeInterval: 0.1)

        let entity = store.entity(named: "Parser")
        #expect(entity != nil, "Entity should exist")
        #expect(entity!.sessionMentions == 1, "sessionMentions should be 1")
        #expect(entity!.mentionCount == 1, "mentionCount should be 1")
    }

    // 3. Threshold trigger is idempotent
    @Test func testThresholdTriggerAndIdempotency() throws {
        let cfg = EntityTrackerConfig(flushIntervalCalls: 200, mentionThreshold: 3)
        let (tracker, store, root) = try makeTempTracker(config: cfg)
        defer { cleanup(root) }

        insertEntity("Widget", into: store)
        tracker.reloadEntities()

        // First 3 observations: threshold crossed
        for _ in 1...3 { tracker.observe(text: "Widget is active") }
        let first = tracker.consumeEnrichmentCandidates()
        #expect(first.contains("Widget"), "Widget should be in first drain")

        // After drain, queue is empty
        let second = tracker.consumeEnrichmentCandidates()
        #expect(second.isEmpty, "Second drain should be empty")

        // More observations — threshold already triggered, no re-enqueue
        for _ in 1...3 { tracker.observe(text: "Widget is active") }
        let third = tracker.consumeEnrichmentCandidates()
        #expect(third.isEmpty, "Should not re-trigger after alreadyTriggered")
    }

    // 4. Auto-flush fires at interval
    @Test func testAutoFlushAtInterval() throws {
        let cfg = EntityTrackerConfig(flushIntervalCalls: 5, mentionThreshold: 50)
        let (tracker, store, root) = try makeTempTracker(config: cfg)
        defer { cleanup(root) }

        insertEntity("Router", into: store)
        tracker.reloadEntities()

        // 5 observations — 5th triggers auto-flush
        for _ in 1...5 { tracker.observe(text: "Router handles request") }
        Thread.sleep(forTimeInterval: 0.1)

        let entity = store.entity(named: "Router")
        #expect(entity != nil)
        #expect(entity!.sessionMentions >= 5,
                "After auto-flush, sessionMentions should be ≥5, got \(entity!.sessionMentions)")
    }

    // 5. Session reset clears all in-memory state
    @Test func testSessionReset() throws {
        let (tracker, store, root) = try makeTempTracker()
        defer { cleanup(root) }

        insertEntity("Store", into: store)
        tracker.reloadEntities()

        for _ in 1...3 { tracker.observe(text: "Store accessed") }
        let beforeReset = tracker.state()
        #expect(beforeReset.sessionTotal["Store"] == 3)

        tracker.resetSession()

        let s = tracker.state()
        #expect(s.sessionTotal.isEmpty, "sessionTotal should be empty after reset")
        #expect(s.pendingDelta.isEmpty, "pendingDelta should be empty after reset")
        #expect(s.enrichmentCandidates.isEmpty, "enrichmentCandidates should be empty after reset")
        #expect(s.callsSinceFlush == 0, "callsSinceFlush should be 0 after reset")
    }

    // 6. Multiple entities detected in single observation
    @Test func testMultiEntityInSingleObservation() throws {
        let (tracker, store, root) = try makeTempTracker()
        defer { cleanup(root) }

        insertEntity("Alpha", into: store)
        insertEntity("Beta", into: store)
        tracker.reloadEntities()

        let detected = tracker.observe(text: "Alpha depends on Beta for processing")
        #expect(detected.contains("Alpha"), "Alpha should be detected")
        #expect(detected.contains("Beta"), "Beta should be detected")
        #expect(detected.count == 2)

        let s = tracker.state()
        #expect(s.pendingDelta["Alpha"] == 1)
        #expect(s.pendingDelta["Beta"] == 1)
    }

    // 7. Entity registry update via reloadEntities
    @Test func testEntityRegistryUpdate() throws {
        let (tracker, store, root) = try makeTempTracker()
        defer { cleanup(root) }

        // No entities loaded yet
        let before = tracker.observe(text: "KnowledgeStore text")
        #expect(before.isEmpty, "Should detect nothing with empty registry")

        // Insert entity then reload
        insertEntity("KnowledgeStore", into: store)
        tracker.reloadEntities()

        let after = tracker.observe(text: "KnowledgeStore text")
        #expect(after.contains("KnowledgeStore"), "Should detect after reload")
    }

    // 8. Concurrent observations — no data races, correct counts
    @Test func testConcurrentObservations() throws {
        let cfg = EntityTrackerConfig(flushIntervalCalls: 200, mentionThreshold: 50)
        let (tracker, store, root) = try makeTempTracker(config: cfg)
        defer { cleanup(root) }

        insertEntity("ConcurrentEntity", into: store)
        tracker.reloadEntities()

        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            tracker.observe(text: "ConcurrentEntity seen here")
        }

        tracker.flush()
        Thread.sleep(forTimeInterval: 0.1)

        let entity = store.entity(named: "ConcurrentEntity")
        #expect(entity != nil)
        #expect(entity!.mentionCount == 20,
                "Expected 20 mentions after concurrent observe, got \(entity!.mentionCount)")
    }
}
