import ArgumentParser
import Foundation
import Core

// MARK: - Root KB command (status when no subcommand given)

struct KB: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kb",
        abstract: "Query the Senkani knowledge base.",
        subcommands: [KBList.self, KBGet.self, KBSearch.self, KBRollback.self, KBHistory.self, KBTimeline.self]
    )

    @Option(name: .long, help: "Project root directory.")
    var root: String?

    func run() throws {
        guard let projectRoot = resolveKBRoot(root) else {
            fputs("No Senkani KB found. Has the MCP server run in this project?\n", stderr)
            throw ExitCode(2)
        }
        let store = KnowledgeStore(projectRoot: projectRoot)
        let entities = store.allEntities()
        let enriched = entities.filter { $0.lastEnriched != nil }.count

        print("Knowledge Base: \(projectRoot)")
        print("  Entities : \(entities.count)")
        print("  Enriched : \(enriched)")

        let activity = SessionDatabase.shared.lastSessionActivity(projectRoot: projectRoot)
        if let a = activity {
            let mins = Int(a.durationSeconds / 60)
            let savings = a.totalRawTokens > 0
                ? Int(Double(a.totalSavedTokens) / Double(a.totalRawTokens) * 100)
                : 0
            print("")
            print("Last session: \(mins > 0 ? "\(mins)m" : "<1m") · \(a.commandCount) calls · \(savings)% savings")
            let filenames = a.topHotFiles.prefix(3).map { ($0 as NSString).lastPathComponent }
            if !filenames.isEmpty {
                print("  Hot files: \(filenames.joined(separator: ", "))")
            }
        }
    }
}

// MARK: - list

struct KBList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List knowledge base entities."
    )

    @Option(name: .long, help: "Sort: mentions (default), name, staleness, recent.")
    var sort: String = "mentions"

    @Option(name: .long, help: "Filter by entity type (class, struct, func, file).")
    var type: String?

    @Option(name: .long, help: "Maximum results (default 30).")
    var limit: Int = 30

    @Option(name: .long, help: "Project root directory.")
    var root: String?

    func run() throws {
        guard let projectRoot = resolveKBRoot(root) else {
            fputs("No Senkani KB found.\n", stderr)
            throw ExitCode(2)
        }
        let store = KnowledgeStore(projectRoot: projectRoot)
        let sortMode: EntitySort = {
            switch sort {
            case "name":      return .nameAsc
            case "staleness": return .stalenessDesc
            case "recent":    return .lastEnrichedDesc
            default:          return .mentionCountDesc
            }
        }()
        var entities = store.allEntities(sortedBy: sortMode)
        if let t = type { entities = entities.filter { $0.entityType == t } }
        let display = Array(entities.prefix(limit))

        print("\(display.count) of \(entities.count) entities (sort: \(sort))\n")
        for e in display {
            let mark     = e.lastEnriched != nil ? "●" : "○"
            let mentStr  = String(e.mentionCount).padding(toLength: 4, withPad: " ", startingAt: 0)
            let typeStr  = e.entityType.padding(toLength: 8, withPad: " ", startingAt: 0)
            print("  \(mark) \(mentStr) \(typeStr) \(e.name)")
        }
    }
}

// MARK: - get

struct KBGet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get entity detail from the knowledge base."
    )

    @Argument(help: "Entity name (exact match).")
    var entity: String

    @Option(name: .long, help: "Project root directory.")
    var root: String?

    func run() throws {
        guard let projectRoot = resolveKBRoot(root) else {
            fputs("No Senkani KB found.\n", stderr)
            throw ExitCode(2)
        }
        let store = KnowledgeStore(projectRoot: projectRoot)
        guard let e = store.entity(named: entity) else {
            fputs("Entity '\(entity)' not found.\n", stderr)
            throw ExitCode(1)
        }

        print("Entity: \(e.name) (\(e.entityType))")
        print("  Mentions : \(e.mentionCount)")
        if let sp = e.sourcePath   { print("  Source   : \(sp)") }
        if let le = e.lastEnriched { print("  Enriched : \(kbShortDate(le))") }

        if !e.compiledUnderstanding.isEmpty {
            print("\nUNDERSTANDING\n\(e.compiledUnderstanding)")
        }

        let links = store.links(fromEntityId: e.id)
        if !links.isEmpty {
            print("\nRELATIONS (\(links.count))")
            for l in links {
                print("  → \(l.relation ?? "related_to"): \(l.targetName)")
            }
        }

        let decisions = store.decisions(forEntityName: e.name)
        if !decisions.isEmpty {
            print("\nDECISIONS (\(decisions.count))")
            for d in decisions.prefix(5) {
                print("  [\(kbShortDate(d.createdAt))] \(d.decision)")
            }
        }
    }
}

// MARK: - search

