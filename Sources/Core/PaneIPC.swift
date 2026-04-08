import Foundation

/// File-based IPC protocol for pane control between the MCP tool (out-of-process)
/// and the Senkani GUI. Follows the MetricsWatcher pattern: JSONL command queue
/// + per-request response files.
///
/// Flow: MCP tool appends command → GUI watcher picks up → executes → writes response
///       → MCP tool polls for response file.

// MARK: - Actions

public enum PaneIPCAction: String, Codable {
    case list
    case add
    case remove
    case setActive = "set_active"
}

// MARK: - Command (MCP → GUI)

public struct PaneIPCCommand: Codable {
    public let id: String
    public let action: PaneIPCAction
    public let params: [String: String]
    public let timestamp: Date

    public init(action: PaneIPCAction, params: [String: String] = [:]) {
        self.id = UUID().uuidString
        self.action = action
        self.params = params
        self.timestamp = Date()
    }
}

// MARK: - Response (GUI → MCP)

public struct PaneIPCResponse: Codable {
    public let id: String
    public let success: Bool
    public let result: String?
    public let error: String?

    public init(id: String, success: Bool, result: String? = nil, error: String? = nil) {
        self.id = id
        self.success = success
        self.result = result
        self.error = error
    }
}

// MARK: - Paths

public enum PaneIPCPaths {
    private static var baseDir: String { NSHomeDirectory() + "/.senkani" }

    /// JSONL file where MCP tool appends commands.
    public static var commandFile: String { baseDir + "/pane-commands.jsonl" }

    /// Directory where GUI writes per-request response JSON files.
    public static var responseDir: String { baseDir + "/pane-responses" }

    /// Path for a specific response file.
    public static func responsePath(for requestId: String) -> String {
        responseDir + "/\(requestId).json"
    }

    /// Ensure the response directory exists.
    public static func ensureDirectories() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: responseDir) {
            try? fm.createDirectory(atPath: responseDir, withIntermediateDirectories: true)
        }
        // Ensure command file parent exists
        let cmdDir = (commandFile as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: cmdDir) {
            try? fm.createDirectory(atPath: cmdDir, withIntermediateDirectories: true)
        }
    }
}
