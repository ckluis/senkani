import Testing
import Foundation
@testable import Core
@testable import MCPServer

private func makeKBRoot() -> (KnowledgeStore, String) {
    let root = "/tmp/senkani-kbcli-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: root + "/.senkani",
                                              withIntermediateDirectories: true)
    return (KnowledgeStore(projectRoot: root), root)
}

private func cleanup(_ root: String) { try? FileManager.default.removeItem(atPath: root) }

@Suite("KBCLIData")
struct KBCLITests {

    // 1. list: allEntities returns correct count and name-sort order
    @Test func testListReturnsAllEntities() {
        let (store, root) = makeKBRoot(); defer { cleanup(root) }
        store.upsertEntity(KnowledgeEntity(name: "Alpha", entityType: "class",  markdownPath: "a.md"))
        store.upsertEntity(KnowledgeEntity(name: "Beta",  entityType: "struct", markdownPath: "b.md"))
        store.upsertEntity(KnowledgeEntity(name: "Gamma", entityType: "func",   markdownPath: "c.md"))
        let all = store.allEntities(sortedBy: .nameAsc)
        #expect(all.count == 3)
        #expect(all.map(\.name) == ["Alpha", "Beta", "Gamma"])
    }

    // 2. list --type: type filter works correctly
    @Test func testListTypeFilter() {
        let (store, root) = makeKBRoot(); defer { cleanup(root) }
        store.upsertEntity(KnowledgeEntity(name: "A", entityType: "class",  markdownPath: "a.md"))
        store.upsertEntity(KnowledgeEntity(name: "B", entityType: "struct", markdownPath: "b.md"))
        store.upsertEntity(KnowledgeEntity(name: "C", entityType: "class",  markdownPath: "c.md"))
        let classes = store.allEntities().filter { $0.entityType == "class" }
        #expect(classes.count == 2)
        #expect(classes.map(\.name).sorted() == ["A", "C"])
    }

    // 3. get: entity(named:) returns correct entity with understanding
    @Test func testGetEntityByName() {
        let (store, root) = makeKBRoot(); defer { cleanup(root) }
        store.upsertEntity(KnowledgeEntity(name: "AuthManager", entityType: "class",
                                            markdownPath: "auth.md",
                                            compiledUnderstanding: "Handles auth tokens."))
        let e = store.entity(named: "AuthManager")
        #expect(e != nil)
        #expect(e?.compiledUnderstanding == "Handles auth tokens.")
        #expect(e?.entityType == "class")
    }

    // 4. get: unknown entity returns nil (CLI exit 1 path)
    @Test func testGetUnknownEntityIsNil() {
        let (store, root) = makeKBRoot(); defer { cleanup(root) }
        #expect(store.entity(named: "Ghost") == nil)
    }

    // 5. get: links and decisions accessible together for full detail output
    @Test func testGetEntityWithLinksAndDecisions() {
        let (store, root) = makeKBRoot(); defer { cleanup(root) }
        let id = store.upsertEntity(KnowledgeEntity(name: "Router", entityType: "class",
                                                     markdownPath: "r.md"))
        store.upsertEntity(KnowledgeEntity(name: "DB", entityType: "class", markdownPath: "d.md"))
        store.insertLink(EntityLink(sourceId: id, targetName: "DB", relation: "uses"))
        _ = store.insertDecision(DecisionRecord(entityId: id, entityName: "Router",
                                                 decision: "Use async routing", rationale: "perf",
                                                 source: "agent"))
        let links = store.links(fromEntityId: id)
        let decisions = store.decisions(forEntityName: "Router")
        #expect(links.count == 1)
        #expect(links[0].targetName == "DB")
        #expect(links[0].relation == "uses")
        #expect(decisions.count == 1)
        #expect(decisions[0].decision == "Use async routing")
    }

    // 6. search: FTS returns matching results for keyword
    @Test func testSearchReturnsFTSResults() {
        let (store, root) = makeKBRoot(); defer { cleanup(root) }
        store.upsertEntity(KnowledgeEntity(name: "TokenManager", entityType: "class",
                                            markdownPath: "tm.md",
                                            compiledUnderstanding: "Manages JWT bearer tokens for API auth."))
        store.upsertEntity(KnowledgeEntity(name: "Router", entityType: "class",
                                            markdownPath: "r.md",
                                            compiledUnderstanding: "Routes HTTP requests to handlers."))
        let results = store.search(query: "tokens", limit: 5)
        #expect(results.count >= 1)
        #expect(results.first?.entity.name == "TokenManager")
    }

    // 7. brief: SessionBriefGenerator formats correctly for CLI status
    @Test func testBriefGenerationForStatus() {
        let activity = SessionDatabase.LastSessionActivity(
            sessionId: "s1",
            startedAt: Date().addingTimeInterval(-2700),
            endedAt: Date(),
            durationSeconds: 2700,
            commandCount: 42,
            totalSavedTokens: 8000,
            totalRawTokens: 10000,
            lastCommand: "senkani exec git log",
            recentSearchQueries: ["auth", "routing"],
            topHotFiles: ["/project/Sources/Auth.swift", "/project/Sources/Router.swift"]
        )
        let brief = SessionBriefGenerator.generate(lastActivity: activity)
        #expect(!brief.isEmpty)
        #expect(brief.contains("42"))    // command count
        #expect(brief.contains("80%"))   // savings: 8000/10000 = 80%
    }

    // 8. brief: nil activity yields empty string (fresh project = no output)
    @Test func testBriefEmptyWhenNoActivity() {
        let brief = SessionBriefGenerator.generate(lastActivity: nil)
        #expect(brief.isEmpty)
    }
}
