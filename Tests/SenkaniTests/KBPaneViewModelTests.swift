import Testing
import Foundation
@testable import Core
@testable import MCPServer

// MARK: - Helpers (isolated test session — no shared state with KnowledgeToolTests)

private func makeTestSession() -> (MCPSession, String) {
    let root = "/tmp/senkani-kbpane-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let session = MCPSession(
        projectRoot: root, filterEnabled: false, secretsEnabled: false,
        indexerEnabled: false, cacheEnabled: false
    )
    return (session, root)
}

private func cleanup(_ root: String) {
    try? FileManager.default.removeItem(atPath: root)
}

@discardableResult
private func insertEntity(_ name: String, type: String = "class", into store: KnowledgeStore) -> Int64 {
    store.upsertEntity(KnowledgeEntity(
        name: name, entityType: type, markdownPath: ".senkani/knowledge/\(name).md"
    ))
}

// MARK: - Suite

@Suite("KBPaneViewModel — data layer")
struct KBPaneViewModelTests {

    // 1. allEntities() returns exactly what was inserted (name-sorted)
    @Test func testEntityListLoads() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        insertEntity("Alpha", into: session.knowledgeStore)
        insertEntity("Beta",  into: session.knowledgeStore)
        insertEntity("Gamma", into: session.knowledgeStore)

