import Foundation
import MCP
import Core

/// MCP tool for controlling workspace panes via file-based IPC.
/// Claude can list, add, remove, or focus panes — enabling orchestration
/// like "open a browser to test localhost:3000" or "spin up a terminal for tests."
enum PaneControlTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let actionStr = arguments?["action"]?.stringValue,
              let action = PaneIPCAction(rawValue: actionStr) else {
            return .init(
                content: [.text(text: "Error: 'action' is required (list, add, remove, set_active)", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // Build params from arguments
        var params: [String: String] = [:]
        for key in ["type", "title", "command", "url", "pane_id"] {
            if let val = arguments?[key]?.stringValue {
                params[key] = val
            }
        }

        let command = PaneIPCCommand(action: action, params: params)

        // Ensure IPC directories exist
        PaneIPCPaths.ensureDirectories()

        // Append command to JSONL queue
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(command) else {
            return .init(
                content: [.text(text: "Error: failed to encode command", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let line = String(data: data, encoding: .utf8)! + "\n"
        let fileURL = URL(fileURLWithPath: PaneIPCPaths.commandFile)

        // Append atomically
        if FileManager.default.fileExists(atPath: PaneIPCPaths.commandFile) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                return .init(
                    content: [.text(text: "Error: failed to open command file for writing", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }

        // Poll for response (50ms interval, 5s timeout)
        let responsePath = PaneIPCPaths.responsePath(for: command.id)
        let deadline = Date().addingTimeInterval(5.0)

        while Date() < deadline {
            if let responseData = FileManager.default.contents(atPath: responsePath) {
                // Clean up response file
                try? FileManager.default.removeItem(atPath: responsePath)

                let decoder = JSONDecoder()
                if let response = try? decoder.decode(PaneIPCResponse.self, from: responseData) {
                    if response.success {
                        return .init(
                            content: [.text(text: response.result ?? "OK", annotations: nil, _meta: nil)],
                            isError: false
                        )
                    } else {
                        return .init(
                            content: [.text(text: "Error: \(response.error ?? "unknown error")", annotations: nil, _meta: nil)],
                            isError: true
                        )
                    }
                }

                return .init(
                    content: [.text(text: "Error: malformed response", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Timeout — GUI might not be running
        return .init(
            content: [.text(text: "Error: timeout waiting for Senkani GUI response. Is the app running?", annotations: nil, _meta: nil)],
            isError: true
        )
    }
}
