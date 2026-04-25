import Testing
import Foundation
@testable import Core

private func makeTempKB() -> (KnowledgeStore, String) {
    let path = "/tmp/senkani-enrichmentstore-test-\(UUID().uuidString).sqlite"
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

@Suite("EnrichmentStore — schema + lifecycle invariants")
struct EnrichmentStoreInvariantTests {

    @Test func schemaSurvivesReopen() {
        let path = "/tmp/senkani-enrichmentstore-reopen-\(UUID().uuidString).sqlite"
        defer { cleanupKB(path) }

        do {
            let store = KnowledgeStore(path: path)
            let id = store.upsertEntity(makeEntity("E"))
            _ = store.appendEvidence(EvidenceEntry(
                entityId: id, sessionId: "s1",
                whatWasLearned: "first observation", source: "enrichment"
            ))
            store.upsertCoupling(CouplingEntry(
                entityA: "alpha", entityB: "beta",
                commitCount: 5, totalCommits: 10, couplingScore: 0.5
            ))
            store.queue.sync {}
            store.close()
        }

        let reopened = KnowledgeStore(path: path)
        let id = reopened.entity(named: "E")?.id ?? 0
        #expect(reopened.timeline(forEntityId: id).count == 1)
        #expect(reopened.couplings(forEntityName: "alpha", minScore: 0.0).count == 1)
    }

    /// Removing the entity must cascade-delete its evidence rows
    /// (`entity_id REFERENCES knowledge_entities(id) ON DELETE CASCADE`).
    @Test func evidenceCascadeDeleteOnEntityRemoval() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let id = store.upsertEntity(makeEntity("Cascade"))
        for i in 0..<3 {
            _ = store.appendEvidence(EvidenceEntry(
                entityId: id, sessionId: "s\(i)",
                whatWasLearned: "obs \(i)", source: "enrichment"
            ))
        }
        #expect(store.timeline(forEntityId: id).count == 3)

        store.deleteEntity(named: "Cascade")
        store.queue.sync {}
        #expect(store.timeline(forEntityId: id).isEmpty,
                "FK cascade reaped evidence rows")
    }

    /// `timeline(forEntityId:)` must return rows in `created_at ASC` order
    /// — that's what the timeline pane and the prompt-context generator depend on.
    @Test func evidenceTimelineOrderedByCreatedAtAsc() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let id = store.upsertEntity(makeEntity("Ordered"))
        let later = EvidenceEntry(entityId: id, sessionId: "s",
                                  whatWasLearned: "second", source: "enrichment",
                                  createdAt: Date(timeIntervalSince1970: 2_000))
        let earlier = EvidenceEntry(entityId: id, sessionId: "s",
                                    whatWasLearned: "first", source: "enrichment",
                                    createdAt: Date(timeIntervalSince1970: 1_000))
        _ = store.appendEvidence(later)    // intentionally backwards
        _ = store.appendEvidence(earlier)

        let rows = store.timeline(forEntityId: id)
        #expect(rows.map(\.whatWasLearned) == ["first", "second"])
    }

    /// `upsertCoupling` canonicalises the pair so storage always has
    /// `entity_a < entity_b` even when the caller flips them.
    @Test func couplingPairCanonicalizedOnInsert() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        // Insert with reversed order.
        store.upsertCoupling(CouplingEntry(
            entityA: "Zeta", entityB: "Alpha",
            commitCount: 3, totalCommits: 6, couplingScore: 0.5
        ))
        store.queue.sync {}

        let rows = store.couplings(forEntityName: "Alpha", minScore: 0.0)
        #expect(rows.count == 1)
        #expect(rows.first?.entityA == "Alpha", "stored a < b")
        #expect(rows.first?.entityB == "Zeta")
    }

    /// Repeated upserts of the same canonical pair must produce a single row
    /// whose values reflect the latest write — not multiple stacked rows.
    @Test func couplingUpsertIdempotentUnderBurst() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        for score in [0.1, 0.4, 0.9] {
            store.upsertCoupling(CouplingEntry(
                entityA: "X", entityB: "Y",
                commitCount: Int(score * 100),
                totalCommits: 100,
                couplingScore: score
            ))
        }
        store.queue.sync {}

        let rows = store.couplings(forEntityName: "X", minScore: 0.0)
        #expect(rows.count == 1, "ON CONFLICT collapses to one row")
        #expect(rows.first?.couplingScore == 0.9, "last upsert wins")
        #expect(rows.first?.commitCount == 90)
    }

    /// `couplings(forEntityName:)` returns rows where the name appears at
    /// either end of the pair, after canonicalisation. Both queries should
    /// return the same single row.
    @Test func couplingMatchesEitherEndpoint() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        store.upsertCoupling(CouplingEntry(
            entityA: "Left", entityB: "Right",
            commitCount: 4, totalCommits: 10, couplingScore: 0.4
        ))
        store.queue.sync {}

        let leftHits = store.couplings(forEntityName: "Left", minScore: 0.0)
        let rightHits = store.couplings(forEntityName: "Right", minScore: 0.0)
        #expect(leftHits.count == 1)
        #expect(rightHits.count == 1)
        #expect(leftHits.first?.couplingScore == rightHits.first?.couplingScore)
    }
}
