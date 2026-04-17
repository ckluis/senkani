import Foundation

// MARK: - SignalType
//
// Phase H+1 adopts the Garg "Feedback Flywheel" taxonomy: every learned
// pattern belongs to exactly one of four signal categories, each mapped
// to a typed artifact destination (see spec/compound_learning.md). The
// H+1 wedge only generates `.failure` signals (filter rules ARE failure
// signals — the filter pipeline didn't catch noise), but the field is
// serialized on every rule so H+2 can add context / instruction /
// workflow generators without another schema migration.

public enum SignalType: String, Codable, Sendable, CaseIterable {
    /// Priming document destination — `.senkani/context/<topic>.md`.
    case context
    /// MCP tool description / shared command preamble destination.
    case instruction
    /// Team / project playbook destination.
    case workflow
    /// Guardrail destination — filter rules, rewriter entries, validator
    /// additions. Default for Phase H+1 proposals.
    case failure
}

// MARK: - GateResult
//
// Enumerated outcome of the proposal-safety gate. Replaces the Phase H
// `Bool` so every rejection has a reason code — diagnosable from CLI
// and directly mappable to an `event_counters` row (Majors).

public enum GateResult: Sendable, Equatable {
    /// Proposal is safe to stage.
    case accepted

    /// A BuiltinRules.rules entry already covers this command+subcommand.
    case rejectedBuiltinCovered

    /// An existing learned rule (staged or applied) already covers this
    /// command+subcommand. Dedup defense at the gate, not the store.
    case rejectedAlreadyLearned

    /// Reserved for H+2: the proposed FilterOp has a complexity signature
    /// that could cause runtime pathologies (ReDoS, huge capture groups).
    /// H+1 rule generation produces only bounded substring patterns so
    /// this branch is unreachable today but reserved for telemetry symmetry.
    case rejectedComplexity

    /// Applying the proposed rule to a representative output corpus
    /// reduced filter savings vs. baseline — or didn't improve enough.
    /// `deltaPct` is negative when savings regressed, positive-but-below-
    /// threshold when the rule simply didn't help enough.
    case rejectedRegressed(deltaPct: Double)

    /// Duplicate of an active proposal at the same lifecycle stage.
    /// Dedup within a single post-session run.
    case rejectedDuplicate

    /// Catch-all for statistical / heuristic thresholds that the gate
    /// rejects before running the regression check. `reason` is logged
    /// to stderr so operators can debug distribution issues.
    case rejectedBelowThreshold(reason: String)

    /// Whether the proposal was accepted.
    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    /// The `event_counters.type` value to bump when this outcome fires.
    /// Keys are stable; changing them breaks dashboards and CLI output.
    public var eventCounterKey: String {
        switch self {
        case .accepted:                 return "compound_learning.proposal.accepted"
        case .rejectedBuiltinCovered:   return "compound_learning.proposal.rejected.builtin"
        case .rejectedAlreadyLearned:   return "compound_learning.proposal.rejected.learned"
        case .rejectedComplexity:       return "compound_learning.proposal.rejected.complexity"
        case .rejectedRegressed:        return "compound_learning.proposal.rejected.regressed"
        case .rejectedDuplicate:        return "compound_learning.proposal.rejected.duplicate"
        case .rejectedBelowThreshold:   return "compound_learning.proposal.rejected.threshold"
        }
    }

    /// Short human-readable form for CLI / log output.
    public var shortDescription: String {
        switch self {
        case .accepted:                         return "accepted"
        case .rejectedBuiltinCovered:           return "rejected: covered by builtin rule"
        case .rejectedAlreadyLearned:           return "rejected: already learned"
        case .rejectedComplexity:               return "rejected: rule complexity"
        case .rejectedRegressed(let delta):     return "rejected: savings delta \(String(format: "%+.1f", delta))pp"
        case .rejectedDuplicate:                return "rejected: duplicate of active proposal"
        case .rejectedBelowThreshold(let why):  return "rejected: \(why)"
        }
    }
}

// MARK: - Laplace-smoothed confidence
//
// Phase H used `1.0 - avgSavedPct/100.0` as the confidence — a raw point
// estimate on samples of size `sessionCount` (typically 2–5). Gelman's
// concern: variance is infinite in the tails, and rules applied on N=2
// noise corrupt downstream. H+1 shrinks toward the prior.
//
// Model: treat each session as one Bernoulli trial on "this command is
// unfiltered." Prior is Beta(α=1, β=1) ≡ uniform ≡ Laplace's rule of
// succession. The posterior mean is (successes + α) / (trials + α + β).
// Here `successes` = (100 - avgSavedPct)/100 × sessionCount, i.e. how
// many sessions' worth of "unfiltered" we observed. This keeps small-N
// confidences bounded between 0.25 and 0.75 even with extreme inputs,
// and converges to the raw estimate as sessionCount grows.

public enum ConfidenceEstimator {
    /// Laplace-smoothed confidence that the command is genuinely unfiltered.
    /// - Parameters:
    ///   - avgSavedPct: observed average savings percentage (0–100).
    ///   - sessionCount: number of distinct sessions contributing.
    /// - Returns: posterior mean in [0, 1], clamped just in case.
    public static func laplace(avgSavedPct: Double, sessionCount: Int) -> Double {
        // Map "avgSavedPct=0" → all trials were unfiltered (success for us).
        // Map "avgSavedPct=100" → no trials were unfiltered.
        let unfilteredFraction = max(0, min(1, (100.0 - avgSavedPct) / 100.0))
        let n = max(0, sessionCount)
        let successes = unfilteredFraction * Double(n)
        // Beta(1,1) prior → (x + 1) / (n + 2).
        let posterior = (successes + 1.0) / (Double(n) + 2.0)
        return max(0.0, min(1.0, posterior))
    }
}
