import SwiftUI

/// Tiered-checkbox confirmation sheet for project removal.
///
/// Operator picks per-artifact what to delete. Sidebar entry is
/// always on (disabled checkbox); other artifacts default per the
/// item spec — app-support checked, child worktrees + branches
/// unchecked. Branches with unpushed commits show a warning icon
/// and tooltip; missing worktree dirs render disabled grey.
struct ProjectRemoveSheet: View {
    let project: ProjectModel
    let workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    @State private var options: ProjectRemovalOptions
    @State private var failures: [RemovalFailure] = []
    @State private var unpushedByWorkstream: [UUID: WorktreeGitInspector.UnpushedStatus] = [:]
    @State private var worktreeDirExists: [UUID: Bool] = [:]

    init(project: ProjectModel, workspace: WorkspaceModel) {
        self.project = project
        self.workspace = workspace
        var initialBranch: [UUID: Bool] = [:]
        var initialWtDir: [UUID: Bool] = [:]
        for ws in project.workstreams where !ws.isDefault {
            initialBranch[ws.id] = false
            initialWtDir[ws.id] = false
        }
        _options = State(initialValue: ProjectRemovalOptions(
            removeAppSupportDir: true,
            removeWorktreeDir: initialWtDir,
            removeBranch: initialBranch,
            force: false
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove '\(project.name)'?")
                .font(.system(size: 16, weight: .semibold))

            Text("Pick the artifacts to delete. The sidebar entry is always removed — that's what \"remove\" means.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Sidebar entry (mandatory, disabled).
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.square.fill")
                            .foregroundStyle(.secondary)
                        Text("Sidebar entry")
                            .font(.system(size: 11))
                        Spacer()
                    }

                    // Per-project app-support dir.
                    Toggle(isOn: $options.removeAppSupportDir) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Per-project app-support directory")
                                .font(.system(size: 11))
                            Text(ProjectAppSupport.directory(for: project.id))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)

                    if !project.workstreams.contains(where: { !$0.isDefault }) {
                        Text("No child workstreams to clean up.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    } else {
                        Divider().padding(.vertical, 2)

                        Text("Child workstreams")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)

                        ForEach(project.workstreams.filter { !$0.isDefault }) { ws in
                            workstreamRow(ws)
                        }
                    }

                    if !failures.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text("Failures")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                        ForEach(failures) { f in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.artifact)
                                    .font(.system(size: 10, design: .monospaced))
                                Text(f.reason)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.red)
                            }
                            .padding(.vertical, 2)
                        }
                        Toggle("Force-remove worktree dirs (`git worktree remove --force`)", isOn: $options.force)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10))
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 280)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button(failures.isEmpty ? "Remove" : "Retry") {
                    failures = workspace.removeProject(id: project.id, options: options)
                    if failures.isEmpty {
                        dismiss()
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            for ws in project.workstreams where !ws.isDefault {
                let repoRoot = ws.effectiveRoot(projectPath: project.path)
                if let branch = ws.branch {
                    unpushedByWorkstream[ws.id] = WorktreeGitInspector.unpushedCommits(
                        repoPath: repoRoot,
                        branch: branch
                    )
                }
                if let wtPath = ws.worktreePath {
                    worktreeDirExists[ws.id] = FileManager.default.fileExists(atPath: wtPath)
                }
            }
        }
    }

    @ViewBuilder
    private func workstreamRow(_ ws: WorkstreamModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ws.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            // Worktree dir
            let wtExists = worktreeDirExists[ws.id] ?? true
            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { options.removeWorktreeDir[ws.id] ?? false },
                    set: { options.removeWorktreeDir[ws.id] = $0 }
                )) {
                    Text("Worktree directory")
                        .font(.system(size: 10))
                }
                .toggleStyle(.checkbox)
                .disabled(!wtExists)

                if let wtPath = ws.worktreePath {
                    Text(wtPath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(wtExists ? .secondary : .tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // Branch
            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { options.removeBranch[ws.id] ?? false },
                    set: { options.removeBranch[ws.id] = $0 }
                )) {
                    Text("Feature branch")
                        .font(.system(size: 10))
                }
                .toggleStyle(.checkbox)

                if let branch = ws.branch {
                    Text(branch)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if case .unpushed(let n) = unpushedByWorkstream[ws.id] {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("Branch has \(n) unpushed commit\(n == 1 ? "" : "s")")
                }
                if case .noUpstream = unpushedByWorkstream[ws.id] {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("Branch has no upstream — never pushed")
                }
            }
        }
        .padding(.vertical, 4)
    }
}
