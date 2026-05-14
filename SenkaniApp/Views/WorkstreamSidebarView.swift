import SwiftUI

/// Second sidebar showing workstreams for the active project.
/// Visible whenever a project is active — the "+ New Workstream"
/// button is the discoverability surface for the
/// `firstWorkstreamCreated` onboarding milestone, so the sidebar
/// must render on a fresh install (count == 1) too.
struct WorkstreamSidebarView: View {
    let project: ProjectModel
    let workspace: WorkspaceModel
    @State private var showNewSheet = false
    @State private var hoveredWorkstreamID: UUID?
    @State private var removalTarget: WorkstreamModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("WORKSTREAMS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                Spacer()
                Text("\(project.workstreams.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Workstream list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(project.workstreams) { ws in
                        workstreamRow(ws)
                    }
                }
            }

            Spacer()

            // New Workstream button
            Button {
                showNewSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                    Text("New Workstream")
                        .font(.system(size: 10))
                }
                .foregroundStyle(SenkaniTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 160)
        .background(SenkaniTheme.paneShell)
        .sheet(isPresented: $showNewSheet) {
            NewWorkstreamSheet(project: project) { name, branchOverride in
                let result = workspace.addWorkstream(name: name, branch: branchOverride, to: project)
                if case .failure(let error) = result {
                    fputs("[senkani] Failed to create workstream: \(error.localizedDescription)\n", stderr)
                }
            }
        }
        .sheet(item: $removalTarget) { ws in
            WorkstreamRemoveSheet(workstream: ws, project: project, workspace: workspace)
        }
    }

    /// Show the hover X only when more than one workstream exists and
    /// this row isn't the default — matches model invariants in
    /// `ProjectModel.removeWorkstream`.
    private func canRemove(_ ws: WorkstreamModel) -> Bool {
        !ws.isDefault && project.workstreams.count > 1
    }

    // MARK: - Workstream Row

    private func workstreamRow(_ ws: WorkstreamModel) -> some View {
        Button {
            workspace.switchWorkstream(to: ws.id)
        } label: {
            HStack(spacing: 6) {
                // Active dot
                Circle()
                    .fill(ws.isActive ? SenkaniTheme.savingsGreen : SenkaniTheme.textTertiary.opacity(0.3))
                    .frame(width: 5, height: 5)

                // Name
                VStack(alignment: .leading, spacing: 1) {
                    Text(ws.isDefault ? "default" : ws.name)
                        .font(.system(size: 10, weight: ws.isActive ? .semibold : .regular))
                        .foregroundStyle(ws.isActive ? SenkaniTheme.textPrimary : SenkaniTheme.textSecondary)
                        .lineLimit(1)

                    if let branch = ws.branch {
                        Text(branch)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.7))
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Hover-revealed remove X (suppressed for default + lone workstream).
                if hoveredWorkstreamID == ws.id && canRemove(ws) {
                    Button {
                        removalTarget = ws
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove workstream…")
                } else {
                    // Pane count
                    Text("\(ws.panes.count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                ws.isActive
                    ? SenkaniTheme.savingsGreen.opacity(0.06)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredWorkstreamID = inside ? ws.id : (hoveredWorkstreamID == ws.id ? nil : hoveredWorkstreamID)
        }
    }
}
