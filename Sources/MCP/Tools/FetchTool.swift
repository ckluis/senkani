import Foundation
import MCP
import Indexer
import Core

enum FetchTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let name = arguments?["name"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'name' is required", annotations: nil, _meta: nil)], isError: true)
        }

        guard let index = session.indexIfReady() else {
            return .init(content: [.text(text: "Symbol index is building (first run). Try again in a few seconds.", annotations: nil, _meta: nil)])
        }

        guard let entry = index.find(name: name) else {
            let candidates = index.search(name: name).prefix(5)
            if candidates.isEmpty {
                return .init(content: [.text(text: "Symbol \"\(name)\" not found in index.", annotations: nil, _meta: nil)], isError: true)
            }
            var msg = "Symbol \"\(name)\" not found. Did you mean:\n"
            for c in candidates {
                msg += "  - \(c.name) (\(c.kind)) at \(c.file):\(c.startLine)\n"
            }
            return .init(content: [.text(text: msg, annotations: nil, _meta: nil)], isError: true)
        }

        let fullPath = session.projectRoot + "/" + entry.file
        guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
            return .init(content: [.text(text: "Could not read \(entry.file)", annotations: nil, _meta: nil)], isError: true)
        }

        let lines = content.components(separatedBy: "\n")
        let start = max(0, entry.startLine - 1)
        let end = min(lines.count, (entry.endLine ?? (entry.startLine + 19)))
        let slice = lines[start..<end]
        let sliceText = slice.joined(separator: "\n")

        // Apply secret detection
        var output = sliceText
        if session.secretsEnabled {
            output = SecretDetector.scan(output).redacted
        }

        let wholeFileBytes = content.utf8.count
        let sliceBytes = output.utf8.count
        let savedPct = wholeFileBytes > 0 ? Int(Double(wholeFileBytes - sliceBytes) / Double(wholeFileBytes) * 100) : 0

        session.recordMetrics(rawBytes: wholeFileBytes, compressedBytes: sliceBytes, feature: "fetch",
                              command: name, outputPreview: String(output.prefix(200)))

        var header = "// \(entry.name) (\(entry.kind)) — \(entry.file):\(entry.startLine)-\(end)\n"
        if let sig = entry.signature { header += "// \(sig)\n" }
        header += "// senkani: \(sliceBytes) bytes fetched (whole file: \(wholeFileBytes), \(savedPct)% saved)\n\n"

        var numbered = ""
        for (i, line) in slice.enumerated() {
            numbered += "\(String(start + i + 1).padding(toLength: 5, withPad: " ", startingAt: 0))| \(line)\n"
        }

        return .init(content: [.text(text: header + numbered, annotations: nil, _meta: nil)])
    }
}
