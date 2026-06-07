import Foundation

/// Deterministic Sprint Review seeder for onboarding walks + dev/test setups.
///
/// Real staged proposals appear only after the daily compound-learning
/// sweep promotes a recurring observation. That sweep is non-deterministic
/// in time, so the `release-v0-3-0-onboarding-pass-milestones-4-7-walk`
/// re-walks could not reliably reach step 6 (Accept/Reject) when the
/// queue happened to be empty.
///
/// `SprintReviewSeedFixture.seed(...)` writes one synthetic
/// `LearnedFilterRule` (status `.staged`) directly into
/// `LearnedRulesStore`. When the operator (or Cowork) opens the Sprint
/// Review pane and clicks Accept or Reject on the row, the existing
/// `SprintReviewViewModel.accept`/`.reject` dispatch fires
/// `OnboardingMilestoneStore.record(.firstStagedProposalReviewed)`
/// through the same call site as a real sweep row would —
/// `Sources/Core/SprintReviewViewModel.swift:242,261`.
///
/// The seeded row is unmistakable in the UI: its id starts with the
/// `seed-fixture-` prefix and its command name is `seed-fixture`,
/// so it cannot be confused with real sweep output.
///
/// Safety: `seed(...)` refuses to run when
/// `firstStagedProposalReviewed` is already recorded in
/// `~/.senkani/onboarding/milestones.json`, unless the caller passes
/// `force: true`. This prevents accidental pollution of a real
/// operator's state on an already-onboarded install.
public enum SprintReviewSeedFixture {

    public enum SeedError: Error, CustomStringConvertible {
        case milestoneAlreadyCompleted
        case storeWriteFailed(underlying: Error)

        public var description: String {
            switch self {
            case .milestoneAlreadyCompleted:
                return "firstStagedProposalReviewed already recorded — refusing to seed. Pass --force to override."
            case .storeWriteFailed(let err):
                return "failed to write learned-rules.json: \(err)"
            }
        }
    }

    /// Seed one staged filter-rule proposal into `LearnedRulesStore`.
    ///
    /// - Parameters:
    ///   - home: override `$HOME` (test/dev path). Default = process HOME.
    ///   - env: override the process environment (used for the
    ///     `SENKANI_ONBOARDING_MILESTONES=off` env-gate check). Default
    ///     = process environment.
    ///   - force: if true, skip the `firstStagedProposalReviewed`
    ///     already-completed guard. Default = false.
    ///   - now: clock injection point. Default = `Date()`.
    /// - Returns: the synthetic id of the seeded row
    ///   (`seed-fixture-<YYYY-MM-DD>-<NNN>`).
    @discardableResult
    public static func seed(
        home: String? = nil,
        env: [String: String]? = nil,
        force: Bool = false,
        now: Date = Date()
    ) throws -> String {
        if !force,
           OnboardingMilestoneStore.isCompleted(
            .firstStagedProposalReviewed, home: home, env: env) {
            throw SeedError.milestoneAlreadyCompleted
        }

        let file = LearnedRulesStore.load() ?? .empty
        let existingIds = Set(file.rules.map(\.id))
        let id = nextSyntheticID(now: now, existingIds: existingIds)

        let rule = LearnedFilterRule(
            id: id,
            command: "seed-fixture",
            subcommand: nil,
            ops: ["head(50)"],
            source: "seed-fixture",
            confidence: 0.85,
            status: .staged,
            sessionCount: 1,
            createdAt: now,
            rationale: "Synthetic Sprint Review fixture — accept or reject to cross the firstStagedProposalReviewed onboarding milestone.",
            signalType: .failure,
            recurrenceCount: 3,
            lastSeenAt: now,
            sources: ["seed-fixture"],
            enrichedRationale: nil
        )

        var artifacts = file.artifacts
        artifacts.append(.filterRule(rule))
        let updated = LearnedRulesFile(
            version: LearnedRulesFile.currentVersion,
            artifacts: artifacts)
        do {
            try LearnedRulesStore.save(updated)
            LearnedRulesStore.reload()
        } catch {
            throw SeedError.storeWriteFailed(underlying: error)
        }
        return id
    }

    /// Build the next available `seed-fixture-<YYYY-MM-DD>-<NNN>` id
    /// for `now`, skipping any ids already present in the store.
    static func nextSyntheticID(now: Date, existingIds: Set<String>) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let datePart = fmt.string(from: now)
        for n in 1...999 {
            let candidate = String(format: "seed-fixture-%@-%03d", datePart, n)
            if !existingIds.contains(candidate) { return candidate }
        }
        // Fallback to a UUID suffix if 999 fixtures already exist on the
        // same day — vanishingly unlikely but cheaper than crashing.
        return "seed-fixture-\(datePart)-\(UUID().uuidString.prefix(8))"
    }
}
