import Foundation

// Public forwarders for the entity / FTS surface, delegating to `EntityStore`.
// Callers stay on `KnowledgeStore.upsertEntity(...)` etc.; the split is invisible.
extension KnowledgeStore {

    /// Upsert an entity with an explicit `AuthorshipTag` (Phase V.5).
    /// The default of `.unset` is the explicit "operator has not yet
    /// chosen" sentinel — never silently resolved to `.humanAuthored`.
    /// Production callers should pass a real tag; the V.5b UI prompt
    /// path turns `.unset` into one of the three concrete tags before
    /// any policy decision keys off the value.
    @discardableResult
    public func upsertEntity(
        _ entity: KnowledgeEntity,
        authorship: AuthorshipTag = .unset
    ) -> Int64 {
        entityStore.upsertEntity(entity, authorship: authorship)
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

    /// Phase V.5c — count legacy NULL-authorship rows since a date. Used
    /// by `senkani authorship backfill` as the dry-run preview surface.
    public func countNullAuthorship(since: Date) -> Int {
        entityStore.countNullAuthorship(since: since)
    }

    /// Phase V.5c — bulk-tag legacy NULL-authorship rows. Matches only
    /// rows whose `authorship IS NULL`; the in-band `.unset` sentinel is
    /// preserved as an explicit operator deferral. Idempotent.
    @discardableResult
    public func backfillNullAuthorship(since: Date, tag: AuthorshipTag) -> Int {
        entityStore.backfillNullAuthorship(since: since, tag: tag)
    }
}
