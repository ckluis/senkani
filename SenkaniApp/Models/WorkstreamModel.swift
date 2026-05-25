import Foundation
import Core

/// A single workstream within a project group.
/// The default workstream uses the project root path; non-default workstreams
/// use git worktrees at `.worktrees/<slug>`.
///
/// Every ProjectGroup always has ≥1 workstream (the default).
/// This invariant is enforced by ProjectGroup's init and removeWorkstream().
@Observable
final class WorkstreamModel: Identifiable {
    let id: UUID
    var name: String
    /// True for the auto-created workstream that wraps the project's main branch.
    var isDefault: Bool
    /// Git branch name (detected or user-specified).
    var branch: String?
    /// Absolute path to git worktree. nil = use parent project's root path.
    var worktreePath: String?
    /// Panes belonging to this workstream.
    var panes: [PaneModel] = []
    /// Whether this is the currently active workstream in its project.
    var isActive: Bool = false
    /// Core-layer runtime lifecycle record (U.11-pre a-2). `nil` for
    /// rows that pre-date the v37 migration adoption — the App layer
    /// is migrating in place and existing models populate this slot
    /// lazily as `PaneSessionDriver` drives them. The canonical
    /// persisted copy lives in the SQLite `workstreams` table; this
    /// slot is the in-memory mirror for SwiftUI binding.
    var lifecycle: WorkstreamLifecycle?

    init(id: UUID = UUID(),
         name: String = "default",
         isDefault: Bool = true,
         branch: String? = nil,
         worktreePath: String? = nil,
         panes: [PaneModel] = [],
         lifecycle: WorkstreamLifecycle? = nil) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.branch = branch
        self.worktreePath = worktreePath
        self.panes = panes
        self.lifecycle = lifecycle
    }

    /// The effective working directory for panes in this workstream.
    /// Returns worktreePath if set, otherwise the project root must be provided.
    func effectiveRoot(projectPath: String) -> String {
        worktreePath ?? projectPath
    }
}
