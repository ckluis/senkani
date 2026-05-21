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

    /// Remove a project and all its panes (in-memory only).
    /// Prefer `removeProject(id:options:)` for the tiered-checkbox
    /// destructive flow; this overload is kept for the small number
    /// of callsites that only need the in-memory drop.
    func removeProject(id: UUID) {
        _ = removeProject(id: id, options: .none)
    }

    /// Tiered project removal. Honors `ProjectRemovalOptions` flags
    /// per-artifact and executes in a fixed order so partial failures
    /// are deterministic and recoverable:
    ///
    ///   1. Worktree directories (one per opted-in workstream)
    ///   2. Branches (one per opted-in workstream)
    ///   3. Per-project app-support directory
    ///   4. In-memory model removal (sidebar entry) — DEFERRED.
    ///
    /// Worktree-first ordering (`remove-step-ordering-worktree-before-
    /// branch-2026-05-21`, shipped 2026-05-21) lets a dual-toggle
    /// force-retry heal in ONE call: removing the worktree detaches
    /// the branch from it, so `git branch -D` then succeeds against a
    /// no-longer-checked-out branch. Pre-fix ordering (branch-first)
    /// required the operator to deselect the branch toggle, retry to
    /// remove the worktree, re-tick the branch toggle, and retry a
    /// third time — three operator clicks per workstream.
    ///
    /// Each step's failure is collected into the returned array; the
    /// dialog shows them inline and lets the operator opt in to
    /// `force: true` and retry. The in-memory removal (step 4) is the
    /// LAST step and only fires when every opted-in artifact has been
    /// deleted — i.e. `failures.isEmpty` at the boundary. This ensures
    /// retry-after-failure can re-resolve the project via `id` and re-
    /// run the artifact steps; otherwise the sidebar entry would be
    /// dropped on call N and the retry's `guard let project = projects
    /// .first(...)` would short-circuit, leaving the artifacts on disk.
    /// The dialog still renders the sidebar-entry row as the always-on
    /// disabled-checked checkbox; "always" means "always, once all the
    /// opted-in artifacts are gone."
    ///
    /// Steps 1 and 2 are also IDEMPOTENT: each step pre-checks that
    /// its target still exists (`FileManager.fileExists` for worktree
    /// paths, `WorktreeGitInspector.branchExists` for branches) and
    /// treats "already gone" as a no-op success. Without these guards,
    /// a partial-success retry re-running a step against an artifact
    /// the prior call already deleted would surface a spurious
    /// RemovalFailure.
    @discardableResult
    func removeProject(id: UUID, options: ProjectRemovalOptions) -> [RemovalFailure] {
        guard let project = projects.first(where: { $0.id == id }) else { return [] }
        var failures: [RemovalFailure] = []
        let fm = FileManager.default

        // Step 1: worktree dirs. Default workstream's "worktree" is
        // the project root itself — never remove that here.
        // Worktree-first ordering: removing the worktree detaches the
        // branch from it, so the Step 2 branch-delete can succeed
        // against a no-longer-checked-out branch in the same call
        // when both force toggles are on.
        // Partial-success retry idempotency: skip paths that no longer
        // exist so a re-run doesn't surface a spurious failure for an
        // already-cleaned worktree.
        for ws in project.workstreams {
            guard options.removeWorktreeDir[ws.id] == true,
                  let wtPath = ws.worktreePath,
                  !ws.isDefault else { continue }
            guard fm.fileExists(atPath: wtPath) else { continue }
            let res = GitWorktreeManager.removeWorktree(path: wtPath, force: options.force)
            if case .failure(let err) = res {
                failures.append(RemovalFailure(
                    artifact: wtPath,
                    reason: err.errorDescription ?? "unknown git worktree error"
                ))
            }
        }

        // Step 2: branches (in deterministic workstream order).
        // Same idempotency rule: skip branches that no longer exist
        // (a prior call's step succeeded; this call's re-run would
        // otherwise surface `branch '<gone>' not found` as a spurious
        // RemovalFailure).
        for ws in project.workstreams {
            guard options.removeBranch[ws.id] == true,
                  let branch = ws.branch else { continue }
            let repoRoot = ws.effectiveRoot(projectPath: project.path)
            guard WorktreeGitInspector.branchExists(repoPath: repoRoot, branch: branch) else { continue }
            if let err = WorktreeGitInspector.deleteBranch(repoPath: repoRoot, branch: branch) {
                failures.append(RemovalFailure(artifact: branch, reason: err))
            }
        }

        // Step 3: per-project app-support dir.
        if options.removeAppSupportDir {
            let dir = ProjectAppSupport.directory(for: project.id)
            if fm.fileExists(atPath: dir) {
                do {
                    try fm.removeItem(atPath: dir)
                } catch {
                    failures.append(RemovalFailure(
                        artifact: dir,
                        reason: error.localizedDescription
                    ))
                }
            }
        }

        // Step 4: sidebar / in-memory — DEFERRED until every opted-in
        // artifact step succeeded. Without this guard, a failed step
        // 1/2/3 would still drop the in-memory entry, and the retry
        // path would short-circuit at the top-of-function guard-let.
        guard failures.isEmpty else { return failures }
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
        return failures
    }

    /// Tiered workstream removal. Honors `WorkstreamRemovalOptions`
    /// flags per-artifact and executes in a fixed order:
    ///
    ///   1. Worktree directory
    ///   2. Branch
    ///   3. Sidebar / in-memory — DEFERRED (delegated to
    ///      `ProjectModel.removeWorkstream`)
    ///
    /// Worktree-first ordering (`remove-step-ordering-worktree-before-
    /// branch-2026-05-21`, shipped 2026-05-21) lets a dual-toggle
    /// force-retry heal in ONE call: removing the worktree detaches
    /// the branch from it, so `git branch -D` then succeeds against a
    /// no-longer-checked-out branch.
    ///
    /// The in-memory step is the LAST step and only fires when every
    /// opted-in artifact has been deleted — i.e. `failures.isEmpty`
    /// at the boundary. Without this guard the sidebar entry would
    /// drop on call N and the retry's top-of-function `guard let ws
    /// = project.workstreams.first(...)` would short-circuit,
    /// returning `[]` and leaving the branch + worktree on disk.
    ///
    /// The in-memory step respects the existing default-workstream
    /// and last-workstream invariants — it refuses to drop either,
    /// and surfaces that refusal as a `RemovalFailure` so the dialog
    /// can show the operator why the row stayed.
    ///
    /// Steps 1 and 2 are also IDEMPOTENT: each step pre-checks that
    /// its target still exists and treats "already gone" as a no-op
    /// success. Without these guards, a partial-success retry re-
    /// running a step against an already-cleaned artifact would
    /// surface a spurious `RemovalFailure`.
    @discardableResult
    func removeWorkstream(id workstreamID: UUID, from project: ProjectModel, options: WorkstreamRemovalOptions) -> [RemovalFailure] {
        guard let ws = project.workstreams.first(where: { $0.id == workstreamID }) else { return [] }
        var failures: [RemovalFailure] = []

        // Step 1: worktree dir.
        // Worktree-first ordering lets a dual-toggle force-retry heal
        // in one call: removing the worktree detaches the branch from
        // it, so Step 2 below can succeed against a no-longer-checked-
        // out branch in the same retry call.
        // Partial-success retry idempotency: skip artifact steps whose
        // target is already gone (a prior call's step succeeded; re-
        // running it would surface a spurious failure for the cleaned
        // artifact). Mirrors the same guards in `removeProject`.
        if options.removeWorktreeDir, let wtPath = ws.worktreePath, !ws.isDefault {
            if FileManager.default.fileExists(atPath: wtPath) {
                let res = GitWorktreeManager.removeWorktree(path: wtPath, force: options.force)
                if case .failure(let err) = res {
                    failures.append(RemovalFailure(
                        artifact: wtPath,
                        reason: err.errorDescription ?? "unknown git worktree error"
                    ))
                }
            }
        }

        // Step 2: branch.
        if options.removeBranch, let branch = ws.branch {
            let repoRoot = ws.effectiveRoot(projectPath: project.path)
            if WorktreeGitInspector.branchExists(repoPath: repoRoot, branch: branch) {
                if let err = WorktreeGitInspector.deleteBranch(repoPath: repoRoot, branch: branch) {
                    failures.append(RemovalFailure(artifact: branch, reason: err))
                }
            }
        }

        // Step 3: sidebar — DEFERRED until every opted-in artifact step
        // succeeded. Without this guard, a failed step 1/2 would still
        // drop the in-memory entry, and the retry path's top-of-function
        // `guard let ws = project.workstreams.first(...)` would short-
        // circuit, returning `[]` and leaving the branch + worktree on
        // disk (sidebar-already-mutated regression — fix landed
        // 2026-05-21).
        guard failures.isEmpty else { return failures }
        let removed = project.removeWorkstream(id: workstreamID)
        if !removed {
            failures.append(RemovalFailure(
                artifact: ws.name,
                reason: "Cannot remove the default or only workstream of a project."
            ))
        } else if project.activeWorkstreamID != nil, let pane = project.activeWorkstream?.panes.first {
            activePaneID = pane.id
        }
        return failures
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
    ///
    /// `branch` lets the create sheet honor an operator-provided
    /// branch name override (Finding #E disclosure UX). When nil,
    /// `GitWorktreeManager.createWorktree` auto-generates
    /// `feature/<YYYYMMDD>-<slug>` and we mirror that here for the
    /// model record.
    @discardableResult
    func addWorkstream(name: String, branch: String? = nil, to project: ProjectModel) -> Result<WorkstreamModel, GitWorktreeManager.GitError> {
        let slug = GitWorktreeManager.slugify(name)

        let result = GitWorktreeManager.createWorktree(
            projectRoot: project.path,
            slug: slug,
            branch: branch
        )

        switch result {
        case .success(let worktreePath):
            let branchName: String
            if let override = branch, !override.isEmpty {
                branchName = override
            } else {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyyMMdd"
                branchName = "feature/\(fmt.string(from: Date()))-\(slug)"
            }

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
