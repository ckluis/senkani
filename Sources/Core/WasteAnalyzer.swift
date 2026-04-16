import Foundation

// MARK: - UnfilteredCommand

/// A recurring shell command with poor filter savings — candidate for a new FilterRule.
public struct UnfilteredCommand: Sendable {
    /// Raw command string as recorded in token_events, e.g. "docker compose logs --tail 100"
    public let command: String
    /// First whitespace-delimited token, e.g. "docker"
    public let baseCommand: String
    /// Second whitespace-delimited token, e.g. "compose". nil if command is a single word.
    public let subcommand: String?
    /// Average input_tokens across matching events.
    public let avgInputTokens: Int
    /// Average percentage of tokens saved (0–100). Low value = poorly filtered.
    public let avgSavedPct: Double
    /// Number of distinct sessions where this pattern appeared.
    public let sessionCount: Int
}

// MARK: - WasteReport

/// Output of a single WasteAnalyzer run for one session.
public struct WasteReport: Sendable {
    /// Commands sorted by avgInputTokens descending (largest savings opportunity first).
    public let unfilteredCommands: [UnfilteredCommand]
    /// The session_id that triggered this analysis.
    public let sessionId: String
    public let analyzedAt: Date

    public var isEmpty: Bool { unfilteredCommands.isEmpty }
}

// MARK: - WasteAnalyzer

/// Scans token_events for recurring shell commands with < 15% filter savings.
/// Pure SQL — no ML, no heuristics. Results are deterministic given the same DB state.
public enum WasteAnalyzer {

    /// Analyze a project's token history for poorly-filtered exec commands.
    ///
    /// - Parameters:
    ///   - projectRoot: Project directory, used to scope the query.
    ///   - sessionId: The triggering session (used to label the WasteReport).
    ///   - db: SessionDatabase instance (injectable for tests).
    ///   - minSessions: Only return commands seen in at least this many distinct sessions.
    ///   - minInputTokens: Ignore commands with fewer average input tokens (noise filter).
    public static func analyze(
        projectRoot: String,
        sessionId: String,
        db: SessionDatabase,
        minSessions: Int = 2,
        minInputTokens: Int = 100
    ) -> WasteReport {
        let rows = db.unfilteredExecCommands(
            projectRoot: projectRoot,
            minSessions: minSessions,
            minInputTokens: minInputTokens
        )

        let commands = rows.map { row -> UnfilteredCommand in
            let parts = row.command.split(separator: " ", maxSplits: 2).map(String.init)
            let base = parts.first ?? row.command
            let sub = parts.count > 1 ? parts[1] : nil
            return UnfilteredCommand(
                command: row.command,
                baseCommand: base,
                subcommand: sub,
                avgInputTokens: row.avgInputTokens,
                avgSavedPct: row.avgSavedPct,
                sessionCount: row.sessionCount
            )
        }

        return WasteReport(
            unfilteredCommands: commands,
            sessionId: sessionId,
            analyzedAt: Date()
        )
    }
}
