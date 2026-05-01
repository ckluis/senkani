import SwiftUI
import Core
import MCPServer

// GraphNode, GraphEdge, springLayout, WikiLinkHelpers defined in MCPServer/GraphLayout.swift

@Observable @MainActor
final class KBPaneViewModel {

    // MARK: - List state
    var entities: [KnowledgeEntity] = []
    var searchQuery: String = ""
    var sortMode: EntitySort = .mentionCountDesc
    var enrichmentBadge: Int = 0

    // Session brief (loaded once on appear, not on 2s timer)
    var sessionBriefActivity: SessionDatabase.LastSessionActivity? = nil
    var isSessionBriefExpanded: Bool = true

    /// Filtered in-memory list. Prefix match on entity name — no FTS5 needed for a name list.
    var displayEntities: [KnowledgeEntity] {
        guard !searchQuery.isEmpty else { return entities }
        let q = searchQuery.lowercased()
        return entities.filter { $0.name.lowercased().contains(q) }
    }

    // MARK: - Detail state
    var selectedEntity: KnowledgeEntity? = nil
    var detailLinks: [EntityLink] = []
    var detailContent: KBContent? = nil   // nil when no .md file exists for this entity
    var detailDecisions: [DecisionRecord] = []
    var detailCouplings: [CouplingEntry] = []
    var stagedProposal: String? = nil

    // Wiki-link completion
    var completionCandidates: [String] = []

    // Relations graph
    var showingGraph: Bool = false
    var isLoadingGraph: Bool = false
    var graphNodes: [GraphNode] = []
    var graphEdges: [GraphEdge] = []

    var understandingText: String = ""
    var isDirty: Bool = false
    var isSaving: Bool = false

    // V.5b — authorship prompt state. `pendingAuthorshipPrompt` is
    // bound to a SwiftUI `.sheet` in `KnowledgeBaseView`. Set true when
    // a save is queued but the row's prior `authorship` is `.unset` or
    // `nil`; cleared by `resolveAuthorship(_:)` (operator picked a tag,
    // save proceeds) or `skipAuthorship()` (operator deferred, save
    // aborts and the editor stays dirty).
    var pendingAuthorshipPrompt: Bool = false

    // MARK: - List actions

    /// Load entity list from store. Dispatches DB read to background, posts to main.
    /// Also refreshes enrichmentBadge via non-destructive tracker.state() peek.
    func loadEntities() {
        let store = KBReader.store
        let sort = sortMode
        Task.detached(priority: .userInitiated) { [weak self] in
            let all = store.allEntities(sortedBy: sort)
            let badge = KBReader.tracker.state().enrichmentCandidates.count
            await MainActor.run {
                self?.entities = all
                self?.enrichmentBadge = badge
            }
        }
    }

    /// Load last-session activity for brief display. No-op if already loaded.
    func loadSessionBrief() {
        guard sessionBriefActivity == nil else { return }
        let root = KBReader.projectRoot
        Task.detached(priority: .utility) { [weak self] in
            let activity = SessionDatabase.shared.lastSessionActivity(projectRoot: root)
            await MainActor.run { self?.sessionBriefActivity = activity }
        }
    }

    // MARK: - Detail actions

    /// Select an entity and load its detail on a background task.
    func select(_ entity: KnowledgeEntity) {
        selectedEntity = entity
        isDirty = false
        detailLinks = []
        detailContent = nil
        understandingText = ""
        showingGraph = false
        graphNodes = []
        graphEdges = []
        completionCandidates = []

        let store = KBReader.store
        let layer = KBReader.layer
        let entityId = entity.id
        let name = entity.name
        let fallback = entity.compiledUnderstanding

        Task.detached(priority: .userInitiated) { [weak self] in
            let links = store.links(fromEntityId: entityId)
            let decisions = store.decisions(forEntityName: name)
            let couplings = store.couplings(forEntityName: name)
            let staged = layer?.readStagedProposal(for: name)
            let content: KBContent?
            let understanding: String
            if let layer, let (c, _) = try? layer.readEntity(name: name) {
                content = c
                understanding = c.compiledUnderstanding
            } else {
                content = nil
                understanding = fallback
            }
            await MainActor.run {
                guard let self else { return }
                self.detailLinks = links
                self.detailDecisions = decisions
                self.detailCouplings = couplings
                self.stagedProposal = staged
                self.detailContent = content
                self.understandingText = understanding
            }
        }
    }

