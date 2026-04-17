import Foundation
import Filter

// MARK: - RegressionGate
//
// Phase H+1 safety net for proposed filter rules.
//
// The contract, in prose:
//   Given a proposed `FilterRule` and a set of "real" output samples
//   that motivated it, the gate returns `.accepted` iff applying the
//   proposed rule on top of the baseline rule set produces a savings
//   percentage that is (a) NOT lower than baseline, and (b) at least
//   `minImprovementPct` higher than baseline. If either condition
//   fails, it returns `.rejectedRegressed(deltaPct:)` with the signed
//   delta (negative = savings dropped, positive-but-too-small = rule
//   doesn't help enough).
//
// Why it matters:
//   FilterEngine rules compose additively — a new rule cannot un-strip
//   output that was already stripped. So the "true" regression is rare
//   but possible when the proposed pattern fires on a line that was
//   previously passing through unchanged (which the baseline rule set
//   intentionally kept). The practical failure mode in H+1 is the
//   opposite: a proposed `head(50)` on a command whose output is
//   already 10 lines long does nothing — we shouldn't ship noise to
//   the operator's `senkani learn status`.
//
// Why it's fast:
//   No disk I/O. No async. Caller passes in the samples (typically 5–20
//   strings, each a few KB). A full gate run is <5ms even for oversized
//   samples.
//
// Why it's safe when `samples` is empty:
//   Early deployments won't have output previews for every observed
//   command. Empty `samples` returns `.accepted` — behavior identical
//   to Phase H. The gate *strengthens* H when data exists; it never
//   weakens it.

public enum RegressionGate {

    /// One real-world output sample.
    public struct Sample: Sendable {
        public let command: String
        public let output: String
        public init(command: String, output: String) {
            self.command = command
            self.output = output
        }
    }

    /// Default minimum improvement (percentage points) for a proposed rule
    /// to clear the gate. Calibrated conservatively — H+1 ships with 2pp,
    /// H+2 can recalibrate from telemetry once real data exists.
    public static let defaultMinImprovementPct: Double = 2.0

    /// Check whether the proposed rule adds meaningful savings on the
    /// supplied corpus vs. the baseline rule set.
    ///
    /// - Parameters:
    ///   - proposed:          the candidate `FilterRule`
    ///   - samples:           real output previews from `commands.output_preview`
    ///   - baselineRules:     the rule set the proposal would be *added to*
    ///                        (defaults to `BuiltinRules.rules`; tests can
    ///                        inject a custom baseline to exercise edge cases)
    ///   - minImprovementPct: minimum delta required to accept (default 2pp)
    ///
    /// - Returns: `.accepted` on no regression and Δ ≥ `minImprovementPct`,
    ///            `.rejectedRegressed(deltaPct: Δ)` otherwise, where Δ is
    ///            the signed baseline-minus-proposed delta (positive = rule
    ///            doesn't help enough, negative = rule regressed savings).
    public static func check(
        proposed: FilterRule,
        samples: [Sample],
        baselineRules: [FilterRule] = BuiltinRules.rules,
        minImprovementPct: Double = defaultMinImprovementPct
    ) -> GateResult {
        // No data → no basis to reject. Preserves H behavior.
        guard !samples.isEmpty else { return .accepted }

        let baselineEngine = FilterEngine(rules: baselineRules)
        let proposedEngine = FilterEngine(rules: baselineRules + [proposed])

        var totalRaw = 0
        var baselineOut = 0
        var proposedOut = 0
        for sample in samples {
            let raw = sample.output.utf8.count
            totalRaw += raw
            baselineOut += baselineEngine
                .filter(command: sample.command, output: sample.output)
                .output.utf8.count
            proposedOut += proposedEngine
                .filter(command: sample.command, output: sample.output)
                .output.utf8.count
        }

        guard totalRaw > 0 else { return .accepted }

        let baselinePct = Double(totalRaw - baselineOut) / Double(totalRaw) * 100.0
        let proposedPct = Double(totalRaw - proposedOut) / Double(totalRaw) * 100.0
        let improvement = proposedPct - baselinePct

        // Sign convention for the rejection payload:
        //   improvement > 0 → rule helped (maybe not enough)
        //   improvement ≤ 0 → rule didn't help / regressed
        // We report the *baseline-minus-proposed* delta so
        // `.rejectedRegressed(deltaPct: 3.5)` reads "savings DROPPED 3.5pp."
        let deltaForRejection = -improvement

        if improvement < 0 {
            // Actual regression — savings went down.
            return .rejectedRegressed(deltaPct: deltaForRejection)
        }
        if improvement < minImprovementPct {
            // Not enough improvement. Phrase as a threshold rejection so
            // the event counter key distinguishes "we tested you, you
            // didn't help" from "we tested you, you actively hurt."
            return .rejectedBelowThreshold(reason: String(
                format: "proposed rule adds only %.1fpp savings (< %.1fpp min)",
                improvement, minImprovementPct))
        }
        return .accepted
    }
}
