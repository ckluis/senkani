import SwiftUI
import Core

/// Categorized gallery for adding new panes. Consumes `PaneGalleryBuilder`
/// from Core (testable); this view is the SwiftUI presentation layer only.
struct AddPaneSheet: View {
    let onAdd: (PaneType, String, String) -> Void  // (type, title, command)

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var hoveredEntryID: String?

    /// Map the gallery's string IDs back to the app-target PaneType enum.
    /// Mirrors the command-palette mapping in ContentView. Keep in sync
    /// when adding a new pane type.
    private let idToType: [String: PaneType] = [
        "terminal": .terminal,
        "agentTimeline": .agentTimeline,
        "skillLibrary": .skillLibrary,
        "knowledgeBase": .knowledgeBase,
        "modelManager": .modelManager,
        "sprintReview": .sprintReview,
        "dashboard": .dashboard,
        "analytics": .analytics,
        "savingsTest": .savingsTest,
        "schedules": .scheduleManager,
        "logViewer": .logViewer,
        "codeEditor": .codeEditor,
        "markdownPreview": .markdownPreview,
        "htmlPreview": .htmlPreview,
        "browser": .browser,
        "diffViewer": .diffViewer,
        "scratchpad": .scratchpad,
        "ollamaLauncher": .ollamaLauncher,
    ]

    private var filteredGroups: [(category: String, entries: [PaneGalleryEntry])] {
        let filtered = PaneGalleryBuilder.filter(PaneGalleryBuilder.allEntries(), query: searchText)
        return PaneGalleryBuilder.categorized(filtered)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            galleryScroll
        }
        .frame(width: 460, height: 560)
        .background(SenkaniTheme.paneShell)
    }

    // MARK: - Header

    private var header: some View {
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
    }

    // MARK: - Search

    private var searchField: some View {
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
    }

    // MARK: - Categorized gallery

    @ViewBuilder
    private var galleryScroll: some View {
        ScrollView {
            if filteredGroups.isEmpty {
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
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(filteredGroups, id: \.category) { group in
                        categorySection(group.category, entries: group.entries)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private func categorySection(_ category: String, entries: [PaneGalleryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(category)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(SenkaniTheme.textTertiary)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(entries) { entry in
                    paneCard(entry)
                }
            }
        }
    }

    // MARK: - Pane card

    private func paneCard(_ entry: PaneGalleryEntry) -> some View {
        let isHovered = hoveredEntryID == entry.id
        let accent = accentColor(for: entry.id)

        return Button {
            guard let type = idToType[entry.id] else {
                dismiss()
                return
            }
            onAdd(type, entry.defaultTitle, "")
            dismiss()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: entry.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(accent)

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
                        isHovered ? accent.opacity(0.6) : SenkaniTheme.inactiveBorder,
                        lineWidth: isHovered ? 1.5 : 0.5
                    )
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .shadow(
                color: isHovered ? accent.opacity(0.15) : .clear,
                radius: isHovered ? 8 : 0,
                y: isHovered ? 2 : 0
            )
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredEntryID = hovering ? entry.id : nil
        }
    }

    private func accentColor(for id: String) -> Color {
        guard let type = idToType[id] else { return SenkaniTheme.textSecondary }
        return SenkaniTheme.accentColor(for: type)
    }
}
