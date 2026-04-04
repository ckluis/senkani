import SwiftUI

/// Sidebar with pane list and add button.
struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel
    @Binding var showModels: Bool
    @Binding var showAnalytics: Bool

    var body: some View {
        List(selection: $workspace.activePaneID) {
            Section("Tools") {
                Button {
                    showModels = true
                    showAnalytics = false
                    workspace.activePaneID = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain")
                            .font(.system(size: 11))
                            .foregroundStyle(showModels ? .blue : .secondary)
                        Text("Models")
                            .font(.system(size: 12))
                            .foregroundStyle(showModels ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(showModels ? Color.accentColor.opacity(0.12) : Color.clear)

                Button {
                    showAnalytics = true
                    showModels = false
                    workspace.activePaneID = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 11))
                            .foregroundStyle(showAnalytics ? .blue : .secondary)
                        Text("Analytics")
                            .font(.system(size: 12))
                            .foregroundStyle(showAnalytics ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(showAnalytics ? Color.accentColor.opacity(0.12) : Color.clear)
            }

            Section("Panes") {
                ForEach(workspace.panes) { pane in
                    HStack {
                        Circle()
                            .fill(stateColor(pane.processState))
                            .frame(width: 6, height: 6)

                        Image(systemName: iconName(pane.paneType))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Text(pane.title)
                            .font(.system(size: 12))

                        Spacer()

                        if pane.metrics.savedBytes > 0 {
                            Text(pane.metrics.formattedSavings)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    }
                    .tag(pane.id)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        workspace.removePane(id: workspace.panes[index].id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: workspace.activePaneID) { _, newValue in
            if newValue != nil {
                showModels = false
                showAnalytics = false
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Claude Code") {
                        workspace.addPane(title: "claude", command: "claude")
                    }
                    Button("Shell") {
                        workspace.addPane(title: "shell", command: "/bin/zsh")
                    }
                    Divider()
                    Button("Markdown Preview") {
                        workspace.addPane(type: .markdownPreview, title: "Markdown")
                    }
                    Button("HTML Preview") {
                        workspace.addPane(type: .htmlPreview, title: "HTML")
                    }
                } label: {
                    Label("Add Pane", systemImage: "plus.circle")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .padding(8)

                Spacer()
            }
            .background(.ultraThinMaterial)
        }
    }

    private func iconName(_ type: PaneType) -> String {
        switch type {
        case .terminal: return "terminal"
        case .analytics: return "chart.bar"
        case .markdownPreview: return "doc.richtext"
        case .htmlPreview: return "globe"
        }
    }

    private func stateColor(_ state: ProcessState) -> Color {
        switch state {
        case .notStarted: return .gray
        case .running: return .green
        case .exited(0): return .blue
        case .exited: return .red
        }
    }
}
