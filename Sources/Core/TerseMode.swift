import Foundation

/// Token compression mode that teaches the agent to minimize output tokens.
/// Activated per-pane via the "T" toggle in the savings bar, which sets
/// the SENKANI_TERSE environment variable.
public enum TerseMode {
    /// The system prompt prefix injected when terse mode is on.
    /// This teaches the agent to minimize output tokens.
    public static let systemPrompt = """
    CRITICAL: You are in TERSE MODE. Minimize output tokens ruthlessly.
    - Do the task first. Give the result. Stop.
    - No preamble ("I'd be happy to", "Let me", "Sure!")
    - No narration ("I'm going to", "Now I'll")
    - No summaries after actions
    - Use shortest possible descriptions
    - Tool calls: no explanation before or after
    - Answers: facts only, no filler
    - One word is better than one sentence
    - "result. done." not "I have completed the task successfully."
    """

    /// Check if terse mode is enabled via environment
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SENKANI_TERSE"] == "on"
    }
}
