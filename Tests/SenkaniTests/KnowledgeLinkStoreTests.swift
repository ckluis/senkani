import Testing
import Foundation
@testable import Core

private func makeTempKB() -> (KnowledgeStore, String) {
    let path = "/tmp/senkani-linkstore-test-\(UUID().uuidString).sqlite"
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

private func makeLink(from sourceId: Int64, to targetName: String, relation: String? = "depends_on", line: Int? = nil) -> EntityLink {
    EntityLink(sourceId: sourceId, targetName: targetName, relation: relation, lineNumber: line)
}

@Suite("LinkStore — schema + FK invariants")
struct LinkStoreInvariantTests {

    @Test func schemaSurvivesReopen() {
        let path = "/tmp/senkani-linkstore-reopen-\(UUID().uuidString).sqlite"
        defer { cleanupKB(path) }

        do {
            let store = KnowledgeStore(path: path)
            let aId = store.upsertEntity(makeEntity("A"))
            _ = store.insertLink(makeLink(from: aId, to: "B"))
            store.close()
        }

        let reopened = KnowledgeStore(path: path)
        let aId = reopened.entity(named: "A")?.id ?? 0
        #expect(reopened.links(fromEntityId: aId).count == 1, "row + index survive reopen")
        // Insert a second link to confirm indexes still serve queries fast.
        _ = reopened.insertLink(makeLink(from: aId, to: "C", relation: "used_by"))
        #expect(reopened.links(fromEntityId: aId).count == 2)
    }

    /// `ON DELETE CASCADE` on `entity_links.source_id`: removing the source
    /// entity must remove all of its outgoing links.
    @Test func cascadeDeleteOnSourceEntityRemoval() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let aId = store.upsertEntity(makeEntity("A"))
        _ = store.upsertEntity(makeEntity("B"))
        _ = store.insertLink(makeLink(from: aId, to: "B"))
        _ = store.insertLink(makeLink(from: aId, to: "B", relation: "used_by"))

        store.deleteEntity(named: "A")
        store.queue.sync {}

        #expect(store.links(fromEntityId: aId).isEmpty, "outgoing links cascaded away")
    }

    /// `ON DELETE SET NULL` on `entity_links.target_id`: removing the target
    /// entity must clear `target_id` on links pointing at it without deleting
    /// the link rows themselves (target_name is preserved).
    @Test func targetIdSetNullOnTargetEntityDelete() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let aId = store.upsertEntity(makeEntity("A"))
        _ = store.upsertEntity(makeEntity("B"))
        _ = store.insertLink(makeLink(from: aId, to: "B"))
        store.resolveLinks()
        let beforeDelete = store.links(fromEntityId: aId).first
        #expect(beforeDelete?.targetId != nil, "resolveLinks set target_id")

        store.deleteEntity(named: "B")
        store.queue.sync {}

        let afterDelete = store.links(fromEntityId: aId).first
        #expect(afterDelete != nil, "link row not removed")
        #expect(afterDelete?.targetName == "B", "target_name preserved")
        #expect(afterDelete?.targetId == nil, "target_id reset to NULL")
    }

    /// `links(fromEntityId:)` orders by `created_at ASC` — that's the document
    /// order users expect. Insert two links, the older one comes first.
    @Test func linksOrderedByCreatedAtAsc() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let aId = store.upsertEntity(makeEntity("A"))
        let earlier = EntityLink(sourceId: aId, targetName: "Old",
                                 relation: "depends_on",
                                 createdAt: Date(timeIntervalSince1970: 1_000))
        let later = EntityLink(sourceId: aId, targetName: "New",
                               relation: "depends_on",
                               createdAt: Date(timeIntervalSince1970: 2_000))
        _ = store.insertLink(later)   // insert order is intentionally backwards
        _ = store.insertLink(earlier)

        let ordered = store.links(fromEntityId: aId)
        #expect(ordered.map(\.targetName) == ["Old", "New"])
    }

    /// `deleteLinks(forEntityId:)` only removes outgoing links for that one
    /// source entity — other entities' links are untouched.
    @Test func deleteLinksScopesToSourceId() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let aId = store.upsertEntity(makeEntity("A"))
        let bId = store.upsertEntity(makeEntity("B"))
        _ = store.insertLink(makeLink(from: aId, to: "X"))
        _ = store.insertLink(makeLink(from: bId, to: "X"))

        store.deleteLinks(forEntityId: aId)
        #expect(store.links(fromEntityId: aId).isEmpty)
        #expect(store.links(fromEntityId: bId).count == 1, "B's outgoing link untouched")
    }

    /// `resolveLinks` only fills in NULL `target_id` cells — already-resolved
    /// links keep the id they were inserted with.
    @Test func resolveLinksOnlyTouchesUnresolved() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let aId = store.upsertEntity(makeEntity("A"))
        let cId = store.upsertEntity(makeEntity("C"))
        // Pre-resolved link: caller supplies target_id directly.
        let preResolved = EntityLink(sourceId: aId, targetName: "C",
                                     targetId: cId, relation: "used_by")
        _ = store.insertLink(preResolved)
        // Unresolved link: target_name only.
        _ = store.upsertEntity(makeEntity("B"))
        _ = store.insertLink(makeLink(from: aId, to: "B"))

        store.resolveLinks()

        let links = store.links(fromEntityId: aId)
        #expect(links.first(where: { $0.targetName == "C" })?.targetId == cId)
        #expect(links.first(where: { $0.targetName == "B" })?.targetId != nil,
                "previously NULL target_id now populated")
    }
}
