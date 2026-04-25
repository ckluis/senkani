import Foundation

// Public forwarders for the entity / FTS surface, delegating to `EntityStore`.
// Callers stay on `KnowledgeStore.upsertEntity(...)` etc.; the split is invisible.
extension KnowledgeStore {

    @discardableResult
    public func upsertEntity(_ entity: KnowledgeEntity) -> Int64 {
        entityStore.upsertEntity(entity)
    }

    public func entity(named name: String) -> KnowledgeEntity? {
        entityStore.entity(named: name)
    }

    public func entity(id: Int64) -> KnowledgeEntity? {
        entityStore.entity(id: id)
    }

    public func allEntities(sortedBy sort: EntitySort = .mentionCountDesc) -> [KnowledgeEntity] {
        entityStore.allEntities(sortedBy: sort)
    }

    public func deleteEntity(named name: String) {
        entityStore.deleteEntity(named: name)
    }

    public func updateMentionCounts(name: String, sessionDelta: Int, lifetimeDelta: Int = 0) {
        entityStore.updateMentionCounts(name: name, sessionDelta: sessionDelta, lifetimeDelta: lifetimeDelta)
    }

    public func batchIncrementMentions(_ deltas: [String: Int]) {
        entityStore.batchIncrementMentions(deltas)
    }

    public func resetSessionMentions() {
        entityStore.resetSessionMentions()
    }

    public func updateStaleness(name: String, score: Double) {
        entityStore.updateStaleness(name: name, score: score)
    }

    public func computeStaleness(name: String, sourceFileModifiedAt: Date) -> Double {
        entityStore.computeStaleness(name: name, sourceFileModifiedAt: sourceFileModifiedAt)
    }

    public func search(query: String, limit: Int = 10) -> [KnowledgeSearchResult] {
        entityStore.search(query: query, limit: limit)
    }
}
