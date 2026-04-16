import Foundation
import MCP
import Core

// MARK: - KnowledgeTool

/// senkani_knowledge — query the project knowledge base.
///
/// All actions are read-only in F.3. Write actions (propose, validate, commit) are F.7.
/// Output: structured plain text — token-efficient, readable by Claude as context.
enum KnowledgeTool {

    // Date-only formatter (UTC) — mirrors KnowledgeParser.isoDate which is internal to Core
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        let action = arguments?["action"]?.stringValue ?? "status"
        switch action {
        case "status":  return handleStatus(session)
        case "get":     return handleGet(arguments, session)
        case "search":  return handleSearch(arguments, session)
        case "list":    return handleList(arguments, session)
        case "relate":  return handleRelate(arguments, session)
        case "mine":    return handleMine(session)
        case "propose": return handlePropose(arguments, session)
        case "commit":  return handleCommit(arguments, session)
        case "discard": return handleDiscard(arguments, session)
        case "graph":   return handleGraph(arguments, session)
        default:
            return .init(
                content: [.text(text: "Unknown action '\(action)'. Use: status|get|search|list|relate|mine|propose|commit|discard|graph",
                                annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    // MARK: - status

    private static func handleStatus(_ session: MCPSession) -> CallTool.Result {
        let store = session.knowledgeStore
        let tracker = session.entityTracker
        let entities = store.allEntities()
        let state = tracker.state()
        let candidates = tracker.consumeEnrichmentCandidates()

        var lines = ["Knowledge Base Status"]
        lines.append("  Entities: \(entities.count)")
        let totalSessionMentions = state.sessionTotal.values.reduce(0, +)
        lines.append("  Session mentions tracked: \(totalSessionMentions)")
        if state.pendingDelta.isEmpty {
            lines.append("  Pending DB flush: none")
        } else {
            lines.append("  Pending DB flush: \(state.pendingDelta.count) entities")
        }
        if !candidates.isEmpty {
            lines.append("  Enrichment candidates: \(candidates.sorted().joined(separator: ", "))")
        }
        lines.append("  KB directory: \(session.projectRoot)/.senkani/knowledge/")
        if let layer = session.knowledgeLayer {
            let mdFiles = (try? FileManager.default.contentsOfDirectory(atPath: layer.knowledgeDir))
                ?? []
            lines.append("  KB files: \(mdFiles.filter { $0.hasSuffix(".md") }.count) markdown file(s)")
        }
        return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    // MARK: - get

    private static func handleGet(_ arguments: [String: Value]?, _ session: MCPSession) -> CallTool.Result {
        guard let entityName = arguments?["entity"]?.stringValue, !entityName.isEmpty else {
            return .init(
                content: [.text(text: "Error: 'entity' argument required for action 'get'",
                                annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let store = session.knowledgeStore
        guard let entity = store.entity(named: entityName) else {
            return .init(
                content: [.text(text: "Entity '\(entityName)' not found in knowledge base.\n"
                                + "Use knowledge(action:'list') to see known entities.",
                                annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // P2-10: canonical `full: bool` read. Any legacy `detail:"full"` was translated
        // upstream by ArgumentShim.normalize in ToolRouter before this handler ran.
        let full = arguments?["full"]?.boolValue ?? false

        // Understanding — from DB field or from FS if richer
        let understanding: String
        if !entity.compiledUnderstanding.isEmpty {
            understanding = entity.compiledUnderstanding
        } else if let layer = session.knowledgeLayer,
                  let (content, _) = try? layer.readEntity(name: entity.name) {
            understanding = content.compiledUnderstanding
        } else {
            understanding = ""
        }

        let outLinks  = store.links(fromEntityId: entity.id)
        let timeline  = store.timeline(forEntityId: entity.id)
        let decisions = store.decisions(forEntityName: entity.name)

        let isStaged = (session.knowledgeLayer?.readStagedProposal(for: entity.name) != nil)

        var lines: [String] = []

        if full {
            // Full mode: original behaviour + decisions capped at 10
            lines.append("\(entity.name) — \(entity.entityType)")
            var meta: [String] = []
            if let sp = entity.sourcePath { meta.append("Source: \(sp)") }
            meta.append("Mentions: \(entity.mentionCount)")
            if let le = entity.lastEnriched {
                meta.append("Last enriched: \(dateFormatter.string(from:le))")
            }
            if isStaged { meta.append("⚑ STAGED") }
            if !meta.isEmpty { lines.append(meta.joined(separator: " | ")) }
            lines.append("")

            lines.append("Understanding:")
            if understanding.isEmpty {
                lines.append("  (not yet enriched)")
            } else {
                for line in understanding.components(separatedBy: "\n") {
                    lines.append("  \(line)")
                }
            }
            lines.append("")

            if !outLinks.isEmpty {
                lines.append("Relations (\(outLinks.count)):")
                for link in outLinks {
                    if let rt = link.relation {
                        lines.append("  → \(rt): \(link.targetName)")
                    } else {
                        lines.append("  → \(link.targetName)")
                    }
                }
                lines.append("")
            }

            if !timeline.isEmpty {
                lines.append("Evidence (\(timeline.count) entries):")
                for ev in timeline.prefix(5) {
                    let d = dateFormatter.string(from:ev.createdAt)
                    lines.append("  \(d) [\(ev.sessionId)]: \(ev.whatWasLearned)")
                }
                if timeline.count > 5 { lines.append("  ... and \(timeline.count - 5) more") }
                lines.append("")
            }

            if !decisions.isEmpty {
                let cap = 10
                lines.append("Decisions (\(decisions.count)):")
                for dec in decisions.prefix(cap) {
                    let d = dateFormatter.string(from:dec.createdAt)
                    if dec.rationale.isEmpty {
                        lines.append("  \(d): \(dec.decision)")
                    } else {
                        lines.append("  \(d): \(dec.decision) because \(dec.rationale)")
                    }
                }
                if decisions.count > cap { lines.append("  ... and \(decisions.count - cap) more") }
            }
        } else {
            // Summary mode: header + counts + 120-char understanding preview
            var header = "\(entity.name) — \(entity.entityType)  ·  \(entity.mentionCount) mention\(entity.mentionCount == 1 ? "" : "s")"
            if let le = entity.lastEnriched {
                header += "  ·  enriched: \(dateFormatter.string(from:le))"
            }
            if isStaged { header += "  ·  ⚑ STAGED" }
            lines.append(header)

            var counts: [String] = []
            if !outLinks.isEmpty  { counts.append("Relations: \(outLinks.count)") }
            if !timeline.isEmpty  { counts.append("Evidence: \(timeline.count)") }
            if !decisions.isEmpty { counts.append("Decisions: \(decisions.count)") }
            if !counts.isEmpty { lines.append("  " + counts.joined(separator: "  ·  ")) }

            if !understanding.isEmpty {
                let preview = understanding.count > 120
                    ? String(understanding.prefix(120)) + "…"
                    : understanding
                lines.append("  Understanding: \"\(preview)\"")
            } else {
                lines.append("  Understanding: (not yet enriched)")
            }

            lines.append("")
            lines.append("Use knowledge(action:'get', entity:'\(entity.name)', full:true) for complete output.")
        }

        return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    // MARK: - search

    private static func handleSearch(_ arguments: [String: Value]?, _ session: MCPSession) -> CallTool.Result {
        guard let query = arguments?["query"]?.stringValue, !query.isEmpty else {
            return .init(
                content: [.text(text: "Error: 'query' argument required for action 'search'",
                                annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let results = session.knowledgeStore.search(query: query, limit: 5)
        if results.isEmpty {
            return .init(content: [.text(text: "Knowledge search: \"\(query)\"\n\nNo results found.",
                                         annotations: nil, _meta: nil)])
        }

        var lines = ["Knowledge search: \"\(query)\" (\(results.count) result\(results.count == 1 ? "" : "s"))"]
        lines.append("")
        for (i, r) in results.enumerated() {
            lines.append("\(i + 1). \(r.entity.name) — \(r.entity.entityType) (score: \(String(format: "%.2f", r.bm25Rank)))")
            lines.append("   \(r.snippet)")
            if i < results.count - 1 { lines.append("") }
        }

        return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    // MARK: - list

    private static func handleList(_ arguments: [String: Value]?, _ session: MCPSession) -> CallTool.Result {
        let sortArg = arguments?["sort"]?.stringValue ?? "mentions"
        let sort: EntitySort
        switch sortArg {
        case "name":      sort = .nameAsc
        case "staleness": sort = .stalenessDesc
        case "recent":    sort = .lastEnrichedDesc
        default:          sort = .mentionCountDesc
        }

        let all = session.knowledgeStore.allEntities(sortedBy: sort)
        let page = Array(all.prefix(20))

        if all.isEmpty {
            return .init(content: [.text(text: "Knowledge Base — 0 entities\n\nNo entities yet.",
                                         annotations: nil, _meta: nil)])
        }

        var lines = ["Knowledge Base — \(all.count) entit\(all.count == 1 ? "y" : "ies") (sorted by \(sortArg))"]
        lines.append("")
        // Column header
        lines.append(String(format: "  %-28@ %-10@ %8@  %@", "Name", "Type", "Mentions", "Last Enriched"))
        lines.append("  " + String(repeating: "-", count: 60))
        for e in page {
            let enriched = e.lastEnriched.map { dateFormatter.string(from:$0) } ?? "—"
            let mentionsStr = String(e.mentionCount)
            lines.append(String(format: "  %-28@ %-10@ %8@  %@",
                                truncate(e.name, 28),
                                truncate(e.entityType, 10),
                                mentionsStr,
                                enriched))
        }
        if all.count > 20 {
            lines.append("  ... and \(all.count - 20) more (use sort:'name' or other options)")
        }

        return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    // MARK: - mine

    private static func handleMine(_ session: MCPSession) -> CallTool.Result {
        guard FileManager.default.fileExists(atPath: session.projectRoot + "/.git") else {
            return .init(content: [.text(text: "Not a git repository — coupling mining requires git.",
                                         annotations: nil, _meta: nil)], isError: true)
        }
        let (pairs, commits) = ChangeSetMiner.mine(
            projectRoot: session.projectRoot,
            store: session.knowledgeStore
        )
        let msg = commits == 0
            ? "No commits found. Ensure entities have sourcePaths set (run enrichment first)."
            : "Mined \(pairs) coupling pair(s) from \(commits) commit(s)."
        return .init(content: [.text(text: msg, annotations: nil, _meta: nil)], isError: false)
    }

    // MARK: - relate

    private static func handleRelate(_ arguments: [String: Value]?, _ session: MCPSession) -> CallTool.Result {
        guard let entityName = arguments?["entity"]?.stringValue, !entityName.isEmpty else {
            return .init(
                content: [.text(text: "Error: 'entity' argument required for action 'relate'",
                                annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let store = session.knowledgeStore
        guard let entity = store.entity(named: entityName) else {
            return .init(
                content: [.text(text: "Entity '\(entityName)' not found in knowledge base.",
                                annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let outLinks = store.links(fromEntityId: entity.id)

        if outLinks.isEmpty {
            return .init(content: [.text(text: "\(entityName) — no relations recorded.",
                                         annotations: nil, _meta: nil)])
        }

        var lines = ["\(entityName) — relations (\(outLinks.count))"]
        lines.append("")
        for link in outLinks {
            let rt = link.relation ?? "related_to"
            let resolved = link.targetId != nil ? "" : " (unresolved)"
            lines.append("  → \(rt): \(link.targetName)\(resolved)")
        }

        return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    // MARK: - propose

    private static func handlePropose(
        _ arguments: [String: Value]?,
        _ session: MCPSession
    ) -> CallTool.Result {
        guard let entityName = arguments?["entity"]?.stringValue, !entityName.isEmpty else {
            return err("'entity' required for action 'propose'")
        }
        guard let layer = session.knowledgeLayer else {
            return err("No knowledge layer — project must have .senkani/knowledge/ directory")
        }
        let store = session.knowledgeStore
        guard let entity = store.entity(named: entityName) else {
            return err("Entity '\(entityName)' not found. Use knowledge(action:'list') to see known entities.")
        }

        // Without understanding: return rich context for Claude to compose enrichment
        guard let understanding = arguments?["understanding"]?.stringValue,
              !understanding.isEmpty else {
            return buildEnrichmentContext(entity: entity, session: session)
        }

        // With understanding: stage a proposal preserving existing relations/evidence/decisions
        do {
            let markdown: String
            if let (existing, _) = try? layer.readEntity(name: entity.name) {
                let updated = KBContent(
                    frontmatter: KBFrontmatter(
                        entityType: existing.frontmatter.entityType,
                        sourcePath: existing.frontmatter.sourcePath,
                        lastEnriched: Date(),
                        mentionCount: existing.frontmatter.mentionCount
                    ),
                    entityName: existing.entityName,
                    compiledUnderstanding: understanding,
                    relations: existing.relations,
                    evidence: existing.evidence,
                    decisions: existing.decisions
                )
                markdown = KnowledgeParser.serialize(updated, entityName: entity.name)
            } else {
                let fm = KBFrontmatter(
                    entityType: entity.entityType,
                    sourcePath: entity.sourcePath,
                    lastEnriched: Date(),
                    mentionCount: entity.mentionCount
                )
                markdown = KnowledgeParser.serialize(
                    KBContent(frontmatter: fm, entityName: entity.name,
                              compiledUnderstanding: understanding),
                    entityName: entity.name
                )
            }
            try layer.stageProposal(for: entity.name, content: markdown)
            return .init(content: [.text(
                text: "Staged proposal for '\(entity.name)'. "
                    + "Call knowledge(action:'commit', entity:'\(entity.name)') to apply "
                    + "or knowledge(action:'discard', entity:'\(entity.name)') to drop.",
                annotations: nil, _meta: nil
            )])
        } catch {
            return err("Failed to stage proposal: \(error)")
        }
    }

    // MARK: - commit

    private static func handleCommit(
        _ arguments: [String: Value]?,
        _ session: MCPSession
    ) -> CallTool.Result {
        guard let entityName = arguments?["entity"]?.stringValue, !entityName.isEmpty else {
            return err("'entity' required for action 'commit'")
        }
        guard let layer = session.knowledgeLayer else { return err("No knowledge layer") }
        let store = session.knowledgeStore
        guard let entity = store.entity(named: entityName) else {
            return err("Entity '\(entityName)' not found.")
        }
        do {
            try layer.commitProposal(for: entityName)
            _ = store.appendEvidence(EvidenceEntry(
                entityId: entity.id,
                sessionId: session.sessionId ?? "enrichment_tool",
                whatWasLearned: "Understanding enriched via proposal",
                source: "enrichment"
            ))
            return .init(content: [.text(
                text: "Committed proposal for '\(entityName)'. Understanding updated and evidence recorded.",
                annotations: nil, _meta: nil
            )])
        } catch {
            return err("Failed to commit: \(error)")
        }
    }

    // MARK: - discard

    private static func handleDiscard(
        _ arguments: [String: Value]?,
        _ session: MCPSession
    ) -> CallTool.Result {
        guard let entityName = arguments?["entity"]?.stringValue, !entityName.isEmpty else {
            return err("'entity' required for action 'discard'")
        }
        guard let layer = session.knowledgeLayer else { return err("No knowledge layer") }
        do {
            try layer.discardStagedProposal(for: entityName)
            return .init(content: [.text(
                text: "Discarded proposal for '\(entityName)'.",
                annotations: nil, _meta: nil
            )])
        } catch {
            return err("Failed to discard: \(error)")
        }
    }

    // MARK: - graph

    private static func handleGraph(
        _ arguments: [String: Value]?,
        _ session: MCPSession
    ) -> CallTool.Result {
        guard let entityName = arguments?["entity"]?.stringValue, !entityName.isEmpty else {
            return err("'entity' required for action 'graph'")
        }
        let store = session.knowledgeStore
        guard let entity = store.entity(named: entityName) else {
            return err("Entity '\(entityName)' not found.")
        }

        let outLinks = store.links(fromEntityId: entity.id)
        let backLinks = store.backlinks(toEntityName: entity.name)

        if outLinks.isEmpty && backLinks.isEmpty {
            return .init(content: [.text(
                text: "Relations graph: \(entityName)\n\nNo relations recorded.\n"
                    + "Add [[EntityName]] wiki-links to the understanding to create relations.",
                annotations: nil, _meta: nil
            )])
        }

        var lines = ["Relations graph: \(entityName) (\(entity.entityType))"]
        lines.append("")

        if !outLinks.isEmpty {
            lines.append("Outgoing (\(outLinks.count)):")
            for l in outLinks {
                let rt = l.relation ?? "related_to"
                let res = l.targetId != nil ? "" : " (unresolved)"
                lines.append("  → \(rt): \(l.targetName)\(res)")
            }
        }

        if !backLinks.isEmpty {
            if !outLinks.isEmpty { lines.append("") }
            lines.append("Incoming (\(backLinks.count)):")
            for l in backLinks {
                let rt = l.relation ?? "related_to"
                let src = store.entity(id: l.sourceId)?.name ?? "(id:\(l.sourceId))"
                lines.append("  ← \(rt): \(src)")
            }
        }

        return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    // MARK: - Enrichment context builder

    private static func buildEnrichmentContext(
        entity: KnowledgeEntity,
        session: MCPSession
    ) -> CallTool.Result {
        let store = session.knowledgeStore
        var lines = ["Enrichment context: \(entity.name) (\(entity.entityType))"]
        lines.append("")

        let current = entity.compiledUnderstanding.isEmpty
            ? "(not yet enriched)"
            : entity.compiledUnderstanding
        lines.append("Current understanding:")
        lines.append(current)
        lines.append("")

        if let sp = entity.sourcePath { lines.append("Source: \(sp)") }
        lines.append("Mentions: \(entity.mentionCount)")
        lines.append("")

        let links = store.links(fromEntityId: entity.id)
        if !links.isEmpty {
            lines.append("Relations:")
            for l in links { lines.append("  → \(l.relation ?? "related_to"): \(l.targetName)") }
            lines.append("")
        }

        let couplings = store.couplings(forEntityName: entity.name, minScore: 0.05)
        if !couplings.isEmpty {
            lines.append("Co-changes (git coupling):")
            for c in couplings.prefix(5) {
                let partner = c.entityA == entity.name ? c.entityB : c.entityA
                lines.append("  \(partner): \(Int(c.couplingScore * 100))% (\(c.commitCount)/\(c.totalCommits))")
            }
            lines.append("")
        }

        let timeline = store.timeline(forEntityId: entity.id)
        if !timeline.isEmpty {
            lines.append("Recent evidence:")
            for ev in timeline.prefix(3) { lines.append("  [\(ev.sessionId)]: \(ev.whatWasLearned)") }
            lines.append("")
        }

        lines.append("To propose enrichment, call:")
        lines.append("  knowledge(action:'propose', entity:'\(entity.name)', understanding:'<your enrichment>')")

        return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    // MARK: - Error helper

    private static func err(_ msg: String) -> CallTool.Result {
        .init(content: [.text(text: "Error: \(msg)", annotations: nil, _meta: nil)], isError: true)
    }

    // MARK: - Helpers

    private static func truncate(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max - 1)) + "…"
    }
}
