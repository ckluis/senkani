import Foundation

/// Copy + a single concrete next action for each early-use pane's
/// empty state.
///
/// Onboarding P2 wants the first-time user to never face a "No
/// data yet" wall without a clear reason to invest a click. Empty
/// states explain the *exact* event that populates them and offer
/// one concrete next step — usually a starter to launch — rather
/// than passively waiting.
///
/// Strings live in Core so SenkaniTests can pin the contract
/// without linking SwiftUI.
public enum EmptyStateGuidance {

    /// One pane's empty-state copy. `headline` names the state
    /// ("No models configured"); `populatingEvent` describes the
    /// event that flips it from empty to populated; `nextAction`
    /// is the imperative the empty state shows as a CTA.
    public struct Entry: Sendable, Equatable {
        public let surface: Surface
        public let headline: String
        public let populatingEvent: String
        public let nextAction: String

        public init(
            surface: Surface,
            headline: String,
            populatingEvent: String,
            nextAction: String
        ) {
            self.surface = surface
            self.headline = headline
            self.populatingEvent = populatingEvent
            self.nextAction = nextAction
        }
    }

    /// Surfaces this round audited. Pinned as an enum so tests fail
    /// loudly if a new pane is added without an empty-state entry.
    public enum Surface: String, Sendable, CaseIterable, Equatable {
        case analytics
        case knowledgeBase
        case modelManager
        case sprintReview
    }

    public static let analytics = Entry(
        surface: .analytics,
        headline: "No tracked sessions yet",
        populatingEvent:
            "Charts populate the moment a tracked Claude or shell session emits its first compressed tool call.",
        nextAction:
            "Launch a tracked session from the Welcome screen — savings appear within seconds."
    )

    public static let knowledgeBase = Entry(
        surface: .knowledgeBase,
        headline: "No entities yet",
        populatingEvent:
            "Entities are extracted automatically when Claude mentions a project component (file, module, person, decision) across sessions.",
        nextAction:
            "Run a tracked Claude session and ask about the codebase — the first entities land here within one session."
    )

    public static let modelManager = Entry(
        surface: .modelManager,
        headline: "No local models installed",
        populatingEvent:
            "Models appear here once Ollama is running and at least one model has been pulled (or once Senkani's bundled Gemma weights are downloaded).",
        nextAction:
            "Install Ollama, then run `ollama pull qwen3:1.7b` — the model registers here automatically."
    )

    public static let sprintReview = Entry(
        surface: .sprintReview,
        headline: "No staged proposals",
        populatingEvent:
            "Proposals stage automatically when the daily sweep promotes a recurring artifact past its confidence threshold.",
        nextAction:
            "Use Senkani for a few sessions; the first staged proposal usually appears within 24 hours of the first sweep."
    )

    /// Lookup by surface — returns the canonical entry for each
    /// surface. Tests use this to pin every surface present.
    public static func entry(for surface: Surface) -> Entry {
        switch surface {
        case .analytics:     return analytics
        case .knowledgeBase: return knowledgeBase
        case .modelManager:  return modelManager
        case .sprintReview:  return sprintReview
        }
    }
}