    /// Return to list. Auto-saves if dirty (fire-and-forget background task).
    func deselect() {
        if isDirty { saveUnderstanding() }
        selectedEntity = nil
        detailLinks = []
        detailContent = nil
        detailDecisions = []
        detailCouplings = []
        stagedProposal = nil
        showingGraph = false
        isLoadingGraph = false
        graphNodes = []
        graphEdges = []
        completionCandidates = []
        understandingText = ""
        isDirty = false
    }

    /// Save edited understanding to DB (always) and .md file (when layer + parsed content available).
    /// V.5b — when the row's prior authorship is `.unset` or `nil`,
    /// surfaces the prompt sheet first; the save commits only after
    /// `resolveAuthorship(_:)` lands an explicit tag. `skipAuthorship()`
    /// aborts the save and leaves the editor dirty.
    func saveUnderstanding() {
        guard let entity = selectedEntity else { return }
        if AuthorshipPromptResolver.needsPrompt(priorAuthorship: entity.authorship) {
            pendingAuthorshipPrompt = true
            return
        }
        // Prior tag is one of the three explicit values — preserve it.
        let preserved = entity.authorship ?? .unset
        commitSave(authorship: preserved)
    }

    /// V.5b — operator picked a tag in the prompt. Resolve through
    /// `AuthorshipPromptResolver` and complete the save with the
    /// chosen explicit tag (never silently inferred).
    func resolveAuthorship(_ choice: AuthorshipTag) {
        pendingAuthorshipPrompt = false
        commitSave(authorship: AuthorshipPromptResolver.resolve(choice: choice))
    }

    /// V.5b — operator hit Skip. No save. Row stays dirty so the
    /// operator can still resolve later. Cavoukian red flag: never
    /// silently persist `.unset` through this path.
    func skipAuthorship() {
        pendingAuthorshipPrompt = false
        // isDirty stays true; isSaving was never set.
    }

    /// Internal — commit the in-flight edit to the DB + on-disk
    /// markdown with an explicit tag. Called from both the no-prompt
    /// fast path and the post-resolution path.
    private func commitSave(authorship: AuthorshipTag) {
        guard let entity = selectedEntity else { return }
        isSaving = true
        let understanding = understandingText
        let original = detailContent
        let store = KBReader.store
        let layer = KBReader.layer

        Task.detached(priority: .userInitiated) { [weak self] in
            // 1. Sync to DB — preserve all other fields exactly
            let updated = KnowledgeEntity(
                id: entity.id,
                name: entity.name,
                entityType: entity.entityType,
                sourcePath: entity.sourcePath,
                markdownPath: entity.markdownPath,
                contentHash: entity.contentHash,
                compiledUnderstanding: understanding,
                lastEnriched: entity.lastEnriched,
                mentionCount: entity.mentionCount,
                sessionMentions: entity.sessionMentions,
                stalenessScore: entity.stalenessScore,
                createdAt: entity.createdAt,
                modifiedAt: Date()
            )
            _ = store.upsertEntity(updated, authorship: authorship)

            // 2. Sync to .md — only when a parsed KBContent exists (entity was previously enriched)
            if let layer, let orig = original {
                let newContent = KBContent(
                    frontmatter: KBFrontmatter(
                        entityType: orig.frontmatter.entityType,
                        sourcePath: orig.frontmatter.sourcePath,
                        lastEnriched: Date(),
                        mentionCount: orig.frontmatter.mentionCount
                    ),
                    entityName: orig.entityName,
                    compiledUnderstanding: understanding,
                    relations: orig.relations,
                    evidence: orig.evidence,
                    decisions: orig.decisions
                )
                try? layer.writeEntity(name: orig.entityName, content: newContent)
            }

            await MainActor.run {
                self?.isDirty = false
                self?.isSaving = false
            }
        }
    }

