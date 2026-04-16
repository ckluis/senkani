import Foundation

/// Detects the AI agent type from process environment variables.
/// Pure function — zero I/O, zero allocation beyond a dictionary lookup.
/// Called once per session start; result stored on MCPSession.
public enum AgentDetector {

    /// Detect the agent type from the given environment dictionary.
    /// The `environment` parameter is injected for testability;
    /// production callers use the default (ProcessInfo.processInfo.environment).
    public static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AgentType {
        // Explicit override — always wins, enables future agents and test stubs.
        if let explicit = environment["SENKANI_AGENT"],
           let type_ = AgentType(rawValue: explicit) {
            return type_
        }

        // Claude Code — sets SENKANI_PANE_ID when spawning MCP server inside a pane.
        if environment["SENKANI_PANE_ID"] != nil {
            return .claudeCode
        }

        // Cursor IDE — documented env vars in their MCP subprocess environment.
        // Note: verified against Cursor 0.40+ docs; use SENKANI_AGENT override if changed.
        if environment["CURSOR_TRACE_ID"] != nil || environment["CURSOR_SESSION_ID"] != nil {
            return .cursor
        }

        // Cline VS Code extension — sets CLINE_TASK_ID in its MCP subprocess environment.
        if environment["CLINE_TASK_ID"] != nil {
            return .cline
        }

        // GitHub Copilot extensions
        if environment["GITHUB_COPILOT_AGENT"] != nil {
            return .copilot
        }

        // VS Code Copilot Chat
        if environment["VSCODE_COPILOT_CHAT"] != nil {
            return .vscodeCopilot
        }

        // Hook env var is set — agent is hook-capable but not identified above.
        if environment["SENKANI_HOOK"] == "on" || environment["SENKANI_INTERCEPT"] == "on" {
            return .unknownHook
        }

        // MCP-only: no pane, no hooks, no recognized agent env vars.
        return .unknownMCP
    }
}
