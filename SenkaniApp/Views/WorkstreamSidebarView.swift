import SwiftUI

/// Conditional second sidebar showing workstreams for the active project.
/// Only visible when the project has 2+ workstreams.
/// Progressive disclosure: invisible for single-workstream projects.
struct WorkstreamSidebarView: View {
    let project: ProjectModel
    let workspace: WorkspaceModel
    @State private var showNewSheet = false

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
            NewWorkstreamSheet { name in
                let result = workspace.addWorkstream(name: name, to: project)
                if case .failure(let error) = result {
                    fputs("[senkani] Failed to create workstream: \(error.localizedDescription)\n", stderr)
                }
            }
        }
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

                // Pane count
                Text("\(ws.panes.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
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
    }
}
