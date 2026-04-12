import Foundation

/// Token compression mode that teaches the agent to minimize output tokens.
/// Activated per-pane via the "T" toggle in the savings bar, which sets
/// the SENKANI_TERSE environment variable.
public enum TerseMode {
    /// The system prompt prefix injected when terse mode is on.
    /// Combines behavioral instruction with notice of algorithmic compression.
    public static let systemPrompt = """
    CRITICAL: You are in TERSE MODE. ALL responses must minimize output tokens ruthlessly.
    - Every reply — conversational, tool-adjacent, or otherwise: facts only, no filler.
    - Do the task first. Give the result. Stop.
    - No preamble ("I'd be happy to", "Let me", "Sure!")
    - No narration ("I'm going to", "Now I'll")
    - No summaries after actions
    - No restating what the user said
    - No explaining what you're about to do
    - Tool calls: no explanation before or after
    - One word > one sentence > one paragraph. Always pick the shortest form.
    - This applies to ALL output you produce — not just tool-adjacent text.
    NOTE: Tool outputs have been algorithmically compressed (articles, filler, verbose terms shortened). Code blocks are preserved exactly.
    """

    /// Check if terse mode is enabled via environment
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SENKANI_TERSE"] == "on"
    }
}
