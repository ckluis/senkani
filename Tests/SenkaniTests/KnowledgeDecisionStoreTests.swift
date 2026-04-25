import Testing
import Foundation
@testable import Core

private func makeTempKB() -> (KnowledgeStore, String) {
    let path = "/tmp/senkani-decisionstore-test-\(UUID().uuidString).sqlite"
    return (KnowledgeStore(path: path), path)
}

private func cleanupKB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func makeEntity(_ name: String) -> KnowledgeEntity {
    KnowledgeEntity(name: name, markdownPath: ".senkani/knowledge/\(name).md")
}

private func makeDecision(
    entityId: Int64? = nil,
    entityName: String,
    decision: String = "use approach X",
    rationale: String = "because Y",
    source: String = "agent",
    commitHash: String? = nil,
    at: Date = Date()
) -> DecisionRecord {
    DecisionRecord(
        entityId: entityId, entityName: entityName,
        decision: decision, rationale: rationale,
        source: source, commitHash: commitHash, createdAt: at
    )
}

@Suite("DecisionStore — schema + dedup invariants")
struct DecisionStoreInvariantTests {

    @Test func schemaSurvivesReopen() {
        let path = "/tmp/senkani-decisionstore-reopen-\(UUID().uuidString).sqlite"
        defer { cleanupKB(path) }

        do {
            let store = KnowledgeStore(path: path)
            _ = store.insertDecision(makeDecision(entityName: "Foo"))
            store.close()
        }

        let reopened = KnowledgeStore(path: path)
        #expect(reopened.decisions(forEntityName: "Foo").count == 1, "row survives reopen")
        // Verify the partial index is also intact: a second git_commit row with
        // the same hash must still be deduped after reopen.
        _ = reopened.insertDecision(makeDecision(
            entityName: "Bar", source: "git_commit", commitHash: "abc123"
        ))
        _ = reopened.insertDecision(makeDecision(
            entityName: "Bar", source: "git_commit", commitHash: "abc123"
        ))
        #expect(reopened.decisions(forEntityName: "Bar").count == 1, "partial index survived reopen")
    }

    /// Non-`git_commit` sources can repeat freely — the partial unique index
    /// only fires for git_commit rows.
    @Test func nonGitCommitSourcesCanRepeat() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        for _ in 0..<3 {
            _ = store.insertDecision(makeDecision(
                entityName: "Repeat", source: "agent"
            ))
        }
        #expect(store.decisions(forEntityName: "Repeat").count == 3,
                "non-git-commit duplicates are not blocked")
    }

    /// A `git_commit` row with a different commit hash is a different row,
    /// even when the entity_name matches an existing one.
    @Test func gitCommitDifferentHashAllowed() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        _ = store.insertDecision(makeDecision(
            entityName: "Same", source: "git_commit", commitHash: "aaa"
        ))
        _ = store.insertDecision(makeDecision(
            entityName: "Same", source: "git_commit", commitHash: "bbb"
        ))
        #expect(store.decisions(forEntityName: "Same").count == 2)
    }

    /// `decisions(forEntityName:)` orders DESC by `created_at` (latest first).
    @Test func decisionsOrderedByCreatedAtDesc() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let earlier = makeDecision(entityName: "T", decision: "old",
                                   at: Date(timeIntervalSince1970: 1_000))
        let later = makeDecision(entityName: "T", decision: "new",
                                 at: Date(timeIntervalSince1970: 2_000))
        _ = store.insertDecision(earlier)   // intentionally inverted
        _ = store.insertDecision(later)

        let rows = store.decisions(forEntityName: "T")
        #expect(rows.map(\.decision) == ["new", "old"])
    }

    /// Decisions can be filed without an entity_id row — annotation-mode usage
    /// where the entity hasn't been auto-discovered yet.
    @Test func decisionWithNilEntityIdSupported() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let id = store.insertDecision(makeDecision(
            entityId: nil, entityName: "Phantom",
            source: "annotation"
        ))
        #expect(id > 0, "row inserted")
        let rows = store.decisions(forEntityName: "Phantom")
        #expect(rows.count == 1)
        #expect(rows.first?.entityId == nil, "entity_id round-trips as NULL")
    }

    /// `entity_id REFERENCES knowledge_entities(id) ON DELETE CASCADE` —
    /// removing the entity removes any decisions tied to it via entity_id.
    /// Decisions with NULL entity_id (annotation mode) survive.
    @Test func cascadeDeleteOnEntityRemoval() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let id = store.upsertEntity(makeEntity("Tied"))
        _ = store.insertDecision(makeDecision(
            entityId: id, entityName: "Tied", source: "agent"
        ))
        _ = store.insertDecision(makeDecision(
            entityId: nil, entityName: "Tied", source: "annotation"
        ))

        store.deleteEntity(named: "Tied")
        store.queue.sync {}

        let surviving = store.decisions(forEntityName: "Tied")
        #expect(surviving.count == 1, "FK-tied decision cascaded; standalone survives")
        #expect(surviving.first?.source == "annotation")
    }
}
