import SwiftUI
import Core

/// ⌘K command palette — floating search-as-you-type overlay.
/// Replaces scattered UI controls with a single unified interface.
struct CommandPaletteView: View {
    @Binding var isVisible: Bool
    let workspace: WorkspaceModel
    let onAddPane: (String) -> Void  // pane type ID string

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    private var allEntries: [CommandEntryData] {
        CommandEntryBuilder.paneEntries() + CommandEntryBuilder.actionEntries()
    }

    private var filteredEntries: [CommandEntryData] {
        CommandEntryBuilder.filter(allEntries, query: searchText)
    }

    private var groupedEntries: [(category: String, entries: [CommandEntryData])] {
        CommandEntryBuilder.grouped(filteredEntries)
    }

    private var flatFiltered: [CommandEntryData] {
        filteredEntries
    }

    var body: some View {
        ZStack {
            // Dim background — click to dismiss
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Palette card
            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)

                    TextField("Type a command...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isSearchFocused)
                        .onSubmit { executeSelected() }

                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("esc")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color(.separatorColor)))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                // Results list
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if groupedEntries.isEmpty {
                            HStack {
                                Spacer()
                                Text("No results for \"\(searchText)\"")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                    .padding(.vertical, 24)
                                Spacer()
                            }
                        }

                        ForEach(groupedEntries, id: \.category) { group in
                            // Category header
                            Text(group.category.uppercased())
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 4)

                            ForEach(group.entries) { entry in
                                let isSelected = flatFiltered.firstIndex(where: { $0.id == entry.id }) == selectedIndex
                                paletteRow(entry, isSelected: isSelected)
                                    .onTapGesture { executeEntry(entry) }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 320)

                Divider()

                // Footer hint
                HStack(spacing: 16) {
                    hintBadge("↑↓", "navigate")
                    hintBadge("↵", "select")
                    hintBadge("esc", "close")
                    Spacer()
                    Text("\(flatFiltered.count) items")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(width: 480)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .padding(.top, 80)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            searchText = ""
            selectedIndex = 0
            isSearchFocused = true
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onChange(of: searchText) { _, _ in selectedIndex = 0 }
    }

    // MARK: - Row View

    private func paletteRow(_ entry: CommandEntryData, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.icon)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                Text(entry.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }

    private func hintBadge(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color(.separatorColor)))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private func dismiss() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
            isVisible = false
        }
    }

    private func moveSelection(_ delta: Int) {
        let count = flatFiltered.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func executeSelected() {
        guard selectedIndex < flatFiltered.count else { return }
        executeEntry(flatFiltered[selectedIndex])
    }

    private func executeEntry(_ entry: CommandEntryData) {
        if entry.id.hasPrefix("pane:") {
            let typeId = String(entry.id.dropFirst(5))
            onAddPane(typeId)
        }
        // Action entries would be wired here via additional callbacks
        dismiss()
    }
}
