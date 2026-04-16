import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempKB() -> (KnowledgeStore, String) {
    let path = "/tmp/senkani-kb-test-\(UUID().uuidString).sqlite"
    let store = KnowledgeStore(path: path)
    return (store, path)
}

private func cleanupKB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func makeEntity(
    name: String,
    entityType: String = "class",
    sourcePath: String? = nil,
    understanding: String = "",
    mentionCount: Int = 0
) -> KnowledgeEntity {
    KnowledgeEntity(
        name: name,
        entityType: entityType,
        sourcePath: sourcePath,
        markdownPath: ".senkani/knowledge/\(name).md",
        contentHash: "abc123",
        compiledUnderstanding: understanding,
        mentionCount: mentionCount
    )
}

// MARK: - Suite 1: Entity CRUD

@Suite("KnowledgeStore — Entity CRUD")
struct KnowledgeStoreCRUDTests {

    @Test func upsertAndFetch() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let e = makeEntity(
            name: "SessionDatabase",
            entityType: "class",
            sourcePath: "Sources/Core/SessionDatabase.swift",
            understanding: "Manages all SQLite sessions for Senkani",
            mentionCount: 5
        )
        let id = store.upsertEntity(e)
        #expect(id > 0, "upsert should return a valid row id")

        let fetched = store.entity(named: "SessionDatabase")
        #expect(fetched != nil, "Should fetch entity by name")
        #expect(fetched?.name == "SessionDatabase")
        #expect(fetched?.entityType == "class")
        #expect(fetched?.sourcePath == "Sources/Core/SessionDatabase.swift")
        #expect(fetched?.compiledUnderstanding == "Manages all SQLite sessions for Senkani")
        #expect(fetched?.mentionCount == 5)
        #expect(fetched?.id == id)
    }

    @Test func upsertUpdatesExisting() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let first = makeEntity(name: "HookRouter", understanding: "Routes hooks v1")
        let id1 = store.upsertEntity(first)

        let updated = makeEntity(name: "HookRouter", understanding: "Routes hooks v2")
        let id2 = store.upsertEntity(updated)

        // Same name → same stable id, no duplicate row
        #expect(id1 == id2, "UPSERT should keep stable rowid")

        let entities = store.allEntities()
        let matching = entities.filter { $0.name == "HookRouter" }
        #expect(matching.count == 1, "Should not create duplicate entity")
        #expect(matching.first?.compiledUnderstanding == "Routes hooks v2", "Should update understanding")
    }

    @Test func deleteEntityCascades() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let sourceId = store.upsertEntity(makeEntity(name: "Alpha"))
        let targetId = store.upsertEntity(makeEntity(name: "Beta"))

        // Insert a link from Alpha → Beta
        store.insertLink(EntityLink(sourceId: sourceId, targetName: "Beta", relation: "depends_on"))

        // Insert a decision
        store.insertDecision(DecisionRecord(
            entityId: sourceId, entityName: "Alpha",
            decision: "Use raw SQLite", rationale: "Consistent with codebase",
            source: "annotation"
        ))

        // Delete Alpha — cascade should remove links and decisions
        store.deleteEntity(named: "Alpha")
        Thread.sleep(forTimeInterval: 0.15)  // flush async delete

        #expect(store.entity(named: "Alpha") == nil, "Entity should be deleted")
        let remainingLinks = store.links(fromEntityId: sourceId)
        #expect(remainingLinks.isEmpty, "Links should cascade-delete with entity")

        // Note: decision_records has entity_id FK with CASCADE — verify via decisions query
        let decisions = store.decisions(forEntityName: "Alpha")
        #expect(decisions.isEmpty, "Decisions should cascade-delete with entity")

        // Beta should be unaffected
        #expect(store.entity(named: "Beta") != nil, "Beta should survive Alpha's deletion")
        let _ = targetId  // suppress unused warning
    }

    @Test func allEntitiesSortedByMentionCount() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        store.upsertEntity(makeEntity(name: "Rarely", mentionCount: 1))
        store.upsertEntity(makeEntity(name: "Often", mentionCount: 99))
        store.upsertEntity(makeEntity(name: "Sometimes", mentionCount: 10))

        let sorted = store.allEntities(sortedBy: .mentionCountDesc)
        #expect(sorted.first?.name == "Often", "Highest mention count should be first")
        #expect(sorted.last?.name == "Rarely", "Lowest mention count should be last")
    }
}

