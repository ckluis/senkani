import Foundation

/// One first-run task starter — the verb-first, outcome-oriented entry
/// the Welcome screen surfaces after the user picks a project.
///
/// A "task starter" answers the user's question "what do you want to
/// do?" rather than "which pane do you want?". The starter encodes
/// (a) what the user wants to accomplish, (b) which pane / launch
/// path satisfies it, and (c) whether a chosen project is required
/// before the launch is meaningful.
///
/// Distinct from `ScheduledPreset` (under `Sources/Core/Presets/`),
/// which models cron-style automation jobs.
public struct TaskStarter: Sendable, Identifiable, Equatable {

    /// Concrete launch action a starter resolves to. Welcome wires
    /// each kind to a specific `LaunchCoordinator` call site so the
    /// pane / launch result is deterministic per starter ID.
    public enum Kind: String, Sendable, Equatable {
        /// Opens the Claude Code launch sheet, which then creates a
        /// terminal pane for the chosen Claude command.
        case claude
        /// Opens an Ollama launcher pane (first-class local-LLM surface).
        case ollama
        /// Opens a tracked terminal pane in the project (or `$HOME`
        /// when no project is chosen).
        case trackedShell
        /// Opens the project's code viewer for read-only inspection.
        case inspectProject
    }

    public let id: String
    /// Verb-first label shown on the card. Project-aware suffix is
    /// appended at render time via `displayLabel(for:)`.
    public let label: String
    /// One-line outcome description. No FCSIT/MCP/internal jargon.
    public let subtitle: String
    /// SF Symbol name — must be the icon the matching pane already uses
    /// in `PaneGalleryBuilder` so the starter and the pane it produces
    /// look like the same thing.
    public let icon: String
    /// Concrete launch action this starter resolves to.
    public let kind: Kind
    /// Pane gallery ID this starter ultimately creates. Mirrors
    /// `PaneGalleryEntry.id` so the catalog parity test can assert
    /// every starter resolves to a real pane.
    public let paneTypeID: String
    /// True if this starter is gated on a chosen project. Welcome
    /// disables the card until a project is picked. `trackedShell`
    /// is the deliberate escape hatch (works without a project).
    public let requiresProject: Bool

    public init(
        id: String,
        label: String,
        subtitle: String,
        icon: String,
        kind: Kind,
        paneTypeID: String,
        requiresProject: Bool
    ) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
        self.icon = icon
        self.kind = kind
        self.paneTypeID = paneTypeID
        self.requiresProject = requiresProject
    }

    /// Render a project-aware label. Project-gated starters get
    /// "<verb> ... in <projectName>"; the tracked-shell escape hatch
    /// names "home folder" when no project is chosen.
    public func displayLabel(for projectName: String?) -> String {
        if let name = projectName, !name.isEmpty {
            return "\(label) in \(name)"
        }
        if !requiresProject {
            return "\(label) in home folder"
        }
        return label
    }

    /// Render a project-aware subtitle that surfaces the missing
    /// precondition before it surfaces the outcome.
    public func displaySubtitle(for projectName: String?) -> String {
        if requiresProject, projectName == nil {
            return "Choose a project folder first"
        }
        return subtitle
    }
}

/// First-run task-starter catalog. Order is the canonical render
/// order in the Welcome screen.
///
/// Add a starter only with a Luminary-grade reason: Welcome's job is
/// to onboard to a successful agent session, not to advertise every
/// pane. The advanced "Show all panes" affordance covers the long tail.
public enum TaskStarterCatalog {

    /// Canonical render order. Ask Claude is first because Claude is
    /// the modal first-run agent for new Senkani users; Ollama is the
    /// local alternative; tracked shell is the escape hatch; inspect
    /// is the no-agent path for users who want to read first.
    public static func all() -> [TaskStarter] {
        return [
            TaskStarter(
                id: "ask-claude",
                label: "Ask Claude",
                subtitle: "Start a Claude Code session here",
                icon: "brain",
                kind: .claude,
                paneTypeID: "terminal",
                requiresProject: true
            ),
            TaskStarter(
                id: "use-ollama",
                label: "Use Ollama",
                subtitle: "Run a local LLM here",
                icon: "cpu",
                kind: .ollama,
                paneTypeID: "ollamaLauncher",
                requiresProject: true
            ),
            TaskStarter(
                id: "open-tracked-shell",
                label: "Open a tracked shell",
                subtitle: "A regular terminal Senkani is watching",
                icon: "terminal",
                kind: .trackedShell,
                paneTypeID: "terminal",
                requiresProject: false
            ),
            TaskStarter(
                id: "inspect-project",
                label: "Inspect this project",
                subtitle: "Open the code viewer without launching an agent",
                icon: "doc.text.magnifyingglass",
                kind: .inspectProject,
                paneTypeID: "codeEditor",
                requiresProject: true
            ),
        ]
    }

    /// Lookup by ID. Returns nil for unknown IDs.
    public static func find(_ id: String) -> TaskStarter? {
        all().first { $0.id == id }
    }
}
