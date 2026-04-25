import Foundation

// Public forwarders for the entity-link surface, delegating to `LinkStore`.
extension KnowledgeStore {

    public func deleteLinks(forEntityId entityId: Int64) {
        linkStore.deleteLinks(forEntityId: entityId)
    }

    @discardableResult
    public func insertLink(_ link: EntityLink) -> Int64 {
        linkStore.insertLink(link)
    }

    public func links(fromEntityId entityId: Int64) -> [EntityLink] {
        linkStore.links(fromEntityId: entityId)
    }

    public func backlinks(toEntityName name: String) -> [EntityLink] {
        linkStore.backlinks(toEntityName: name)
    }

    public func resolveLinks() {
        linkStore.resolveLinks()
    }
}