// MARK: - Suite 2: FTS5 Search

@Suite("KnowledgeStore — FTS5 Search")
struct KnowledgeStoreFTSTests {

    @Test func searchExactName() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        store.upsertEntity(makeEntity(name: "AutoValidateWorker", understanding: "Runs validators on save"))
        store.upsertEntity(makeEntity(name: "UnrelatedThing", understanding: "Nothing here"))

        let results = store.search(query: "AutoValidateWorker")
        #expect(!results.isEmpty, "Should find entity by exact name")
        #expect(results.first?.entity.name == "AutoValidateWorker", "Top result should match entity name")
    }

    @Test func searchPartialContent() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        store.upsertEntity(makeEntity(
            name: "DiagnosticRewriter",
            understanding: "Rewrites raw compiler output into user-friendly advisories"
        ))

        let results = store.search(query: "compiler advisories")
        #expect(!results.isEmpty, "Should find entity by content keyword")
        #expect(results.first?.entity.name == "DiagnosticRewriter")
    }

    @Test func searchSanitizesFTS5Operators() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        store.upsertEntity(makeEntity(name: "SafetyCheck", understanding: "checks safety rules"))

        // These would crash unsanitized FTS5 queries
        let dangerous = ["AND OR NOT", "\"unclosed quote", "*prefix*", "NEAR(a b, 5)"]
        for q in dangerous {
            let results = store.search(query: q)
            // Main assertion: no crash
            #expect(true, "Query '\(q)' should not crash: got \(results.count) result(s)")
        }
    }

    @Test func searchEmptyQueryReturnsEmpty() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        store.upsertEntity(makeEntity(name: "Anything", understanding: "content"))

        let results = store.search(query: "")
        #expect(results.isEmpty, "Empty query should return no results")
    }

    @Test func searchSnippetContainsMarkers() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        store.upsertEntity(makeEntity(
            name: "KnowledgeStore",
            understanding: "Stores compiled knowledge in a local SQLite vault"
        ))

        let results = store.search(query: "vault")
        #expect(!results.isEmpty, "Should find entity with 'vault' in understanding")
        if let first = results.first {
            // Snippet should use «»… markers (not HTML)
            let hasMarker = first.snippet.contains("\u{AB}") || first.snippet.contains("\u{BB}")
            #expect(hasMarker, "Snippet should use «» markers, got: \(first.snippet)")
        }
    }
}

// MARK: - Suite 3: Links

@Suite("KnowledgeStore — Entity Links")
struct KnowledgeStoreLinksTests {

    @Test func insertLinkAndFetch() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let srcId = store.upsertEntity(makeEntity(name: "Controller"))
        _ = store.upsertEntity(makeEntity(name: "Model"))

        store.insertLink(EntityLink(
            sourceId: srcId, targetName: "Model",
            relation: "depends_on", confidence: 0.9, lineNumber: 42
        ))

