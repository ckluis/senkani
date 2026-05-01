import Foundation
import SwiftUI
import Core

/// Manages the collection of projects and panes in the workspace.
/// Backward compatible: if no projects exist, a single implicit "Default"
/// project is created and all panes live there.
@Observable
final class WorkspaceModel {
    var projects: [ProjectModel] = []
    var activeProjectID: UUID?
    var activePaneID: UUID?
    var sessionStart = Date()

    /// The currently active project (or the implicit default).
    var activeProject: ProjectModel? {
        if let id = activeProjectID {
            return projects.first { $0.id == id }
        }
        return projects.first
    }

    /// All panes across all projects (used for global metrics).
    var allPanes: [PaneModel] {
        projects.flatMap { $0.panes }
    }

    /// Panes for the active project only (shown in the canvas).
    var panes: [PaneModel] {
        get { activeProject?.panes ?? [] }
        set {
            if let project = activeProject {
                project.panes = newValue
            }
        }
    }

    var activePaneIndex: Int? {
        guard let id = activePaneID else { return nil }
        return panes.firstIndex { $0.id == id }
    }

    // MARK: - Project management

    /// Add a new project from a directory path.
    /// Returns the project on success, nil if validation fails.
    @discardableResult
    func addProject(path: String) -> ProjectModel? {
        guard let project = try? ProjectModel.create(path: path) else { return nil }
        projects.append(project)
        switchToProject(id: project.id)
        OnboardingMilestoneStore.record(.projectSelected)
        return project
    }

    /// Switch the active project.
    func switchToProject(id: UUID) {
        // Deactivate all
        for p in projects { p.isActive = false }
        // Activate selected
        if let project = projects.first(where: { $0.id == id }) {
            project.isActive = true
            activeProjectID = id
            // Set active pane to the first pane in the new project (or nil)
            activePaneID = project.panes.first?.id
        }
    }

    /// Switch to a specific workstream within the active project.
    func switchWorkstream(to workstreamID: UUID) {
        guard let project = activeProject else { return }
        project.switchWorkstream(to: workstreamID)
        activePaneID = project.activeWorkstream?.panes.first?.id
    }

    /// Remove a project and all its panes.
    func removeProject(id: UUID) {
        projects.removeAll { $0.id == id }
        if activeProjectID == id {
            activeProjectID = projects.first?.id
            if let first = projects.first {
                first.isActive = true
                activePaneID = first.panes.first?.id
            } else {
                activePaneID = nil
            }
        }
    }

    // MARK: - Pane management (adds to active project)

    /// Ensure at least one project exists (the implicit default).
    /// Uses trustedPath since NSHomeDirectory() is always a valid, readable directory.
    private func ensureDefaultProject() {
        if projects.isEmpty {
            let project = ProjectModel(name: "Default", trustedPath: NSHomeDirectory())
            projects.append(project)
            project.isActive = true
            activeProjectID = project.id
        }
    }

    func addPane(type: PaneType = .terminal, title: String = "Terminal", command: String = "", previewFilePath: String = "") {
        ensureDefaultProject()
        let projectPath = activeProject?.path ?? NSHomeDirectory()
        // Use the active workstream's effective root (worktree path or project path)
        let effectiveRoot = activeProject?.activeWorkstream?.effectiveRoot(projectPath: projectPath) ?? projectPath
        let pane = PaneModel(title: title, paneType: type, initialCommand: command, workingDirectory: effectiveRoot, previewFilePath: previewFilePath)
        activeProject?.panes.append(pane)
        activePaneID = pane.id
    }

    /// Create a new workstream with git worktree. Full-auto: creates worktree + terminal pane.
    /// Returns the created WorkstreamModel on success, or a GitError on failure.
    @discardableResult
    func addWorkstream(name: String, to project: ProjectModel) -> Result<WorkstreamModel, GitWorktreeManager.GitError> {
        let slug = GitWorktreeManager.slugify(name)

        let result = GitWorktreeManager.createWorktree(
            projectRoot: project.path,
            slug: slug,
            branch: nil
        )

        switch result {
        case .success(let worktreePath):
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            let branchName = "feature/\(fmt.string(from: Date()))-\(slug)"

            let ws = WorkstreamModel(
                name: name,
                isDefault: false,
                branch: branchName,
                worktreePath: worktreePath
            )
            // Auto-create a terminal pane in the worktree
            let pane = PaneModel(
                title: "Terminal",
                paneType: .terminal,
                workingDirectory: worktreePath
            )
            ws.panes.append(pane)
            project.addWorkstream(ws)
            activePaneID = pane.id
            OnboardingMilestoneStore.record(.firstWorkstreamCreated)
            return .success(ws)

        case .failure(let error):
            return .failure(error)
        }
    }

    func movePane(id: UUID, toIndex: Int) {
        guard let project = activeProject,
              let fromIndex = project.panes.firstIndex(where: { $0.id == id }),
              fromIndex != toIndex,
              toIndex >= 0, toIndex < project.panes.count else { return }
        let pane = project.panes.remove(at: fromIndex)
        project.panes.insert(pane, at: toIndex)
    }

    func removePane(id: UUID) {
        for project in projects {
            project.panes.removeAll { $0.id == id }
        }
        if activePaneID == id {
            activePaneID = panes.last?.id
        }
    }

    func navigateToPane(index: Int) {
        guard index < panes.count else { return }
        activePaneID = panes[index].id
    }

    // MARK: - Global metrics (across all projects)

    var totalSavedBytes: Int {
        allPanes.reduce(0) { $0 + $1.metrics.savedBytes }
    }

    var totalRawBytes: Int {
        allPanes.reduce(0) { $0 + $1.metrics.totalRawBytes }
    }

    var globalSavingsPercent: Double {
        guard totalRawBytes > 0 else { return 0 }
        return Double(totalSavedBytes) / Double(totalRawBytes) * 100
    }

    var sessionDuration: String {
        let elapsed = Date().timeIntervalSince(sessionStart)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        return "\(minutes)m"
    }

    var formattedTotalSavings: String {
        let bytes = totalSavedBytes
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }

    /// Estimated cost saved using the active model's pricing.
    var estimatedCostSaved: String {
        let cost = ModelPricing.costSaved(bytes: totalSavedBytes)
        return String(format: "$%.2f saved", cost)
    }
}
