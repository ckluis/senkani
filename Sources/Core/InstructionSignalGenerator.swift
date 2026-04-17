import Foundation

// MARK: - InstructionSignalGenerator
//
// Phase H+2c — proposes `LearnedInstructionPatch` artifacts from
// in-session retry patterns. Heuristic: a (tool, command) pair that
// fires ≥ minRetries times in a single session across ≥ minSessions
// distinct sessions indicates the agent kept trying to get the right
// answer. An instruction patch for that tool nudges the next agent
// toward a more effective phrasing.
//
// Deterministic: no LLM. The `hint` string is templated from the
// retry data. Future H+2c+ round can enrich the hint via Gemma
// through the existing `RationaleLLM` infrastructure.

public enum InstructionSignalGenerator {

    public static func analyze(
        projectRoot: String,
        sessionId: String,
        db: SessionDatabase,
        minRetries: Int = 3,
        minSessions: Int = 2,
        limit: Int = 5,
        now: Date = Date()
    ) -> [LearnedInstructionPatch] {
        let rows = db.instructionRetryPatterns(
            projectRoot: projectRoot,
            minRetries: minRetries,
            minSessions: minSessions,
            limit: limit
        )
        guard !rows.isEmpty else { return [] }

        return rows.map { row in
            let commandSnippet = String(row.command.prefix(80))
            let hint = """
            `\(row.toolName)` is frequently retried — e.g., `\(commandSnippet)` fired \
            an average of \(String(format: "%.1f", row.avgRetries)) times per session across \
            \(row.sessionCount) sessions. Consider a more specific invocation up front to avoid the retry loop.
            """
            let confidence = ConfidenceEstimator.laplace(
                avgSavedPct: 0,
                sessionCount: row.sessionCount
            )
            return LearnedInstructionPatch(
                id: UUID().uuidString,
                toolName: row.toolName,
                hint: hint,
                sources: [sessionId],
                confidence: confidence,
                status: .recurring,
                createdAt: now,
                lastSeenAt: now,
                recurrenceCount: 1,
                sessionCount: row.sessionCount
            )
        }
    }
}
