import SwiftUI

/// Tiered-checkbox confirmation sheet for workstream removal.
/// Mirrors `ProjectRemoveSheet` shape — sidebar entry mandatory,
/// worktree-dir checked by default, branch unchecked. Force-remove
/// opt-in appears inline after a non-force attempt fails.
struct WorkstreamRemoveSheet: View {
    let workstream: WorkstreamModel
    let project: ProjectModel
    let workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    @State private var options: WorkstreamRemovalOptions = WorkstreamRemovalOptions(
        removeWorktreeDir: true,
        removeBranch: false,
        force: false
    )
    @State private var failures: [RemovalFailure] = []
    @State private var unpushed: WorktreeGitInspector.UnpushedStatus = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove workstream '\(workstream.name)'?")
                .font(.system(size: 16, weight: .semibold))

            Text("Pick the artifacts to delete. The sidebar entry is always removed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.square.fill")
                        .foregroundStyle(.secondary)
                    Text("Sidebar entry")
                        .font(.system(size: 11))
                    Spacer()
                }

                if let wtPath = workstream.worktreePath {
                    Toggle(isOn: $options.removeWorktreeDir) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Worktree directory")
                                .font(.system(size: 11))
                            Text(wtPath)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)
                }

                if let branch = workstream.branch {
                    Toggle(isOn: $options.removeBranch) {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Feature branch")
                                    .font(.system(size: 11))
                                Text(branch)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            if case .unpushed(let n) = unpushed {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .help("Branch has \(n) unpushed commit\(n == 1 ? "" : "s")")
                            }
                            if case .noUpstream = unpushed {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .help("Branch has no upstream — never pushed")
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            if !failures.isEmpty {
                Divider()
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
                }
                Toggle("Force-remove worktree dir (`git worktree remove --force`)", isOn: $options.force)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button(failures.isEmpty ? "Remove" : "Retry") {
                    failures = workspace.removeWorkstream(
                        id: workstream.id,
                        from: project,
                        options: options
                    )
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
        .frame(width: 420)
        .task {
            if let branch = workstream.branch {
                let repoRoot = workstream.effectiveRoot(projectPath: project.path)
                unpushed = WorktreeGitInspector.unpushedCommits(repoPath: repoRoot, branch: branch)
            }
        }
    }
}
