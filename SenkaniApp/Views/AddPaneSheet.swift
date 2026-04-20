import SwiftUI

/// Beautiful sheet for adding new panes. Grid of type cards with search filter,
/// accent colors, and hover effects. Opened via Cmd+N or "+" toolbar button.
struct AddPaneSheet: View {
    let onAdd: (PaneType, String, String) -> Void  // (type, title, command)

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var hoveredType: PaneType?

    /// All available pane type entries with their metadata.
    private struct PaneEntry: Identifiable {
        let id: PaneType
        let type: PaneType
        let name: String
        let description: String
        let icon: String
        let accent: Color
        let defaultTitle: String
        let defaultCommand: String
    }

    private var entries: [PaneEntry] {
        let all: [PaneEntry] = [
            PaneEntry(
                id: .terminal, type: .terminal,
                name: "Terminal",
                description: "Run commands and AI agents",
                icon: SenkaniTheme.iconName(for: .terminal),
                accent: SenkaniTheme.accentColor(for: .terminal),
                defaultTitle: "Terminal",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .markdownPreview, type: .markdownPreview,
                name: "Markdown Preview",
                description: "Live preview .md files",
                icon: SenkaniTheme.iconName(for: .markdownPreview),
                accent: SenkaniTheme.accentColor(for: .markdownPreview),
                defaultTitle: "Markdown",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .htmlPreview, type: .htmlPreview,
                name: "HTML Preview",
                description: "Preview web pages",
                icon: SenkaniTheme.iconName(for: .htmlPreview),
                accent: SenkaniTheme.accentColor(for: .htmlPreview),
                defaultTitle: "HTML",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .skillLibrary, type: .skillLibrary,
                name: "Skill Library",
                description: "Browse your AI skills",
                icon: SenkaniTheme.iconName(for: .skillLibrary),
                accent: SenkaniTheme.accentColor(for: .skillLibrary),
                defaultTitle: "Skills",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .knowledgeBase, type: .knowledgeBase,
                name: "Knowledge Base",
                description: "Search your AI history",
                icon: SenkaniTheme.iconName(for: .knowledgeBase),
                accent: SenkaniTheme.accentColor(for: .knowledgeBase),
                defaultTitle: "Knowledge",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .analytics, type: .analytics,
                name: "Analytics",
                description: "Charts and cost tracking",
                icon: SenkaniTheme.iconName(for: .analytics),
                accent: SenkaniTheme.accentColor(for: .analytics),
                defaultTitle: "Analytics",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .modelManager, type: .modelManager,
                name: "Model Manager",
                description: "Download and manage ML models",
                icon: SenkaniTheme.iconName(for: .modelManager),
                accent: SenkaniTheme.accentColor(for: .modelManager),
                defaultTitle: "Models",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .scheduleManager, type: .scheduleManager,
                name: "Schedules",
                description: "View scheduled tasks",
                icon: SenkaniTheme.iconName(for: .scheduleManager),
                accent: SenkaniTheme.accentColor(for: .scheduleManager),
                defaultTitle: "Schedules",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .browser, type: .browser,
                name: "Browser",
                description: "Browse URLs and localhost",
                icon: SenkaniTheme.iconName(for: .browser),
                accent: SenkaniTheme.accentColor(for: .browser),
                defaultTitle: "Browser",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .diffViewer, type: .diffViewer,
                name: "Diff Viewer",
                description: "Compare files side by side",
                icon: SenkaniTheme.iconName(for: .diffViewer),
                accent: SenkaniTheme.accentColor(for: .diffViewer),
                defaultTitle: "Diff",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .logViewer, type: .logViewer,
                name: "Log Viewer",
                description: "Tail and filter log files",
                icon: SenkaniTheme.iconName(for: .logViewer),
                accent: SenkaniTheme.accentColor(for: .logViewer),
                defaultTitle: "Log",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .scratchpad, type: .scratchpad,
                name: "Scratchpad",
                description: "Quick notes and scratch space",
                icon: SenkaniTheme.iconName(for: .scratchpad),
                accent: SenkaniTheme.accentColor(for: .scratchpad),
                defaultTitle: "Notes",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .savingsTest, type: .savingsTest,
                name: "Savings Test",
                description: "Benchmark optimization savings",
                icon: SenkaniTheme.iconName(for: .savingsTest),
                accent: SenkaniTheme.accentColor(for: .savingsTest),
                defaultTitle: "Savings Test",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .codeEditor, type: .codeEditor,
                name: "Code Editor",
                description: "View code with syntax highlighting",
                icon: SenkaniTheme.iconName(for: .codeEditor),
                accent: SenkaniTheme.accentColor(for: .codeEditor),
                defaultTitle: "Code",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .agentTimeline, type: .agentTimeline,
                name: "Agent Timeline",
                description: "Live feed of optimization events",
                icon: SenkaniTheme.iconName(for: .agentTimeline),
                accent: SenkaniTheme.accentColor(for: .agentTimeline),
                defaultTitle: "Timeline",
                defaultCommand: ""
            ),
            PaneEntry(
                id: .sprintReview, type: .sprintReview,
                name: SenkaniTheme.displayName(for: .sprintReview),
                description: SenkaniTheme.description(for: .sprintReview),
                icon: SenkaniTheme.iconName(for: .sprintReview),
                accent: SenkaniTheme.accentColor(for: .sprintReview),
                defaultTitle: "Sprint Review",
                defaultCommand: ""
            ),
        ]

        if searchText.isEmpty { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Pane")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textPrimary)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(SenkaniTheme.textTertiary)

                TextField("Filter pane types...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(SenkaniTheme.textPrimary)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SenkaniTheme.paneBody)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            // Grid of pane type cards
            ScrollView {
                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                        Text("No matching pane types")
                            .font(.system(size: 12))
                            .foregroundStyle(SenkaniTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(entries) { entry in
                            paneCard(entry)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(width: 420, height: 480)
        .background(SenkaniTheme.paneShell)
    }

    // MARK: - Pane card

    private func paneCard(_ entry: PaneEntry) -> some View {
        let isHovered = hoveredType == entry.type

        return Button {
            onAdd(entry.type, entry.defaultTitle, entry.defaultCommand)
            dismiss()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: entry.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(entry.accent)

                VStack(spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SenkaniTheme.textPrimary)

                    Text(entry.description)
                        .font(.system(size: 10))
                        .foregroundStyle(SenkaniTheme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(SenkaniTheme.paneBody)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isHovered ? entry.accent.opacity(0.6) : SenkaniTheme.inactiveBorder,
                        lineWidth: isHovered ? 1.5 : 0.5
                    )
            )
            // Lift effect on hover
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .shadow(
                color: isHovered ? entry.accent.opacity(0.15) : .clear,
                radius: isHovered ? 8 : 0,
                y: isHovered ? 2 : 0
            )
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredType = hovering ? entry.type : nil
        }
    }
}
