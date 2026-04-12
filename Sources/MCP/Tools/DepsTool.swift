import Foundation
import MCP
import Indexer

enum DepsTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let target = arguments?["target"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'target' is required (file path or module name)", annotations: nil, _meta: nil)], isError: true)
        }

        let direction = arguments?["direction"]?.stringValue ?? "both"
        let graph = session.ensureDependencyGraph()

        var lines: [String] = []

        // "What does this import?"
        if direction == "both" || direction == "imports" {
            let deps = graph.dependencies(of: target)
            if !deps.isEmpty {
                lines.append("\(target) imports (\(deps.count)):")
                for dep in deps { lines.append("  → \(dep)") }
            } else {
                lines.append("\(target) imports: (none found)")
            }
        }

        if direction == "both" { lines.append("") }

        // "What imports this?"
        if direction == "both" || direction == "importedBy" {
            let dependents = graph.dependents(of: target)
            if !dependents.isEmpty {
                lines.append("Imported by (\(dependents.count) files):")
                for dep in dependents { lines.append("  ← \(dep)") }
            } else {
                lines.append("Imported by: (none found)")
            }
        }

        let output = lines.joined(separator: "\n")

        // Estimate savings: each file the agent would have read is ~2KB
        let estimatedRawBytes = (graph.dependencies(of: target).count + graph.dependents(of: target).count) * 2000
        session.recordMetrics(
            rawBytes: max(estimatedRawBytes, 1000),
            compressedBytes: output.utf8.count,
            feature: "deps",
            command: target,
            outputPreview: String(output.prefix(200))
        )

        return .init(content: [.text(text: output, annotations: nil, _meta: nil)])
    }
}
