import Foundation
import MCP
import Filter
import Core
import Indexer

enum ReadTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let path = arguments?["path"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'path' is required", annotations: nil, _meta: nil)], isError: true)
        }

        let absPath = path.hasPrefix("/") ? path : session.projectRoot + "/" + path
        let wantsFull = arguments?["full"]?.boolValue == true
        let hasRange = arguments?["offset"]?.intValue != nil || arguments?["limit"]?.intValue != nil

        // Check cache (always returns full content — skip for outline-only)
        if (wantsFull || hasRange), session.cacheEnabled, let cached = session.readCache.lookup(path: absPath) {
            session.recordCacheSaving(bytes: cached.rawBytes)
            return .init(content: [.text(text: "// senkani: cached (\(cached.rawBytes) bytes saved)\n[unchanged since last read]", annotations: nil, _meta: nil)])
        }

        // Outline-first: if not full and no range, try returning outline from index
        if !wantsFull && !hasRange && session.indexerEnabled,
           let outline = buildOutline(absPath: absPath, session: session) {
            return outline
        }

        // Full read fallback
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

        // Terse compression
        if session.terseEnabled {
            output = TerseCompressor.compress(output)
        }

        let compressedBytes = output.utf8.count
        let savedPct = rawBytes > 0 ? Int(Double(rawBytes - compressedBytes) / Double(rawBytes) * 100) : 0

        // Cache
        if session.cacheEnabled {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: absPath))?[.modificationDate] as? Date ?? Date()
            session.readCache.store(path: absPath, mtime: mtime, content: output, rawBytes: rawBytes)
        }

        session.recordMetrics(rawBytes: rawBytes, compressedBytes: compressedBytes, feature: "read",
                              command: absPath, outputPreview: String(output.prefix(200)))

        let header = "// senkani: \(rawBytes) -> \(compressedBytes) bytes (\(savedPct)% saved)\n"
        return .init(content: [.text(text: header + output, annotations: nil, _meta: nil)])
    }

    /// Build an outline from the symbol index for the given file path.
    /// Returns nil if the index isn't ready or has no symbols for this file.
    private static func buildOutline(absPath: String, session: MCPSession) -> CallTool.Result? {
        guard let index = session.indexIfReady() else { return nil }

        // Match by relative path within project root, or by filename
        let relativePath: String
        let prefix = session.projectRoot + "/"
        if absPath.hasPrefix(prefix) {
            relativePath = String(absPath.dropFirst(prefix.count))
        } else {
            relativePath = (absPath as NSString).lastPathComponent
        }

        let symbols = index.search(file: relativePath).sorted { $0.startLine < $1.startLine }
        guard !symbols.isEmpty else { return nil }

        // Build outline text (same format as OutlineTool)
        var lines: [String] = []
        let fileName = symbols.first?.file ?? relativePath
        lines.append("\(fileName) — \(symbols.count) symbols (outline — use read with full: true for complete content)\n")

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

        // Orphaned containers
        let topNames = Set(topLevel.map(\.name))
        for (container, members) in contained.sorted(by: { $0.value.first!.startLine < $1.value.first!.startLine }) where !topNames.contains(container) {
            lines.append("  [\(container)]")
            for m in members {
                let mRange = m.endLine != nil ? "L\(m.startLine)-\(m.endLine!)" : "L\(m.startLine)"
                lines.append("  \(mRange.padding(toLength: 12, withPad: " ", startingAt: 0))   \(m.kind) \(m.name)")
            }
        }

        let output = lines.joined(separator: "\n")

        // Estimate full file size for savings calculation
        let rawBytes = (try? FileManager.default.attributesOfItem(atPath: absPath)[.size] as? Int) ?? (symbols.count * 300)
        let compressedBytes = output.utf8.count
        let savedPct = rawBytes > 0 ? Int(Double(rawBytes - compressedBytes) / Double(rawBytes) * 100) : 0

        session.recordMetrics(rawBytes: rawBytes, compressedBytes: compressedBytes, feature: "outline_read",
                              command: absPath, outputPreview: String(output.prefix(200)))

        let header = "// senkani: outline \(rawBytes) -> \(compressedBytes) bytes (\(savedPct)% saved)\n"
        return .init(content: [.text(text: header + output, annotations: nil, _meta: nil)])
    }
}
