import Foundation
import Filter

// MARK: - CompoundLearning

/// Post-session feedback loop: analyze token_events for waste patterns, propose
/// new FilterRule entries, gate them for safety, and stage them for user review.
///
/// Phase H scope — wedge implementation:
/// - Signal type: recurring exec commands with <15% filter savings across ≥2 sessions
/// - Proposal: head(50) FilterRule (safe, conservative)
/// - Gate: command not already covered by a built-in rule
/// - Cadence: fires once in a background Task after session close
///
/// TODO: Phase H+1 — Gemma 4 enrichment for natural-language rationale
/// TODO: Phase H+1 — regex stripMatching proposals (needs BenchBaseline regression gate)
/// TODO: Phase H+1 — daily/sprint/quarterly cadence tiers
public enum CompoundLearning {

    // MARK: - Post-Session Entry Point

    /// Run post-session waste analysis and stage safe proposals.
    /// Non-blocking — always called from `Task.detached(priority: .background)`.
    public static func runPostSession(
        sessionId: String,
        projectRoot: String,
        db: SessionDatabase = .shared
    ) async {
        let report = WasteAnalyzer.analyze(
            projectRoot: projectRoot,
            sessionId: sessionId,
            db: db
        )
        guard !report.isEmpty else { return }

        for cmd in report.unfilteredCommands {
            let proposed = LearnedFilterRule(
                id: UUID().uuidString,
                command: cmd.baseCommand,
                subcommand: cmd.subcommand,
                ops: ["head(50)"],
                source: sessionId,
                confidence: max(0, min(1, 1.0 - (cmd.avgSavedPct / 100.0))),
                status: .staged,
                sessionCount: cmd.sessionCount,
                createdAt: Date()
            )

            guard runGate(proposed: proposed) else { continue }
            try? LearnedRulesStore.stage(proposed)
        }
    }

    // MARK: - Regression Gate

    /// Returns true if the proposed rule is safe to stage.
    ///
    /// Phase H gate: the command must not already be covered by a built-in rule.
    /// head(50) is conservative — it can only help unfiltered commands, never regress
    /// commands that already have specific rules.
    static func runGate(proposed: LearnedFilterRule) -> Bool {
        guard let match = CommandMatcher.parse(proposed.command) else { return false }

        // Reject if a built-in rule already covers this command (+subcommand combo)
        let alreadyCovered = BuiltinRules.rules.contains { rule in
            rule.matches(match)
        }
        return !alreadyCovered
    }
}
