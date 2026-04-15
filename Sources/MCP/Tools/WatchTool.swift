import Foundation
import MCP

/// MCP tool: senkani_watch
/// Query file changes detected by FSEvents. Returns changed files since a cursor timestamp.
/// Eliminates re-read polling — one call instead of re-reading the file tree.
enum WatchTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        let sinceStr = arguments?["since"]?.stringValue
        let glob = arguments?["glob"]?.stringValue

        var sinceDate: Date? = nil
        if let sinceStr = sinceStr {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            sinceDate = fmt.date(from: sinceStr)
            if sinceDate == nil {
                // Try without fractional seconds
                sinceDate = ISO8601DateFormatter().date(from: sinceStr)
            }
            if sinceDate == nil {
                return .init(content: [.text(text: "Error: invalid ISO8601 date: \(sinceStr)", annotations: nil, _meta: nil)], isError: true)
            }
        }

        let events = session.changesSince(sinceDate, glob: glob)

        if events.isEmpty {
            let msg = sinceStr != nil
                ? "No file changes since \(sinceStr!)."
                : "No file changes detected yet. Changes appear after edits/builds within the project."
            return .init(content: [.text(text: msg, annotations: nil, _meta: nil)])
        }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = ["\(events.count) change(s):"]
        for event in events {
            lines.append("  \(fmt.string(from: event.timestamp))  \(event.eventType)  \(event.path)")
        }

        // Include the latest timestamp as a cursor hint
        if let last = events.last {
            lines.append("")
            lines.append("Cursor for next call: since=\"\(fmt.string(from: last.timestamp))\"")
        }

        return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }
}