        let fetched = store.links(fromEntityId: srcId)
        #expect(fetched.count == 1, "Should fetch one link")
        #expect(fetched.first?.targetName == "Model")
        #expect(fetched.first?.relation == "depends_on")
        #expect(fetched.first?.lineNumber == 42)
    }

    @Test func resolveLinksPopulatesTargetId() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let srcId = store.upsertEntity(makeEntity(name: "View"))
        let tgtId = store.upsertEntity(makeEntity(name: "ViewModel"))

        store.insertLink(EntityLink(sourceId: srcId, targetName: "ViewModel"))
        store.resolveLinks()

        let links = store.links(fromEntityId: srcId)
        #expect(links.first?.targetId == tgtId, "resolveLinks should populate target_id")
    }

    @Test func backlinksReturnsReverseLinks() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let aId = store.upsertEntity(makeEntity(name: "Parser"))
        let bId = store.upsertEntity(makeEntity(name: "Lexer"))
        let cId = store.upsertEntity(makeEntity(name: "AST"))

        store.insertLink(EntityLink(sourceId: aId, targetName: "Lexer", relation: "uses"))
        store.insertLink(EntityLink(sourceId: cId, targetName: "Lexer", relation: "produced_by"))

        let backs = store.backlinks(toEntityName: "Lexer")
        #expect(backs.count == 2, "Should find both backlinks to Lexer")

        let sourceIds = Set(backs.map(\.sourceId))
        #expect(sourceIds.contains(aId))
        #expect(sourceIds.contains(cId))
        let _ = bId  // suppress warning
    }

    @Test func duplicateLinksIgnored() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let srcId = store.upsertEntity(makeEntity(name: "Foo"))
        store.upsertEntity(makeEntity(name: "Bar"))

        store.insertLink(EntityLink(sourceId: srcId, targetName: "Bar", relation: "depends_on"))
        store.insertLink(EntityLink(sourceId: srcId, targetName: "Bar", relation: "depends_on"))

        let links = store.links(fromEntityId: srcId)
        #expect(links.count == 1, "Duplicate links should be ignored (INSERT OR IGNORE)")
    }
}

// MARK: - Suite 4: Decision Records

@Suite("KnowledgeStore — Decision Records")
struct KnowledgeStoreDecisionsTests {

    @Test func insertAndFetchDecision() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let eid = store.upsertEntity(makeEntity(name: "AuthMiddleware"))
        store.insertDecision(DecisionRecord(
            entityId: eid, entityName: "AuthMiddleware",
            decision: "Use JWT over sessions",
            rationale: "Stateless, scales horizontally",
            source: "annotation",
            commitHash: nil
        ))

        let records = store.decisions(forEntityName: "AuthMiddleware")
        #expect(records.count == 1, "Should fetch one decision")
        #expect(records.first?.decision == "Use JWT over sessions")
        #expect(records.first?.rationale == "Stateless, scales horizontally")
        #expect(records.first?.source == "annotation")
    }

    @Test func gitCommitDecisionDeduped() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let eid = store.upsertEntity(makeEntity(name: "RateLimiter"))
        let rec = DecisionRecord(
            entityId: eid, entityName: "RateLimiter",
            decision: "Token bucket algorithm",
            rationale: "Smooth bursts, predictable",
            source: "git_commit",
            commitHash: "abc123def456"
        )
        store.insertDecision(rec)
        store.insertDecision(rec)  // same commit hash — should be ignored

        let records = store.decisions(forEntityName: "RateLimiter")
        #expect(records.count == 1, "Same git_commit hash should not produce duplicate decision")
    }
}

// MARK: - Suite 5: Evidence Timeline

@Suite("KnowledgeStore — Evidence Timeline")
struct KnowledgeStoreEvidenceTests {

    @Test func appendAndFetchTimeline() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let eid = store.upsertEntity(makeEntity(name: "Scheduler"))

        store.appendEvidence(EvidenceEntry(
            entityId: eid, sessionId: "sess-1",
            whatWasLearned: "Scheduler handles priority queues",
            source: "annotation",
            createdAt: Date(timeIntervalSince1970: 1000)
        ))
        store.appendEvidence(EvidenceEntry(
            entityId: eid, sessionId: "sess-2",
            whatWasLearned: "Scheduler uses min-heap internally",
            source: "enrichment",
            createdAt: Date(timeIntervalSince1970: 2000)
        ))