        let all = session.knowledgeStore.allEntities(sortedBy: .nameAsc)
        #expect(all.count == 3)
        #expect(all.map(\.name) == ["Alpha", "Beta", "Gamma"])
    }

    // 2. Fresh session produces empty list (empty-state guard)
    @Test func testEmptyStateNoEntities() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        let all = session.knowledgeStore.allEntities()
        #expect(all.isEmpty)
    }

    // 3. In-memory prefix filter (mirrors KBPaneViewModel.displayEntities)
    @Test func testInMemorySearchFilter() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        insertEntity("SearchableWorker", into: session.knowledgeStore)
        insertEntity("OtherComponent",   into: session.knowledgeStore)

        let all = session.knowledgeStore.allEntities()
        let query = "search"
        let filtered = all.filter { $0.name.lowercased().contains(query) }
        #expect(filtered.count == 1)
        #expect(filtered[0].name == "SearchableWorker")
    }

    // 4. Sort by name ascending — same sort the VM applies when sortMode == .nameAsc
    @Test func testSortByNameAsc() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        insertEntity("ZEntity", into: session.knowledgeStore)
        insertEntity("AEntity", into: session.knowledgeStore)
        insertEntity("MEntity", into: session.knowledgeStore)

        let sorted = session.knowledgeStore.allEntities(sortedBy: .nameAsc)
        #expect(sorted.count == 3)
        #expect(sorted[0].name == "AEntity")
        #expect(sorted[2].name == "ZEntity")
    }

    // 5. links(fromEntityId:) returns the inserted link — mirrors VM's select() detail load
    @Test func testDetailLinksLoadForEntity() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        let srcId = insertEntity("SourceEntity", into: session.knowledgeStore)
        insertEntity("TargetEntity", into: session.knowledgeStore)
        session.knowledgeStore.insertLink(EntityLink(
            sourceId: srcId, targetName: "TargetEntity", relation: "depends_on"
        ))

        let links = session.knowledgeStore.links(fromEntityId: srcId)
        #expect(links.count == 1)
        #expect(links[0].targetName == "TargetEntity")
        #expect(links[0].relation == "depends_on")
    }

    // 6. Entity with no links returns empty array (no crash in detail view)
    @Test func testDetailLinksEmptyForIsolatedEntity() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        let id = insertEntity("IsolatedEntity", into: session.knowledgeStore)
        let links = session.knowledgeStore.links(fromEntityId: id)
        #expect(links.isEmpty)
    }

    // 7. tracker.state().enrichmentCandidates reflects mention threshold crossing
    //    AND is non-destructive (calling state() twice returns the same count)
    @Test func testEnrichmentBadgeNonDestructivePeek() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        insertEntity("HotEntity", into: session.knowledgeStore)
        session.entityTracker.reloadEntities()

        // mentionThreshold = 5 per EntityTrackerConfig.default
        for _ in 0..<5 {
            session.entityTracker.observe(text: "HotEntity was modified here", source: "test")
        }

        let state1 = session.entityTracker.state()
        #expect(state1.enrichmentCandidates.contains("HotEntity"),
                "HotEntity should be an enrichment candidate after 5 mentions")

        // Non-destructive: second call must return the same set
        let state2 = session.entityTracker.state()
        #expect(state2.enrichmentCandidates.count == state1.enrichmentCandidates.count,
                "state() must not consume the enrichment queue")
    }

    // 8. saveUnderstanding path: upsertEntity persists compiledUnderstanding to DB
    @Test func testSaveUnderstandingPersistsToStore() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        insertEntity("EditTarget", into: session.knowledgeStore)
        guard let before = session.knowledgeStore.entity(named: "EditTarget") else {
            Issue.record("Entity not found after insert")
            return
        }
        #expect(before.compiledUnderstanding.isEmpty)

        // Replicate exactly what KBPaneViewModel.saveUnderstanding() does
        let updated = KnowledgeEntity(
            id: before.id,
            name: before.name,
            entityType: before.entityType,
            sourcePath: before.sourcePath,
            markdownPath: before.markdownPath,
            contentHash: before.contentHash,
            compiledUnderstanding: "Handles async work scheduling.",
            lastEnriched: before.lastEnriched,
            mentionCount: before.mentionCount,
            sessionMentions: before.sessionMentions,
            stalenessScore: before.stalenessScore,
            createdAt: before.createdAt,
            modifiedAt: Date()
        )
        let returnedId = session.knowledgeStore.upsertEntity(updated)

        guard let after = session.knowledgeStore.entity(named: "EditTarget") else {
            Issue.record("Entity not found after update")
            return
        }
        #expect(after.compiledUnderstanding == "Handles async work scheduling.")
        #expect(after.id == returnedId, "id must not change on upsert")
    }

    // 9. decisions(forEntityName:) returns inserted record — mirrors VM's select() detail load
    @Test func testDecisionsLoadForEntity() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        let id = insertEntity("DecidedEntity", into: session.knowledgeStore)
        session.knowledgeStore.insertDecision(DecisionRecord(
            entityId: id, entityName: "DecidedEntity",
            decision: "Use actor isolation", rationale: "prevents data races",
            source: "annotation"
        ))

        let decisions = session.knowledgeStore.decisions(forEntityName: "DecidedEntity")
        #expect(decisions.count == 1)
        #expect(decisions[0].decision == "Use actor isolation")
        #expect(decisions[0].rationale == "prevents data races")
        #expect(decisions[0].source == "annotation")
    }

    // 10. Entity with no decisions returns empty array (no crash in detail view)
    @Test func testDecisionsEmptyForNewEntity() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        insertEntity("NaiveEntity", into: session.knowledgeStore)
        let decisions = session.knowledgeStore.decisions(forEntityName: "NaiveEntity")
        #expect(decisions.isEmpty)
    }

    // 11. decisions ordered newest-first — matches VM's display order (created_at DESC)
    @Test func testDecisionsOrderedNewestFirst() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        let id = insertEntity("TimelineEntity", into: session.knowledgeStore)
        let old = Date(timeIntervalSinceNow: -86400)
        let recent = Date()
        session.knowledgeStore.insertDecision(DecisionRecord(
            entityId: id, entityName: "TimelineEntity",
            decision: "Old decision", rationale: "", source: "annotation", createdAt: old
        ))
        session.knowledgeStore.insertDecision(DecisionRecord(
            entityId: id, entityName: "TimelineEntity",
            decision: "Recent decision", rationale: "", source: "cli", createdAt: recent
        ))

        let decisions = session.knowledgeStore.decisions(forEntityName: "TimelineEntity")
        #expect(decisions.count == 2)
        #expect(decisions[0].decision == "Recent decision", "newest first (created_at DESC)")
        #expect(decisions[1].decision == "Old decision")
    }
}
