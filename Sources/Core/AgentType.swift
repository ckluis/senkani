/// Identifies the type of AI agent that opened a Senkani session.
/// Used to label sessions and choose the right token-tracking methodology.
///
/// Tiers:
///   Tier 1 (exact)    — Claude Code: actual usage from JSONL incremental reader
///   Tier 2 (estimated) — Hook agents: output_bytes → estimated tokens from PostToolUse
///   Tier 3 (partial)  — MCP-only: compression savings only; no API usage data
public enum AgentType: String, Codable, Sendable, CaseIterable {
    case claudeCode    = "claude_code"       // Tier 1 exact
    case cursor        = "cursor"             // Tier 2 estimated
    case cline         = "cline"              // Tier 2 estimated
    case copilot       = "copilot"            // Tier 2 estimated
    case vscodeCopilot = "vscode_copilot"     // Tier 2 estimated
    case unknownHook   = "unknown_hook"       // Tier 2 estimated (hook present, type unknown)
    case unknownMCP    = "unknown_mcp"        // Tier 3 partial

    /// Human-readable display label.
    public var displayName: String {
        switch self {
        case .claudeCode:    return "Claude Code"
        case .cursor:        return "Cursor"
        case .cline:         return "Cline"
        case .copilot:       return "GitHub Copilot"
        case .vscodeCopilot: return "VS Code Copilot"
        case .unknownHook:   return "Unknown (hook)"
        case .unknownMCP:    return "Unknown (MCP)"
        }
    }

    /// model_tier value written to token_events rows.
    public var modelTier: String {
        switch self {
        case .claudeCode:
            return "tier1_exact"
        case .cursor, .cline, .copilot, .vscodeCopilot, .unknownHook:
            return "tier2_estimated"
        case .unknownMCP:
            return "tier3_partial"
        }
    }

    /// Tracking methodology label, shown in eval and savings pane.
    public var methodologyLabel: String {
        switch self {
        case .claudeCode:
            return "Tier 1 — exact (JSONL)"
        case .cursor, .cline, .copilot, .vscodeCopilot, .unknownHook:
            return "Tier 2 — estimated (hooks)"
        case .unknownMCP:
            return "Tier 3 — partial (MCP only)"
        }
    }
}
