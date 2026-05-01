import Foundation

/// Decides which panes to assemble for a given task starter so the
/// first-run user lands on a layout that makes Senkani's value
/// legible without manually opening "Terminal, Analytics, Agent
/// Timeline" themselves.
///
/// First-run = workspace contains no panes yet. Picking "Ask Claude"
/// or "Open a tracked shell" then yields a primary terminal pane
/// PLUS an Agent Timeline insight pane so the user can watch
/// optimization events appear as they work. Picking "Use Ollama"
/// yields the OllamaLauncher (its header IS the proof/status
/// surface), and "Inspect this project" yields the code editor — no
/// extra insight pane in those two cases because the primary pane
/// is already its own insight surface.
///
/// Subsequent launches in an existing workspace yield ONLY the
/// primary pane: clicking "Ask Claude" twice must not stack two
/// agent timelines next to two terminals. Idempotency is also
/// enforced here — if an Agent Timeline already exists in the
/// workspace, we skip the insight pane even on a "first" launch
/// so reopening the Welcome screen after closing every other pane
/// doesn't duplicate it.
public enum FirstValueLayout {

    /// Spec for one pane the layout asks the launcher to add. The
    /// `typeID` strings match `PaneGalleryEntry.id` and the
    /// `paneTypeID` field on `TaskStarter`.
    public struct PaneSpec: Sendable, Equatable {
        public let typeID: String
        public let title: String
        public let role: Role
        public init(typeID: String, title: String, role: Role) {
            self.typeID = typeID
            self.title = title
            self.role = role
        }

        public enum Role: String, Sendable, Equatable {
            /// Pane the user explicitly asked for via the starter.
            case primary
            /// Additional insight surface added on first-run only.
            case insight
        }
    }

    /// Compute the panes to add for `starterKind` given the workspace's
    /// current set of pane type IDs. The result always begins with the
    /// primary pane; an `insight` pane follows only on a true first-run
    /// for starters whose primary pane needs a witness surface.
    public static func assemble(
        for starterKind: TaskStarter.Kind,
        existingPaneTypeIDs: [String]
    ) -> [PaneSpec] {
        let primary = primarySpec(for: starterKind)
        guard shouldIncludeInsight(
            for: starterKind,
            existingPaneTypeIDs: existingPaneTypeIDs
        ) else {
            return [primary]
        }
        return [primary, insightSpec]
    }

    /// True when an empty workspace should welcome the primary pane
    /// with the Agent Timeline insight pane next to it. Claude and
    /// tracked-shell launches benefit from a witness; Ollama and
    /// Inspect already carry their own insight surface.
    public static func shouldIncludeInsight(
        for starterKind: TaskStarter.Kind,
        existingPaneTypeIDs: [String]
    ) -> Bool {
        guard existingPaneTypeIDs.isEmpty else { return false }
        switch starterKind {
        case .claude, .trackedShell:
            return true
        case .ollama, .inspectProject:
            return false
        }
    }

    /// Spec for the insight pane. Pulled out so callers (and tests)
    /// can reference the canonical default title without rebuilding it.
    public static let insightSpec = PaneSpec(
        typeID: "agentTimeline",
        title: "Agent Timeline",
        role: .insight
    )

    private static func primarySpec(for kind: TaskStarter.Kind) -> PaneSpec {
        switch kind {
        case .claude:
            return PaneSpec(typeID: "terminal", title: "Claude Code", role: .primary)
        case .ollama:
            return PaneSpec(typeID: "ollamaLauncher", title: "Ollama", role: .primary)
        case .trackedShell:
            return PaneSpec(typeID: "terminal", title: "Terminal", role: .primary)
        case .inspectProject:
            return PaneSpec(typeID: "codeEditor", title: "Code", role: .primary)
        }
    }
}