    /// Accept the staged proposal: commit it, record evidence, reload detail.
    func acceptProposal() {
        guard let entity = selectedEntity, let layer = KBReader.layer else { return }
        let store = KBReader.store
        let entityId = entity.id
        let name = entity.name
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try layer.commitProposal(for: name)
                _ = store.appendEvidence(EvidenceEntry(
                    entityId: entityId,
                    sessionId: "app",
                    whatWasLearned: "Understanding accepted from enrichment proposal",
                    source: "enrichment"
                ))
            } catch {}
            // Reload detail
            let links = store.links(fromEntityId: entityId)
            let decisions = store.decisions(forEntityName: name)
            let couplings = store.couplings(forEntityName: name)
            let understanding: String
            if let (content, _) = try? layer.readEntity(name: name) {
                understanding = content.compiledUnderstanding
            } else {
                understanding = store.entity(named: name)?.compiledUnderstanding ?? ""
            }
            await MainActor.run {
                guard let self else { return }
                self.stagedProposal = nil
                self.understandingText = understanding
                self.detailLinks = links
                self.detailDecisions = decisions
                self.detailCouplings = couplings
                self.isDirty = false
            }
        }
    }

    /// Discard the staged proposal without touching the live file.
    func discardProposal() {
        guard let entity = selectedEntity, let layer = KBReader.layer else { return }
        let name = entity.name
        Task.detached(priority: .userInitiated) { [weak self] in
            try? layer.discardStagedProposal(for: name)
            await MainActor.run { self?.stagedProposal = nil }
        }
    }

    // MARK: - Wiki-link completion (logic in MCPServer/GraphLayout.swift)

    func updateCompletion(_ text: String) {
        guard let query = WikiLinkHelpers.extractWikiLinkQuery(text) else {
            if !completionCandidates.isEmpty { completionCandidates = [] }
            return
        }
        let q = query.lowercased()
        completionCandidates = entities
            .map(\.name)
            .filter { q.isEmpty || $0.lowercased().hasPrefix(q) }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Relations graph

    /// Kick off graph layout computation in background for the 1-hop neighborhood of entity.
    func loadGraph(for entity: KnowledgeEntity) {
        isLoadingGraph = true
        graphNodes = []
        graphEdges = []
        let store = KBReader.store
        let entityId = entity.id
        let entityName = entity.name
        let entityType = entity.entityType

        Task.detached(priority: .userInitiated) { [weak self] in
            let outLinks = store.links(fromEntityId: entityId)
            let backLinks = store.backlinks(toEntityName: entityName)

            // Build node set: root + 1-hop neighborhood
            var nodeMap: [String: GraphNode] = [:]
            nodeMap[entityName] = GraphNode(id: entityId, name: entityName,
                                            entityType: entityType, isRoot: true)
            for link in outLinks where nodeMap[link.targetName] == nil {
                let e = store.entity(named: link.targetName)
                nodeMap[link.targetName] = GraphNode(
                    id: e?.id ?? -1, name: link.targetName,
                    entityType: e?.entityType ?? "unknown", isRoot: false
                )
            }
            for link in backLinks {
                if let src = store.entity(id: link.sourceId), nodeMap[src.name] == nil {
                    nodeMap[src.name] = GraphNode(
                        id: src.id, name: src.name,
                        entityType: src.entityType, isRoot: false
                    )
                }
            }

            // Build edge list (outgoing + backlinks)
            var edges: [GraphEdge] = []
            for link in outLinks where nodeMap[link.targetName] != nil {
                edges.append(GraphEdge(sourceId: entityId, targetName: link.targetName,
                                       relation: link.relation))
            }
            for link in backLinks {
                if let src = store.entity(id: link.sourceId) {
                    edges.append(GraphEdge(sourceId: src.id, targetName: entityName,
                                           relation: link.relation))
                }
            }

            // Initial positions: root at center, partners on ellipse
            var nodesList = Array(nodeMap.values)
            let cx = CGFloat(250), cy = CGFloat(200)
            let nonRootCount = max(1, nodesList.filter { !$0.isRoot }.count)
            var nonRootIdx = 0
            for i in 0..<nodesList.count {
                if nodesList[i].isRoot {
                    nodesList[i].position = CGPoint(x: cx, y: cy)
                } else {
                    let angle = (CGFloat(nonRootIdx) / CGFloat(nonRootCount)) * 2 * .pi - .pi / 2
                    nodesList[i].position = CGPoint(x: cx + 130 * cos(angle),
                                                    y: cy + 110 * sin(angle))
                    nonRootIdx += 1
                }
            }

            let finalNodes = springLayout(
                nodes: nodesList, edges: edges,
                size: CGSize(width: 500, height: 400)
            )

            await MainActor.run {
                guard let self else { return }
                self.graphNodes = finalNodes
                self.graphEdges = edges
                self.isLoadingGraph = false
            }
        }
    }

}
// springLayout free function is in MCPServer/GraphLayout.swift
