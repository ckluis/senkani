import Foundation
import Core

/// Single entry point for every user-visible pane creation.
///
/// Centralizes the four side effects every launch path must do
/// together — model mutation, project-hook registration, session
/// watcher start, and workspace persistence. Welcome cards, the
/// AddPaneSheet, the Sidebar Claude launch sheet, the command
/// palette, and the pane IPC `.add` action all route through this
/// type. UI code MUST NOT call `WorkspaceModel.addPane(...)`
/// directly — `WorkspaceModel.addPane` remains the pure model
/// mutation, and `LaunchCoordinator.launchPane` owns the side
/// effects on top of it.
///
/// Hook-registration failures are intentionally `try?`-swallowed
/// (matches the previous per-call-site behavior). Surfacing those
/// errors to the user is tracked separately.
///
/// Threading: callers must be on the main thread because they're
/// mutating `WorkspaceModel` (SwiftUI `@State`). UI call sites are
/// already on main; the pane IPC `.add` path dispatches to main
/// before invoking the coordinator. The type isn't `@MainActor`
/// to match the existing `WorkspaceModel.addPane` calling
/// convention so the coordinator slots into both contexts without
/// changing the static IPC handler's actor isolation.
final class LaunchCoordinator {
    let workspace: WorkspaceModel
    let sessions: SessionRegistry
    private let saveWorkspace: () -> Void

    init(
        workspace: WorkspaceModel,
        sessions: SessionRegistry,
        saveWorkspace: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.sessions = sessions
        self.saveWorkspace = saveWorkspace
    }

    /// Launch a new pane and perform every side effect required for
    /// Senkani to be active in it.
    @discardableResult
    func launchPane(
        type: PaneType = .terminal,
        title: String = "Terminal",
        command: String = "",
        previewFilePath: String = ""
    ) -> PaneModel? {
        workspace.addPane(
            type: type,
            title: title,
            command: command,
            previewFilePath: previewFilePath
        )
        guard let pane = workspace.panes.last else { return nil }
        if pane.paneType == .terminal {
            try? HookRegistration.registerForProject(
                at: pane.workingDirectory,
                hookBinaryPath: AutoRegistration.hookWrapperPath
            )
        }
        sessions.startSession(for: pane)
        saveWorkspace()
        return pane
    }
}
