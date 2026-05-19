import Foundation

/// Three-band F1 verdict for the PIIClassifier eval gate (T.2b-2).
/// Layered on top of T.2b-1's `EvalResultsStore` writer + `senkani
/// doctor` Layer 3 status line.
///
/// Karpathy P0: the three bands are a clean decision surface — clean
/// ships without a peep, warn ships with a durable cached warning,
/// abort fails the eval test and blocks the build round.
public enum F1Status: Equatable, Sendable {
    /// `f1 >= cleanThreshold` (default 0.95). No warning, no abort.
    case clean
    /// `f1 ∈ [abortThreshold, cleanThreshold)` (default [0.90, 0.95)).
    /// MODEL_QUALITY_WARNING line buffered for CHANGELOG; doctor
    /// surfaces the warn band.
    case warn(Double)
    /// `f1 < abortThreshold` (default 0.90). The eval-test #expect
    /// fails, aborting the build round.
    case abort(Double)
}

/// Threshold logic for the PIIClassifier eval gate (T.2b-2).
/// `f1Status(_:)` is a pure function over a measured / cached F1
/// score; no side effects. Callers (eval harness, doctor, CHANGELOG
/// warn buffer) read the returned band and act.
public enum PIIClassifierEvalGate {
    /// Ship-clean floor. F1 at or above this value is considered
    /// healthy and does not surface a warning.
    public static let cleanThreshold: Double = 0.95

    /// Hard abort floor. F1 below this value aborts the eval test
    /// (`#expect(false)`) and blocks the build round.
    public static let abortThreshold: Double = 0.90

    /// Map a measured F1 to its band. Boundary semantics:
    /// `f1 == 0.95` → `.clean`; `f1 == 0.90` → `.warn(0.90)`.
    public static func f1Status(_ f1: Double) -> F1Status {
        if f1 >= cleanThreshold { return .clean }
        if f1 >= abortThreshold { return .warn(f1) }
        return .abort(f1)
    }

    /// Human-readable band suffix used by doctor + CHANGELOG
    /// formatters. Single source of truth so band wording stays
    /// uniform across surfaces.
    public static func bandLabel(for status: F1Status) -> String {
        switch status {
        case .clean:
            return "clean"
        case .warn(let f):
            return String(format: "warn — target 0.95 — F1 %.3f", f)
        case .abort(let f):
            return String(format: "abort — F1 %.3f below 0.90", f)
        }
    }

    /// The single-line `MODEL_QUALITY_WARNING` message buffered for
    /// the next CHANGELOG entry. Format mirrors existing severity
    /// markers in the repo (`[MODEL_QUALITY_WARNING] <human text>`).
    /// Returns `nil` for `.clean` (no warning to emit).
    public static func changelogWarningLine(modelId: String, status: F1Status) -> String? {
        switch status {
        case .clean:
            return nil
        case .warn(let f):
            return String(
                format: "[MODEL_QUALITY_WARNING] %@: F1 %.3f in warn band [0.90, 0.95) — ship, but plan a fix before the next release.",
                modelId, f
            )
        case .abort(let f):
            return String(
                format: "[MODEL_QUALITY_WARNING] %@: F1 %.3f below abort threshold 0.90 — build round aborted; do not ship.",
                modelId, f
            )
        }
    }
}
