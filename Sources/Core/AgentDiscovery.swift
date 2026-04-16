import Foundation

/// A detected AI agent installation on this machine.
public struct InstalledAgent: Sendable {
    public let agentType: AgentType
    /// Absolute path to the config file where the agent was found.
    public let configPath: String
    /// True when a Senkani MCP server entry is present in that config.
    public let hasSenkaniMCP: Bool

    public init(agentType: AgentType, configPath: String, hasSenkaniMCP: Bool) {
        self.agentType = agentType
        self.configPath = configPath
        self.hasSenkaniMCP = hasSenkaniMCP
    }
}

/// Scans well-known config file locations to discover installed AI agents.
/// Used by `senkani doctor` to report the agent ecosystem and verify MCP registration.
public enum AgentDiscovery {

    /// Return all detected agent installations. Non-blocking (filesystem reads only).
    public static func scan() -> [InstalledAgent] {
        var results: [InstalledAgent] = []
        results += scanClaudeCode()
        results += scanCursor()
        results += scanCline()
        return results
    }

    // MARK: - Per-agent scanners

    private static func scanClaudeCode() -> [InstalledAgent] {
        let path = NSHomeDirectory() + "/.claude/settings.json"
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let active = hasSenkani(in: path, serverKey: "mcpServers")
        return [InstalledAgent(agentType: .claudeCode, configPath: path, hasSenkaniMCP: active)]
    }

    private static func scanCursor() -> [InstalledAgent] {
        let candidates = [
            NSHomeDirectory() + "/.cursor/mcp.json",
            NSHomeDirectory() + "/Library/Application Support/Cursor/User/mcp.json",
        ]
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let active = hasSenkani(in: path, serverKey: "mcpServers")
            return [InstalledAgent(agentType: .cursor, configPath: path, hasSenkaniMCP: active)]
        }
        return []
    }

    private static func scanCline() -> [InstalledAgent] {
        // Cline stores MCP config in VS Code extension global storage.
        let candidates = [
            NSHomeDirectory() + "/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
        ]
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let active = hasSenkani(in: path, serverKey: "mcpServers")
            return [InstalledAgent(agentType: .cline, configPath: path, hasSenkaniMCP: active)]
        }
        return []
    }

    // MARK: - Helpers

    private static func hasSenkani(in path: String, serverKey: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = config[serverKey] as? [String: Any] else { return false }
        return servers["senkani"] != nil
    }
}
