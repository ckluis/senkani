import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempKB() -> (KnowledgeStore, String) {
    let path = "/tmp/senkani-entitystore-test-\(UUID().uuidString).sqlite"
    return (KnowledgeStore(path: path), path)
}

private func cleanupKB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func makeEntity(_ name: String, understanding: String = "") -> KnowledgeEntity {
    KnowledgeEntity(
        name: name,
        markdownPath: ".senkani/knowledge/\(name).md",
        compiledUnderstanding: understanding
    )
}

// MARK: - EntityStore (post-split) — store-level invariants

@Suite("EntityStore — schema + CRUD invariants")
struct EntityStoreInvariantTests {

    /// Re-opening the same .vault.db must not duplicate tables/triggers and
    /// must preserve previously inserted rows. Mirrors `CommandStore.schemaSurvivesReopen`.
    @Test func schemaSurvivesReopen() {
        let path = "/tmp/senkani-entitystore-reopen-\(UUID().uuidString).sqlite"
        defer { cleanupKB(path) }

        do {
            let store = KnowledgeStore(path: path)
            _ = store.upsertEntity(makeEntity("Alpha"))
            store.close()
        }

        let reopened = KnowledgeStore(path: path)
        #expect(reopened.entity(named: "Alpha") != nil, "row survives close + reopen")
        #expect(reopened.allEntities().count == 1, "no duplicate rows from re-init")
        // FTS triggers are still wired up: insert through the façade hits the FTS index.
        _ = reopened.upsertEntity(makeEntity("Beta", understanding: "second insert"))
        let hits = reopened.search(query: "second")
        #expect(hits.contains { $0.entity.name == "Beta" })
    }

    /// FTS5 sync must hold across many back-to-back upserts on the queue;
    /// no row inserted via the façade should be missing from the virtual table.
    @Test func ftsSyncRemainsConsistentUnderBackToBackWrites() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        for i in 0..<20 {
            _ = store.upsertEntity(makeEntity("Entity\(i)", understanding: "marker_\(i)"))
        }
        for i in 0..<20 {
            let hits = store.search(query: "marker_\(i)")
            #expect(hits.contains { $0.entity.name == "Entity\(i)" },
                    "FTS row for marker_\(i) is reachable")
        }
    }

    /// `batchIncrementMentions` is async via the queue; after a queue barrier
    /// every named row must have its counters bumped exactly once.
    @Test func batchIncrementAppliesAllDeltasOnce() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        for i in 0..<5 { _ = store.upsertEntity(makeEntity("E\(i)")) }
        store.batchIncrementMentions(["E0": 1, "E1": 2, "E2": 3, "E3": 4, "E4": 5])
        // Synchronise on the same serial queue — when this returns, the async
        // batch has finished. (Same trick used in the legacy KnowledgeStore tests.)
        store.queue.sync {}

        let counts = store.allEntities().reduce(into: [String: Int]()) { $0[$1.name] = $1.mentionCount }
        #expect(counts == ["E0": 1, "E1": 2, "E2": 3, "E3": 4, "E4": 5])
    }

    /// `resetSessionMentions` must zero session counts for every row without
    /// touching lifetime `mention_count`.
    @Test func resetSessionMentionsClearsAllRows() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        for i in 0..<3 { _ = store.upsertEntity(makeEntity("R\(i)")) }
        store.batchIncrementMentions(["R0": 2, "R1": 2, "R2": 2])
        store.queue.sync {}

        store.resetSessionMentions()
        store.queue.sync {}

        for i in 0..<3 {
            let e = store.entity(named: "R\(i)")
            #expect(e?.sessionMentions == 0, "R\(i) session count cleared")
            #expect(e?.mentionCount == 2, "R\(i) lifetime count preserved")
        }
    }

    /// `updateStaleness` must clamp inputs into [0.0, 1.0] before persisting,
    /// regardless of the caller passing a negative or super-unit value.
    @Test func updateStalenessClampedToValidRange() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }
        _ = store.upsertEntity(makeEntity("Clampy"))

        store.updateStaleness(name: "Clampy", score: -5.0)
        store.queue.sync {}
        #expect(store.entity(named: "Clampy")?.stalenessScore == 0.0, "negative clamps to 0")

        store.updateStaleness(name: "Clampy", score: 47.0)
        store.queue.sync {}
        #expect(store.entity(named: "Clampy")?.stalenessScore == 1.0, "super-unit clamps to 1")
    }

    /// An entity with no enrichment timestamp is fully stale (score = 1.0).
    /// An enrichment newer than the source file is fresh (score = 0.0).
    /// In between, the score ramps linearly over a 7-day window.
    @Test func computeStalenessRampsOverSevenDays() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        // Never-enriched entity → fully stale.
        _ = store.upsertEntity(makeEntity("Never"))
        #expect(store.computeStaleness(name: "Never", sourceFileModifiedAt: Date()) == 1.0)

        // Enriched in the future of the source file → fresh.
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        _ = store.upsertEntity(KnowledgeEntity(
            name: "Fresh", markdownPath: ".senkani/knowledge/Fresh.md",
            lastEnriched: now
        ))
        #expect(store.computeStaleness(name: "Fresh", sourceFileModifiedAt: weekAgo) == 0.0)

        // Three-day-old enrichment, source file just touched → ~3/7 stale.
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        _ = store.upsertEntity(KnowledgeEntity(
            name: "Mid", markdownPath: ".senkani/knowledge/Mid.md",
            lastEnriched: threeDaysAgo
        ))
        let mid = store.computeStaleness(name: "Mid", sourceFileModifiedAt: now)
        #expect(mid > 0.40 && mid < 0.45,
                "three-day delta lands ~3/7 of the way up the ramp (got \(mid))")
    }
}
