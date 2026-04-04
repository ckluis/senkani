import Foundation
import MCP
import Indexer

enum ExploreTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        let path = arguments?["path"]?.stringValue
        let index = session.ensureIndex()
        let grouped = index.groupedByFile(under: path)

        guard !grouped.isEmpty else {
            let msg = path != nil ? "No symbols found under \"\(path!)\"" : "Index is empty. No source files found."
            return .init(content: [.text(text: msg, annotations: nil, _meta: nil)])
        }

        let totalSymbols = grouped.reduce(0) { $0 + $1.symbols.count }
        var lines: [String] = ["\(totalSymbols) symbols across \(grouped.count) files\n"]

        for (file, symbols) in grouped {
            lines.append("  \(file)")
            var topLevel: [IndexEntry] = []
            var contained: [String: [IndexEntry]] = [:]

            for sym in symbols {
                if let c = sym.container { contained[c, default: []].append(sym) }
                else { topLevel.append(sym) }
            }

            for sym in topLevel {
                lines.append("    \(sym.kind) \(sym.name)")
                if let members = contained[sym.name] {
                    for m in members { lines.append("      \(m.kind) \(m.name)") }
                }
            }

            let topNames = Set(topLevel.map(\.name))
            for (container, members) in contained where !topNames.contains(container) {
                lines.append("    [\(container)]")
                for m in members { lines.append("      \(m.kind) \(m.name)") }
            }
        }

        let output = lines.joined(separator: "\n")
        session.recordMetrics(rawBytes: totalSymbols * 300, compressedBytes: output.utf8.count, feature: "explore",
                              command: path ?? session.projectRoot, outputPreview: String(output.prefix(200)))

        return .init(content: [.text(text: output, annotations: nil, _meta: nil)])
    }
}
