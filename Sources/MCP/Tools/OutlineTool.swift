import Foundation
import MCP
import Indexer

enum OutlineTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let file = arguments?["file"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'file' is required", annotations: nil, _meta: nil)], isError: true)
        }

        guard let index = session.indexIfReady() else {
            return .init(content: [.text(text: "Symbol index is building (first run). Try again in a few seconds.", annotations: nil, _meta: nil)])
        }

        // Find symbols in this file (substring match so both relative and absolute paths work)
        let symbols = index.search(file: file)
            .sorted { $0.startLine < $1.startLine }

        guard !symbols.isEmpty else {
            return .init(content: [.text(text: "No symbols found in \"\(file)\". File may not be indexed or may not exist.", annotations: nil, _meta: nil)])
        }

        // Build outline: group top-level vs contained, show line numbers
        var lines: [String] = []
        let fileName = symbols.first?.file ?? file
        lines.append("\(fileName) — \(symbols.count) symbols\n")

        var topLevel: [IndexEntry] = []
        var contained: [String: [IndexEntry]] = [:]

        for sym in symbols {
            if let c = sym.container {
                contained[c, default: []].append(sym)
            } else {
                topLevel.append(sym)
            }
        }

        for sym in topLevel {
            let lineRange = sym.endLine != nil ? "L\(sym.startLine)-\(sym.endLine!)" : "L\(sym.startLine)"
            let sig = sym.signature != nil ? " — \(sym.signature!)" : ""
            lines.append("  \(lineRange.padding(toLength: 12, withPad: " ", startingAt: 0)) \(sym.kind) \(sym.name)\(sig)")

            if let members = contained[sym.name] {
                for m in members {
                    let mRange = m.endLine != nil ? "L\(m.startLine)-\(m.endLine!)" : "L\(m.startLine)"
                    lines.append("  \(mRange.padding(toLength: 12, withPad: " ", startingAt: 0))   \(m.kind) \(m.name)")
                }
            }
        }

        // Show orphaned containers (container not in top-level)
        let topNames = Set(topLevel.map(\.name))
        for (container, members) in contained.sorted(by: { $0.value.first!.startLine < $1.value.first!.startLine }) where !topNames.contains(container) {
            lines.append("  [\(container)]")
            for m in members {
                let mRange = m.endLine != nil ? "L\(m.startLine)-\(m.endLine!)" : "L\(m.startLine)"
                lines.append("  \(mRange.padding(toLength: 12, withPad: " ", startingAt: 0))   \(m.kind) \(m.name)")
            }
        }

        let output = lines.joined(separator: "\n")

        // Estimate whole-file bytes from file size without reading content
        let fullPath = session.projectRoot + "/" + fileName
        let rawBytes = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.size] as? Int) ?? (symbols.count * 300)
        session.recordMetrics(rawBytes: rawBytes, compressedBytes: output.utf8.count, feature: "outline",
                              command: file, outputPreview: String(output.prefix(200)))

        return .init(content: [.text(text: output, annotations: nil, _meta: nil)])
    }
}