struct KBSearch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Full-text search the knowledge base."
    )

    @Argument(help: "Search query.")
    var query: String

    @Option(name: .long, help: "Maximum results (default 5).")
    var limit: Int = 5

    @Option(name: .long, help: "Project root directory.")
    var root: String?

    func run() throws {
        guard let projectRoot = resolveKBRoot(root) else {
            fputs("No Senkani KB found.\n", stderr)
            throw ExitCode(2)
        }
        let store = KnowledgeStore(projectRoot: projectRoot)
        let results = store.search(query: query, limit: limit)

        guard !results.isEmpty else {
            print("No results for '\(query)'")
            return
        }

        print("\(results.count) result(s) for '\(query)'\n")
        for r in results {
            print("  \(r.entity.name) (\(r.entity.entityType))")
            if !r.snippet.isEmpty {
                print("    \(r.snippet)")
            }
        }
    }
}

// MARK: - kb rollback (F+3 Round 6)

struct KBRollback: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Restore an entity's markdown from history archive."
    )

    @Argument(help: "Entity name (matches .senkani/knowledge/<name>.md).")
    var entity: String

    @Option(name: .long, help: "Target ISO date (YYYY-MM-DD). Defaults to most recent archive before today.")
    var to: String?

    @Option(name: .long, help: "Project root directory.")
    var root: String?

    func run() throws {
        guard let projectRoot = resolveKBRoot(root) else {
            fputs("No Senkani KB found.\n", stderr)
            throw ExitCode(2)
        }
        let target: Date
        if let dateStr = to {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "UTC")
            guard let d = fmt.date(from: dateStr) else {
                fputs("Invalid --to date: '\(dateStr)'. Expected YYYY-MM-DD.\n", stderr)
                throw ExitCode(2)
            }
            target = d
        } else {
            target = Date()
        }

        let store = KnowledgeStore(projectRoot: projectRoot)
        let fileLayer: KnowledgeFileLayer
        do {
            fileLayer = try KnowledgeFileLayer(projectRoot: projectRoot, store: store)
        } catch {
            fputs("KnowledgeFileLayer init failed: \(error.localizedDescription)\n", stderr)
            throw ExitCode(1)
        }
        do {
            try fileLayer.rollback(entityName: entity, to: target)
            print("Rolled back `\(entity)` to archive closest to \(target).")
        } catch {
            fputs("Rollback failed: \(error.localizedDescription)\n", stderr)
            throw ExitCode(1)
        }
    }
}

// MARK: - kb history (F+3 Round 6)

struct KBHistory: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "List archived revisions of an entity's markdown."
    )

    @Argument(help: "Entity name.")
    var entity: String

    @Option(name: .long, help: "Project root directory.")
    var root: String?

    func run() throws {
        guard let projectRoot = resolveKBRoot(root) else {
            fputs("No Senkani KB found.\n", stderr)
            throw ExitCode(2)
        }
        let historyDir = projectRoot + "/.senkani/knowledge/.history/" + entity
        guard FileManager.default.fileExists(atPath: historyDir) else {
            print("No history archive for `\(entity)`.")
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: historyDir)) ?? []
        let mdFiles = files.filter { $0.hasSuffix(".md") }.sorted()
        if mdFiles.isEmpty {
            print("Archive exists but is empty.")
            return
        }
        print("History for `\(entity)` (\(mdFiles.count) revision(s)):")
        for f in mdFiles {
            print("  \(f)")
        }
        print("")
        print("Roll back to a specific revision:")
        print("  senkani kb rollback \(entity) --to YYYY-MM-DD")
    }
}

// MARK: - kb timeline (F+4 Round 7)

struct KBTimeline: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "timeline",
        abstract: "Show the append-only evidence timeline for an entity."
    )

    @Argument(help: "Entity name.") var entity: String
    @Option(name: .long, help: "Project root directory.") var root: String?

    func run() throws {
        guard let projectRoot = resolveKBRoot(root) else {
            fputs("No Senkani KB found.\n", stderr)
            throw ExitCode(2)
        }
        let store = KnowledgeStore(projectRoot: projectRoot)
        guard let e = store.entity(named: entity) else {
            fputs("No entity named `\(entity)`.\n", stderr)
            throw ExitCode(1)
        }
        let timeline = store.timeline(forEntityId: e.id)
        if timeline.isEmpty {
            print("Evidence timeline for `\(entity)` is empty.")
            return
        }
        print("Evidence timeline for `\(entity)` (\(timeline.count) entries):")
        for entry in timeline {
            print("  [\(kbShortDate(entry.createdAt))] \(entry.whatWasLearned)")
            if !entry.source.isEmpty {
                print("         source: \(entry.source)")
            }
        }
    }
}

// MARK: - Shared helpers (file-private to avoid collision with other CLI helpers)

private func resolveKBRoot(_ explicit: String?) -> String? {
    let root = explicit ?? FileManager.default.currentDirectoryPath
    let dbPath = root + "/.senkani/knowledge.db"
    guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
    return root
}

private func kbShortDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: date)
}
