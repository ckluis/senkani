import Foundation
import MCP
import Filter
import Core

enum ReadTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let path = arguments?["path"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'path' is required", annotations: nil, _meta: nil)], isError: true)
        }

        let absPath = path.hasPrefix("/") ? path : session.projectRoot + "/" + path

        // Check cache
        if session.cacheEnabled, let cached = session.readCache.lookup(path: absPath) {
            session.recordCacheSaving(bytes: cached.rawBytes)
            return .init(content: [.text(text: "// senkani: cached (\(cached.rawBytes) bytes saved)\n[unchanged since last read]", annotations: nil, _meta: nil)])
        }

        // Read
        guard let content = try? String(contentsOfFile: absPath, encoding: .utf8) else {
            return .init(content: [.text(text: "Error: could not read \(absPath)", annotations: nil, _meta: nil)], isError: true)
        }

        let rawBytes = content.utf8.count
        var output = content

        // Offset/limit
        if let offset = arguments?["offset"]?.intValue, let limit = arguments?["limit"]?.intValue {
            let lines = content.components(separatedBy: "\n")
            let start = max(0, offset - 1)
            let end = min(lines.count, start + limit)
            output = lines[start..<end].joined(separator: "\n")
        } else if let limit = arguments?["limit"]?.intValue {
            output = content.components(separatedBy: "\n").prefix(limit).joined(separator: "\n")
        }

        // Compress
        if session.filterEnabled {
            output = ANSIStripper.strip(output)
            output = LineOperations.stripBlankRuns(output, max: 1)
        }

        // Secrets
        if session.secretsEnabled {
            output = SecretDetector.scan(output).redacted
        }

        let compressedBytes = output.utf8.count
        let savedPct = rawBytes > 0 ? Int(Double(rawBytes - compressedBytes) / Double(rawBytes) * 100) : 0

        // Cache
        if session.cacheEnabled {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: absPath))?[.modificationDate] as? Date ?? Date()
            session.readCache.store(path: absPath, mtime: mtime, content: output, rawBytes: rawBytes)
        }

        session.recordMetrics(rawBytes: rawBytes, compressedBytes: compressedBytes, feature: "read")

        let header = "// senkani: \(rawBytes) -> \(compressedBytes) bytes (\(savedPct)% saved)\n"
        return .init(content: [.text(text: header + output, annotations: nil, _meta: nil)])
    }
}
