import Foundation

/// U.4b-1 — pure promotion-gate evaluator. Decides whether a
/// `set-mode blocking` request from `senkani trust set-mode blocking`
/// (or the upcoming U.4b-2 GUI mode-toggle) is accepted or rejected.
///
/// Pure: no I/O, no clock. Caller passes the observed FP-rate +
/// labeled sample size and the configured thresholds; the gate
/// returns `.accept` or `.reject(reason:)`.
///
/// Schneier audit (operator scope-groom Q4): the gate is a
/// **checkable invariant** — no free-text override, no defaults.
/// Missing thresholds reject; under-threshold sample rejects; over-
/// threshold rate rejects. Only when BOTH conditions are met does
/// the flip succeed, and only then does the chain record one
/// `promotion` row carrying all four numeric witnesses.
public enum PromotionGate {

    /// Decision returned by `evaluate`. `.reject` carries a structured
    /// reason string the CLI surfaces verbatim to the operator (and
    /// the U.4b-2 GUI toggle displays inline per Norman's verdict).
    public enum Decision: Sendable, Equatable {
        case accept
        case reject(reason: String)
    }

    /// Evaluate a `.softFlag → .blocking` flip request.
    ///
    /// - Parameters:
    ///   - fpRateMax: Operator-set ceiling on the running FP-rate
    ///     (0.0–1.0). nil rejects with "configure threshold first".
    ///   - minLabeledSample: Operator-set floor on the labeled-sample
    ///     count over the prior 30 days. nil rejects with "configure
    ///     threshold first".
    ///   - observedRate: Running FP-rate computed from `trust_audits`
    ///     `label` rows over the prior 30 days. nil when sample is
    ///     zero (no labels in window).
    ///   - observedSample: Labeled-sample count over the prior 30
    ///     days. Always ≥ 0.
    ///
    /// Order of checks:
    ///   1. Both thresholds configured?
    ///   2. Sample size ≥ `minLabeledSample`?
    ///   3. Observed rate ≤ `fpRateMax`? (nil observed rate when
    ///      sample is 0 fails check 2 first.)
    public static func evaluate(
        fpRateMax: Double?,
        minLabeledSample: Int?,
        observedRate: Double?,
        observedSample: Int
    ) -> Decision {
        guard let rateMax = fpRateMax, let minSample = minLabeledSample else {
            return .reject(reason: "configure threshold first (senkani trust threshold --fp-rate-max <0-1> --min-sample <N>)")
        }
        if observedSample < minSample {
            return .reject(reason: "insufficient labeled sample: observed \(observedSample) < min_labeled_sample \(minSample) over prior 30d")
        }
        // observedRate is nil iff observedSample == 0; we already
        // failed the sample-size check above in that branch.
        guard let rate = observedRate else {
            return .reject(reason: "no observed FP-rate (no labels in window)")
        }
        if rate > rateMax {
            return .reject(reason: "observed FP-rate \(String(format: "%.3f", rate)) > fp_rate_max \(String(format: "%.3f", rateMax)) over prior 30d")
        }
        return .accept
    }

    /// Compute `observedRate` from FP/TP counts. Returns nil when the
    /// total (FP + TP) is zero — caller treats this as a zero-sample
    /// case (rejected by the sample-size check).
    public static func observedRate(fp: Int, tp: Int) -> Double? {
        let total = fp + tp
        guard total > 0 else { return nil }
        return Double(fp) / Double(total)
    }
}
