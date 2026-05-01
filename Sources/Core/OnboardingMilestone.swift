import Foundation

/// Early-use milestone the local milestone tracker records.
///
/// The seven milestones are the events Torres / Swyx flagged in the
/// onboarding-p2-early-use-milestones synthesis as the moments a new
/// user crosses from "did Senkani install correctly?" into "is Senkani
/// useful?". Recording when each one fires gives us a local,
/// privacy-preserving signal of where users reach value and where they
/// stall — without sending any telemetry off-machine.
///
/// Order in this enum is the order users typically hit the milestones,
/// and is the order ``OnboardingMilestoneProgression/order`` exposes.
public enum OnboardingMilestone: String, Sendable, Equatable, CaseIterable, Codable {
    /// User picked a project folder — the precondition for every
    /// tracked starter.
    case projectSelected
    /// User launched any task starter (Claude, Ollama, tracked shell,
    /// inspect-project) for the first time.
    case agentLaunched
    /// First token event landed in `SessionDatabase` for this user.
    case firstTrackedEvent
    /// `FeatureSavings` reported a non-zero compressed-token saving
    /// for the first time.
    case firstNonzeroSavings
    /// User saved a non-default `BudgetConfig` for the first time.
    case firstBudgetSet
    /// User created the first non-default workstream.
    case firstWorkstreamCreated
    /// User reviewed (approved or rejected) the first staged proposal
    /// in `SprintReviewPane`.
    case firstStagedProposalReviewed
}

/// Copy table for each milestone — the literal title, the populating
/// event ("what makes this milestone happen?"), and the imperative
/// next-action the UI surfaces.
///
/// Lives in Core so `OnboardingMilestoneTests` can pin every entry
/// without linking SwiftUI.
public enum OnboardingMilestoneCopy {

    public struct Entry: Sendable, Equatable {
        public let milestone: OnboardingMilestone
        public let title: String
        public let populatingEvent: String
        public let nextAction: String

        public init(
            milestone: OnboardingMilestone,
            title: String,
            populatingEvent: String,
            nextAction: String
        ) {
            self.milestone = milestone
            self.title = title
            self.populatingEvent = populatingEvent
            self.nextAction = nextAction
        }
    }

    public static let projectSelected = Entry(
        milestone: .projectSelected,
        title: "Pick a project",
        populatingEvent:
            "Recorded the moment you choose a project folder from the Welcome screen.",
        nextAction:
            "Choose a project folder so Senkani knows where to install hooks."
    )

    public static let agentLaunched = Entry(
        milestone: .agentLaunched,
        title: "Launch your first agent",
        populatingEvent:
            "Recorded when any task starter (Claude, Ollama, tracked shell, inspect) launches for the first time.",
        nextAction:
            "Pick a task starter on the Welcome screen — Claude is the fastest path to first value."
    )

    public static let firstTrackedEvent = Entry(
        milestone: .firstTrackedEvent,
        title: "Watch a tool call get tracked",
        populatingEvent:
            "Recorded the moment Senkani logs the first compressed tool call from your session.",
        nextAction:
            "Run any Claude command — events should appear in the Agent Timeline within a second."
    )

    public static let firstNonzeroSavings = Entry(
        milestone: .firstNonzeroSavings,
        title: "Save your first tokens",
        populatingEvent:
            "Recorded the first time the optimizer pipeline reports a non-zero compressed-token saving.",
        nextAction:
            "Ask Claude to read a few files — the Filter and Cache layers usually save tokens within the first session."
    )

    public static let firstBudgetSet = Entry(
        milestone: .firstBudgetSet,
        title: "Set a budget",
        populatingEvent:
            "Recorded when you save a non-default budget for the project or pane.",
        nextAction:
            "Open Settings → Budgets and pick a daily token limit — the dual-layer enforcement keeps runaway sessions in check."
    )

    public static let firstWorkstreamCreated = Entry(
        milestone: .firstWorkstreamCreated,
        title: "Create a workstream",
        populatingEvent:
            "Recorded the first time you create a named workstream beyond the default.",
        nextAction:
            "Use the Workstreams sidebar to group related panes — useful once you're juggling more than one task."
    )

    public static let firstStagedProposalReviewed = Entry(
        milestone: .firstStagedProposalReviewed,
        title: "Review a staged proposal",
        populatingEvent:
            "Recorded after you approve or reject the first staged proposal in Sprint Review.",
        nextAction:
            "Open Sprint Review after a few sessions — the daily sweep stages compound-learning proposals automatically."
    )

    /// Lookup by milestone — every milestone has an entry. Tests pin
    /// the table by iterating `OnboardingMilestone.allCases` so a new
    /// case can't ship without copy.
    public static func entry(for milestone: OnboardingMilestone) -> Entry {
        switch milestone {
        case .projectSelected:             return projectSelected
        case .agentLaunched:               return agentLaunched
        case .firstTrackedEvent:           return firstTrackedEvent
        case .firstNonzeroSavings:         return firstNonzeroSavings
        case .firstBudgetSet:              return firstBudgetSet
        case .firstWorkstreamCreated:      return firstWorkstreamCreated
        case .firstStagedProposalReviewed: return firstStagedProposalReviewed
        }
    }
}
