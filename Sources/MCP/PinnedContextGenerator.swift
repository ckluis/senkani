import Foundation
import Core
import Indexer

/// Generates compressed ≤80-token outlines for @-mention pinning.
///
/// Fallback chain:
///   1. KnowledgeStore.entity(named:) — uses compiled understanding
///   2. SymbolIndex.find(name:) — exact symbol match, file context
///   3. SymbolFTSStore BM25 search — top-3 approximate matches
///
/// Returns nil when nothing is found (caller should report "not found" error).
enum PinnedContextGenerator {

    /// Generate a compressed outline for `name`. Synchronous — all lookups are
    /// in-memory or local SQLite (<1ms). Safe to call from any thread.
    static func generate(name: String, session: MCPSession) -> String? {
        // 1. Knowledge Store — richest source if entity has been enriched
        if let entity = session.knowledgeStore.entity(named: name) {
            let summary = formatKBEntity(entity)
            if !summary.isEmpty {
                return String(summary.prefix(PinnedContextStore.maxEntryChars))
            }
        }

        // 2. Symbol Index exact match
        if let index = session.indexIfReady(), let entry = index.find(name: name) {
            let summary = formatSymbolEntry(entry, index: index)
            if !summary.isEmpty {
                return String(summary.prefix(PinnedContextStore.maxEntryChars))
            }
        }

        // 3. BM25 FTS prefix search — top 3 approximate results
        let fts = SymbolFTSStore(projectRoot: session.projectRoot)
        if let results = try? fts.search(query: name, limit: 3), !results.isEmpty {
            let formatted = formatFTSResults(results, name: name)
            return String(formatted.prefix(PinnedContextStore.maxEntryChars))
        }

        return nil
    }

    /// Return the closest BM25 match for a name — used for typo suggestions.
    /// Returns nil when the top match IS the input (exact match case).
    static func nearestMatch(name: String, session: MCPSession) -> String? {
        let fts = SymbolFTSStore(projectRoot: session.projectRoot)
        guard let results = try? fts.search(query: name, limit: 1),
              let top = results.first,
              top.entry.name.lowercased() != name.lowercased() else { return nil }
        return top.entry.name
    }

    // MARK: - Private Formatters

    private static func formatKBEntity(_ entity: KnowledgeEntity) -> String {
        var lines: [String] = ["\(entity.entityType) \(entity.name)"]
        if let path = entity.sourcePath {
            lines.append("  // \(path)")
        }
        // Use first paragraph of compiledUnderstanding as brief
        if !entity.compiledUnderstanding.isEmpty {
            let brief = entity.compiledUnderstanding
                .components(separatedBy: "\n\n")
                .first?
                .components(separatedBy: "\n")
                .prefix(3)
                .joined(separator: "\n  ") ?? ""
            if !brief.isEmpty { lines.append("  \(brief)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func formatSymbolEntry(_ entry: IndexEntry, index: SymbolIndex) -> String {
        var lines: [String] = ["\(entry.kind) \(entry.name) — \(entry.file):\(entry.startLine)"]
        if let sig = entry.signature { lines.append("  \(sig)") }

        // Up to 5 siblings in the same file (excluding the named symbol itself)
        let siblings = index.search(file: entry.file)
            .filter { $0.name != entry.name }
        for s in siblings.prefix(5) {
            let cont = s.container.map { "(\($0)) " } ?? ""
            lines.append("  \(s.kind) \(s.name) \(cont)L\(s.startLine)")
        }
        if siblings.count > 5 {
            lines.append("  [+\(siblings.count - 5) more]")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatFTSResults(
        _ results: [(entry: IndexEntry, bm25Rank: Int)],
        name: String
    ) -> String {
        var lines: [String] = ["// '\(name)' — closest matches:"]
        for r in results {
            let cont = r.entry.container.map { " (\($0))" } ?? ""
            lines.append(
                "  \(r.entry.kind) \(r.entry.name) — \(r.entry.file):\(r.entry.startLine)\(cont)"
            )
        }
        return lines.joined(separator: "\n")
    }
}
