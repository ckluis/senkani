import Foundation

/// Pure derivation: given the set of completed milestones, decide
/// what to surface next.
///
/// Lives next to ``OnboardingMilestone`` so the UI surface (the
/// Welcome banner) reads the same canonical "next" ordering tests
/// pin. No I/O: callers pass the completed set in.
public enum OnboardingMilestoneProgression {

    /// The canonical surfacing order for the seven milestones. The
    /// next-step banner walks this list and emits the first entry
    /// that hasn't fired yet. Order matches
    /// ``OnboardingMilestone.allCases``.
    public static let order: [OnboardingMilestone] = OnboardingMilestone.allCases

    /// Compact summary for the UI banner.
    public struct Summary: Sendable, Equatable {
        public let totalCount: Int
        public let completedCount: Int
        /// First milestone in ``order`` that hasn't been observed yet.
        /// Nil when every milestone has fired — the UI hides the
        /// banner in that state.
        public let next: OnboardingMilestone?
        /// Convenience: the canonical copy entry for ``next``, or nil
        /// when nothing is left.
        public let nextEntry: OnboardingMilestoneCopy.Entry?
        /// True when every milestone in ``order`` has fired.
        public let allComplete: Bool
        /// Compact "1 of 7" / "7 of 7" string. Stable formatting so
        /// tests can pin it.
        public let progressLabel: String

        public init(
            totalCount: Int,
            completedCount: Int,
            next: OnboardingMilestone?,
            nextEntry: OnboardingMilestoneCopy.Entry?,
            allComplete: Bool,
            progressLabel: String
        ) {
            self.totalCount = totalCount
            self.completedCount = completedCount
            self.next = next
            self.nextEntry = nextEntry
            self.allComplete = allComplete
            self.progressLabel = progressLabel
        }
    }

    /// Compute the next milestone the UI should surface, given a set
    /// of completed milestones. Returns nil when every milestone has
    /// fired.
    public static func next(
        after completed: Set<OnboardingMilestone>
    ) -> OnboardingMilestone? {
        for milestone in order {
            if !completed.contains(milestone) { return milestone }
        }
        return nil
    }

    /// Build a summary for the UI banner from a set of completed
    /// milestones.
    public static func summary(
        completed: Set<OnboardingMilestone>
    ) -> Summary {
        let total = order.count
        let count = completed.intersection(Set(order)).count
        let nextMilestone = next(after: completed)
        let nextEntry = nextMilestone.map(OnboardingMilestoneCopy.entry(for:))
        return Summary(
            totalCount: total,
            completedCount: count,
            next: nextMilestone,
            nextEntry: nextEntry,
            allComplete: nextMilestone == nil,
            progressLabel: "\(count) of \(total)"
        )
    }

    /// Time-to-first-win: elapsed time between two milestone
    /// timestamps. Returns nil if either timestamp is missing or if
    /// `to` is earlier than `from`. Used by the manual-log research
    /// script and by ad-hoc local analysis — there is no automated
    /// telemetry path that reads it.
    public static func elapsed(
        from: OnboardingMilestone,
        to: OnboardingMilestone,
        in completed: [OnboardingMilestone: Date]
    ) -> TimeInterval? {
        guard let start = completed[from], let end = completed[to] else {
            return nil
        }
        let delta = end.timeIntervalSince(start)
        return delta >= 0 ? delta : nil
    }
}
