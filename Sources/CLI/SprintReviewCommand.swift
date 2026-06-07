import ArgumentParser
import Foundation
import Core

// MARK: - sprint-review (root command)

struct SprintReview: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sprint-review",
        abstract: "Developer + onboarding-walk tooling for the Sprint Review pane.",
        subcommands: [SprintReviewSeedFixtureCommand.self]
    )
}

// MARK: - sprint-review seed-fixture

struct SprintReviewSeedFixtureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seed-fixture",
        abstract: "Seed one synthetic staged proposal so onboarding walks can reach Accept/Reject deterministically.",
        discussion: """
        Writes a `LearnedFilterRule` with status `.staged` and a clearly
        synthetic id (`seed-fixture-<date>-<NNN>`) into
        `~/.senkani/learned-rules.json`. The next time SenkaniApp opens
        the Sprint Review pane, the row will appear and Accept/Reject
        will fire the existing `firstStagedProposalReviewed` milestone
        through the same call site as a real sweep row.

        Refuses to run if `firstStagedProposalReviewed` is already
        recorded for this user, unless `--force` is passed. The seeded
        id and command name (`seed-fixture`) make the row visually
        unmistakable in the UI.

        Canonical step-5 unblocker for the
        `release-v0-3-0-onboarding-pass-milestones-4-7-walk` re-walks
        (see `tools/soak/manual-log.md`).
        """
    )

    @Flag(name: .long, help: "Seed even when firstStagedProposalReviewed is already recorded.")
    var force: Bool = false

    func run() throws {
        do {
            let id = try SprintReviewSeedFixture.seed(force: force)
            print("Seeded staged proposal '\(id)'.")
            print("Open Sprint Review in SenkaniApp and click Accept or Reject to cross the firstStagedProposalReviewed milestone.")
        } catch SprintReviewSeedFixture.SeedError.milestoneAlreadyCompleted {
            // Match the convention used by other CLI commands —
            // FileHandle.standardError + non-zero exit.
            FileHandle.standardError.write(Data("error: firstStagedProposalReviewed is already recorded. Pass --force to override (will seed a row anyway).\n".utf8))
            throw ExitCode.failure
        }
    }
}
