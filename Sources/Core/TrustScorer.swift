import Foundation

/// Aggregates `FragmentationDetector.Flag`s into a 0–100 trust score.
/// Soft-flag round (U.4a): the score is informational only — nothing
/// in the HookRouter denial path reads it. U.4b promotes the score to
/// a blocking gate once operator-collected FP labels prove the
/// detector's signal is clean enough to trust.
public enum TrustScorer {

    /// Per-flag-reason penalty. Tunables; defaults match the U.4a
    /// roadmap. Penalties are deliberately small — a single burst
    /// shouldn't crater a score, but a sustained pattern should.
    public struct Weights: Sendable, Equatable {
        public var toolBurst: Int
        public var fragmentStitch: Int
        public var crossPane: Int
        /// Floor — score never drops below this.
        public var floor: Int
        /// Ceiling — un-flagged input scores `ceiling`. Tests + the UI
        /// expect 100; lower it only if you're inverting the scale.
        public var ceiling: Int

        public init(
            toolBurst: Int = 8,
            fragmentStitch: Int = 12,
            crossPane: Int = 6,
            floor: Int = 0,
            ceiling: Int = 100
        ) {
            self.toolBurst = toolBurst
            self.fragmentStitch = fragmentStitch
            self.crossPane = crossPane
            self.floor = floor
            self.ceiling = ceiling
        }

        public static let `default` = Weights()
    }

    /// Score a list of flags. The algorithm is deliberately stateless
    /// and pure: feed it flags from any time window the caller cares
    /// about. Returns `weights.ceiling` for an empty list.
    public static func score(
        flags: [FragmentationDetector.Flag],
        weights: Weights = .default
    ) -> Int {
        var s = weights.ceiling
        for flag in flags {
            switch flag.reason {
            case .toolBurst:       s -= weights.toolBurst
            case .fragmentStitch:  s -= weights.fragmentStitch
            case .crossPane:       s -= weights.crossPane
            }
        }
        return max(weights.floor, min(weights.ceiling, s))
    }
}
