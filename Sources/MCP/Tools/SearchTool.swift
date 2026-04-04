import Foundation
import MCP
import Indexer

enum SearchTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let query = arguments?["query"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'query' is required", annotations: nil, _meta: nil)], isError: true)
        }

        let index = session.ensureIndex()

        let kindStr = arguments?["kind"]?.stringValue
        let kind: SymbolKind? = kindStr.flatMap { SymbolKind(rawValue: $0) }
        let file = arguments?["file"]?.stringValue
        let container = arguments?["container"]?.stringValue

        let results = index.search(name: query, kind: kind, file: file, container: container)

        guard !results.isEmpty else {
            return .init(content: [.text(text: "No symbols matching \"\(query)\"", annotations: nil, _meta: nil)])
        }

        var lines: [String] = ["Found \(results.count) symbol(s) matching \"\(query)\":\n"]
        for (i, entry) in results.prefix(30).enumerated() {
            let kindStr = String(describing: entry.kind).padding(toLength: 10, withPad: " ", startingAt: 0)
            let loc = "\(entry.file):\(entry.startLine)"
            let cont = entry.container.map { " (\($0))" } ?? ""
            lines.append("  \(i+1). \(entry.name.padding(toLength: 24, withPad: " ", startingAt: 0))\(kindStr) \(loc)\(cont)")
        }
        if results.count > 30 { lines.append("  ... and \(results.count - 30) more") }
        lines.append("\nUse senkani_fetch to read a symbol's source.")

        // Estimated savings: ~50 tokens for this list vs ~5000 for grepping files
        session.recordMetrics(rawBytes: results.count * 500, compressedBytes: lines.joined().utf8.count, feature: "search")

        return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }
}
