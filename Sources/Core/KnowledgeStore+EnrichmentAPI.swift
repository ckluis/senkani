import Foundation

// Public forwarders for the enrichment surface (evidence timeline + co-change
// coupling), delegating to `EnrichmentStore`.
extension KnowledgeStore {

    @discardableResult
    public func appendEvidence(_ entry: EvidenceEntry) -> Int64 {
        enrichmentStore.appendEvidence(entry)
    }

    public func timeline(forEntityId entityId: Int64) -> [EvidenceEntry] {
        enrichmentStore.timeline(forEntityId: entityId)
    }

    public func upsertCoupling(_ entry: CouplingEntry) {
        enrichmentStore.upsertCoupling(entry)
    }

    public func couplings(forEntityName name: String, minScore: Double = 0.3) -> [CouplingEntry] {
        enrichmentStore.couplings(forEntityName: name, minScore: minScore)
    }
}