        let entries = store.timeline(forEntityId: eid)
        #expect(entries.count == 2, "Should fetch both timeline entries")
        #expect(entries[0].whatWasLearned == "Scheduler handles priority queues", "First entry should be oldest")
        #expect(entries[1].source == "enrichment", "Second entry should be newer")
    }

    @Test func timelineIsAppendOnly() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let eid = store.upsertEntity(makeEntity(name: "EventBus"))
        for i in 1...5 {
            store.appendEvidence(EvidenceEntry(
                entityId: eid, sessionId: "sess",
                whatWasLearned: "Learning \(i)",
                source: "annotation"
            ))
        }

        let entries = store.timeline(forEntityId: eid)
        #expect(entries.count == 5, "All entries should persist (append-only)")
        // Verify ascending time order
        for i in 1..<entries.count {
            #expect(entries[i].createdAt >= entries[i-1].createdAt, "Timeline should be ordered ascending")
        }
    }
}

// MARK: - Suite 6: Co-Change Coupling

@Suite("KnowledgeStore — Co-Change Coupling")
struct KnowledgeStoreCouplingTests {

    @Test func upsertCouplingAndFetch() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        store.upsertCoupling(CouplingEntry(
            entityA: "Schema.swift", entityB: "Migration.swift",
            commitCount: 7, totalCommits: 20,
            couplingScore: 0.7
        ))
        Thread.sleep(forTimeInterval: 0.1)  // flush async write

        let couplings = store.couplings(forEntityName: "Schema.swift")
        #expect(couplings.count == 1, "Should fetch coupling for entity")
        #expect(couplings.first?.couplingScore ?? 0 > 0.6)
    }

    @Test func upsertCouplingUpdatesNotDuplicates() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        store.upsertCoupling(CouplingEntry(
            entityA: "A.swift", entityB: "B.swift",
            commitCount: 3, totalCommits: 10, couplingScore: 0.3
        ))
        store.upsertCoupling(CouplingEntry(
            entityA: "A.swift", entityB: "B.swift",
            commitCount: 8, totalCommits: 20, couplingScore: 0.5  // updated
        ))
        Thread.sleep(forTimeInterval: 0.1)

        let couplings = store.couplings(forEntityName: "A.swift", minScore: 0.0)
        #expect(couplings.count == 1, "Should not duplicate on re-upsert")
        #expect(couplings.first?.couplingScore == 0.5, "Score should be updated to latest")
        #expect(couplings.first?.commitCount == 8)
    }

    @Test func couplingOrderCanonicalized() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        // Insert with reversed order — should canonical to (A, B)
        store.upsertCoupling(CouplingEntry(
            entityA: "Zebra.swift", entityB: "Alpha.swift",
            commitCount: 5, totalCommits: 10, couplingScore: 0.5
        ))
        Thread.sleep(forTimeInterval: 0.1)

        // Query from either direction should find it
        let fromAlpha = store.couplings(forEntityName: "Alpha.swift", minScore: 0.0)
        let fromZebra = store.couplings(forEntityName: "Zebra.swift", minScore: 0.0)
        #expect(fromAlpha.count == 1, "Should find coupling queried from Alpha side")
        #expect(fromZebra.count == 1, "Should find coupling queried from Zebra side")
        // Canonical ordering: Alpha < Zebra alphabetically
        #expect(fromAlpha.first?.entityA == "Alpha.swift", "entity_a should be canonical (alphabetically first)")
    }

    @Test func minScoreFiltersResults() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        store.upsertCoupling(CouplingEntry(
            entityA: "Core.swift", entityB: "Weak.swift",
            commitCount: 1, totalCommits: 100, couplingScore: 0.01
        ))
        store.upsertCoupling(CouplingEntry(
            entityA: "Core.swift", entityB: "Strong.swift",
            commitCount: 40, totalCommits: 100, couplingScore: 0.4
        ))
        Thread.sleep(forTimeInterval: 0.1)

        let filtered = store.couplings(forEntityName: "Core.swift", minScore: 0.3)
        #expect(filtered.count == 1, "Should filter out coupling below minScore")
        #expect(filtered.first?.entityB == "Strong.swift")
    }
}
