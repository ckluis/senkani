import SwiftUI
import Core

/// Three-column skill browser: source filter, skill list, skill detail.
struct SkillBrowserView: View {
    @State private var skills: [SkillInfo] = []
    @State private var selectedSource: String = "All"
    @State private var searchText: String = ""
    @State private var selectedSkill: SkillInfo?
    @State private var isLoading = true

    private var sources: [String] {
        var s = Set(skills.map(\.source))
        s.insert("All")
        return ["All"] + s.filter { $0 != "All" }.sorted()
    }

    private var filteredSkills: [SkillInfo] {
        skills.filter { skill in
            let matchesSource = selectedSource == "All" || skill.source == selectedSource
            let matchesSearch = searchText.isEmpty
                || skill.name.localizedCaseInsensitiveContains(searchText)
                || skill.description.localizedCaseInsensitiveContains(searchText)
            return matchesSource && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if isLoading {
                loadingView
            } else if skills.isEmpty {
                emptyView
            } else {
                HSplitView {
                    // Left: source pills + skill list
                    VStack(spacing: 0) {
                        sourcePills
                        Divider()
                        skillList
                    }
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)

                    // Right: detail — constrained to prevent overflow
                    skillDetailPane
                        .frame(minWidth: 200, maxWidth: .infinity)
                        .clipped()
                }
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .task {
            await loadSkills()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Skills")
                    .font(.system(size: 18, weight: .semibold))
                Text("\(filteredSkills.count) skill\(filteredSkills.count == 1 ? "" : "s") found")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isLoading = true
                Task { await loadSkills() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Source Pills

    private var sourcePills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sources, id: \.self) { source in
                    Button {
                        selectedSource = source
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: iconForSource(source))
                                .font(.system(size: 9))
                            Text(source.capitalized)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            selectedSource == source
                                ? Color.accentColor.opacity(0.15)
                                : Color(.controlBackgroundColor)
                        )
                        .foregroundStyle(selectedSource == source ? .primary : .secondary)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Skill List

    private var skillList: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search skills...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.controlBackgroundColor))

            Divider()

            if filteredSkills.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("No matching skills")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    if !searchText.isEmpty {
                        Text("Try a different search term")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {

            List(filteredSkills, selection: $selectedSkill) { skill in
                HStack(spacing: 8) {
                    Image(systemName: iconForType(skill.type))
                        .font(.system(size: 11))
                        .foregroundStyle(colorForSource(skill.source))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(skill.description)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Text(skill.type.rawValue)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .tag(skill)
                .contentShape(Rectangle())
            }
            .listStyle(.plain)

            } // end else (filteredSkills not empty)
        }
    }

    // MARK: - Detail Pane

    private var skillDetailPane: some View {
        Group {
            if let skill = selectedSkill {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Title area
                        HStack(spacing: 10) {
                            Image(systemName: iconForType(skill.type))
                                .font(.system(size: 20))
                                .foregroundStyle(colorForSource(skill.source))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                    .font(.system(size: 16, weight: .semibold))
                                HStack(spacing: 6) {
                                    Text(skill.source.capitalized)
                                        .font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(colorForSource(skill.source).opacity(0.12))
                                        .clipShape(Capsule())

                                    Text(skill.type.rawValue)
                                        .font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(.controlBackgroundColor))
                                        .clipShape(Capsule())
                                }
                            }
                        }

                        Divider()

                        // Description
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Description")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(skill.description)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                        }

                        // File path
                        VStack(alignment: .leading, spacing: 4) {
                            Text("File Path")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            HStack {
                                Text(skill.filePath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button {
                                    NSWorkspace.shared.selectFile(skill.filePath, inFileViewerRootedAtPath: "")
                                } label: {
                                    Label("Reveal in Finder", systemImage: "folder.badge.questionmark")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .help("Reveal in Finder")
                            }
                        }

                        // File preview
                        if let content = try? String(contentsOfFile: skill.filePath, encoding: .utf8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Contents")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                ScrollView {
                                    Text(String(content.prefix(2000)))
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                }
                                .frame(maxHeight: 400)
                                .background(Color(.textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Select a skill to view details")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Scanning for skills...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No skills found")
                .font(.system(size: 14, weight: .medium))
            Text("Skills from Claude Code, Cursor, and Continue.dev\nwill appear here when detected.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func loadSkills() async {
        let found = SkillScanner.scan()
        await MainActor.run {
            skills = found
            isLoading = false
        }
    }

    private func iconForSource(_ source: String) -> String {
        switch source.lowercased() {
        case "claude": return "sparkles"
        case "cursor": return "cursorarrow"
        case "continue": return "arrow.right.circle"
        case "all": return "square.grid.2x2"
        default: return "puzzlepiece"
        }
    }

    private func iconForType(_ type: SkillType) -> String {
        switch type {
        case .command: return "terminal"
        case .hook: return "link"
        case .rule: return "doc.text"
        case .skill: return "sparkles"
        }
    }

    private func colorForSource(_ source: String) -> Color {
        switch source.lowercased() {
        case "claude": return .orange
        case "cursor": return .blue
        case "continue": return .green
        default: return .purple
        }
    }
}

// Make SkillInfo selectable in List via Hashable
extension SkillInfo: Hashable {
    public static func == (lhs: SkillInfo, rhs: SkillInfo) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
