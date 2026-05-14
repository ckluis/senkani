import Foundation

/// Per-artifact opt-in list for the project-remove flow. The dialog
/// builds one of these from the operator's tiered checkboxes and
/// passes it to `WorkspaceModel.removeProject(id:options:)`. The
/// sidebar entry is always removed — that's what "remove" means; the
/// dialog renders it as a disabled checked checkbox so the operator
/// can SEE what's mandatory.
///
/// Per-workstream options are keyed by workstream UUID so multiple
/// child workstreams can be opted-in or skipped independently.
struct ProjectRemovalOptions {
    var removeAppSupportDir: Bool
    var removeWorktreeDir: [UUID: Bool]
    var removeBranch: [UUID: Bool]
    /// Force-remove worktree dirs (`git worktree remove --force`).
    /// Operator must explicitly opt in via the dialog's force checkbox
    /// after a non-force attempt fails — never auto-force.
    var force: Bool

    static let none = ProjectRemovalOptions(
        removeAppSupportDir: false,
        removeWorktreeDir: [:],
        removeBranch: [:],
        force: false
    )
}

/// Per-artifact opt-in for the workstream-remove flow.
struct WorkstreamRemovalOptions {
    var removeWorktreeDir: Bool
    var removeBranch: Bool
    var force: Bool

    static let none = WorkstreamRemovalOptions(
        removeWorktreeDir: false,
        removeBranch: false,
        force: false
    )
}

/// One failure surfaced from a tiered remove operation. The dialog
/// shows these inline so the operator knows which artifact failed
/// and can decide whether to retry with `force: true` or cancel.
struct RemovalFailure: Identifiable {
    let id = UUID()
    let artifact: String      // human-readable: ".worktrees/foo", "feature/20260514-foo"
    let reason: String        // stderr or localized error
}

/// Per-project app-support directory convention. Today no code writes
/// to this path; the cleanup contract honors it anyway so that any
/// future writer (per-project sessions DB, per-project caches) is
/// torn down by the same checkbox the operator already approves. The
/// dialog shows the resolved absolute path so operators can verify.
enum ProjectAppSupport {
    /// Resolves to `~/Library/Application Support/Senkani/projects/<id>/`.
    static func directory(for projectID: UUID) -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return appSupport
            .appendingPathComponent("Senkani", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .path
    }
}
