import Foundation
import MCP
import Indexer

enum SearchTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) async -> CallTool.Result {
        guard let query = arguments?["query"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'query' is required", annotations: nil, _meta: nil)], isError: true)
        }

        let kindStr = arguments?["kind"]?.stringValue
        let kind: SymbolKind? = kindStr.flatMap { SymbolKind(rawValue: $0) }
        let file = arguments?["file"]?.stringValue
        let container = arguments?["container"]?.stringValue

        // 1. Try BM25 search via FTS5 store (ranked, preferred path)
        let fts = SymbolFTSStore(projectRoot: session.projectRoot)
        let bm25Results = (try? fts.search(query: query, kind: kind, file: file,
                                           container: container, limit: 50)) ?? []

        let ranked: [RankedEntry]

        if !bm25Results.isEmpty {
            // 2. Optionally fuse with file-level embedding scores (non-blocking — empty if model not warm)
            let fileScores = await EmbedTool.engine.cachedFileRanks(query: query, topK: 20)
            ranked = RRFRanker.fuse(bm25Results: bm25Results, fileScores: fileScores)
        } else {
            // 3. Fallback: substring match when FTS not yet populated
            guard let index = session.indexIfReady() else {
                return .init(content: [.text(text: "Symbol index is building (first run). Try again in a few seconds.", annotations: nil, _meta: nil)])
            }
            let fallback = index.search(name: query, kind: kind, file: file, container: container)
            ranked = fallback.enumerated().map { RankedEntry(entry: $1, rrfScore: 0, bm25Rank: $0 + 1) }
        }

        // Track queried files for staleness detection
        for r in ranked.prefix(30) {
            session.trackQueriedSymbol(file: r.entry.file)
        }

        guard !ranked.isEmpty else {
            return .init(content: [.text(text: "No symbols matching \"\(query)\"", annotations: nil, _meta: nil)])
        }

        let usingRRF = !bm25Results.isEmpty
        let modeTag = usingRRF ? "BM25" : "substring"
        var lines: [String] = ["Found \(ranked.count) symbol(s) matching \"\(query)\" [\(modeTag)]:\n"]
        for (i, r) in ranked.prefix(30).enumerated() {
            let entry = r.entry
            let kindPad = String(describing: entry.kind).padding(toLength: 10, withPad: " ", startingAt: 0)
            let loc = "\(entry.file):\(entry.startLine)"
            let cont = entry.container.map { " (\($0))" } ?? ""
            lines.append("  \(i+1). \(entry.name.padding(toLength: 24, withPad: " ", startingAt: 0))\(kindPad) \(loc)\(cont)")
        }
        if ranked.count > 30 { lines.append("  ... and \(ranked.count - 30) more") }
        lines.append("\nUse senkani_fetch to read a symbol's source.")

        session.recordMetrics(rawBytes: ranked.count * 500, compressedBytes: lines.joined().utf8.count,
                              feature: "search", command: query,
                              outputPreview: String(lines.joined(separator: "\n").prefix(200)))

        return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }
}
