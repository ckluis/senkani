import SwiftUI

/// A list of available VS Code themes with live preview, grouped by dark/light.
/// Themes are loaded from the app bundle and `~/.senkani/themes/`.
struct ThemePickerView: View {
    @Environment(\.themeEngine) private var theme
    @State private var allThemes: [ThemeEngine.ThemeEntry] = []
    @State private var errorMessage: String?

    private var darkThemes: [ThemeEngine.ThemeEntry] {
        allThemes.filter { $0.type == "dark" }
    }

    private var lightThemes: [ThemeEngine.ThemeEntry] {
        allThemes.filter { $0.type == "light" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "paintpalette")
                    .font(.system(size: 14))
                    .foregroundStyle(SenkaniTheme.accentAnalytics)
                Text("Themes")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Rectangle()
                .fill(SenkaniTheme.inactiveBorder)
                .frame(height: 1)

            // Current theme indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(SenkaniTheme.accentTerminal)
                    .frame(width: 6, height: 6)
                Text("Current: \(theme.currentThemeName)")
                    .font(.system(size: 11))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(SenkaniTheme.accentTerminal.opacity(0.06))

            // Error message
            if let error = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                    Text(error)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            // Theme list
            ScrollView {
                VStack(spacing: 0) {
                    // Default Dark fallback
                    themeRow(
                        name: "Default Dark",
                        isSelected: theme.currentThemeURL == nil,
                        isBundled: true,
                        previewColors: ["#0E0E0E", "#1A1A1A", "#E0E0E0", "#3FB068", "#4A9EE0"]
                    ) {
                        theme.loadDefaultDark()
                        errorMessage = nil
                    }

                    // Dark Themes section
                    if !darkThemes.isEmpty {
                        sectionHeader("Dark Themes")

                        ForEach(darkThemes) { entry in
                            themeRow(
                                name: entry.name,
                                isSelected: theme.currentThemeURL == entry.url,
                                isBundled: entry.isBundled,
                                previewColors: previewColors(for: entry.url)
                            ) {
                                loadThemeEntry(entry)
                            }
                        }
                    }

                    // Light Themes section
                    if !lightThemes.isEmpty {
                        sectionHeader("Light Themes")

                        ForEach(lightThemes) { entry in
                            themeRow(
                                name: entry.name,
                                isSelected: theme.currentThemeURL == entry.url,
                                isBundled: entry.isBundled,
                                previewColors: previewColors(for: entry.url)
                            ) {
                                loadThemeEntry(entry)
                            }
                        }
                    }

                    if allThemes.isEmpty {
                        VStack(spacing: 8) {
                            Text("No themes found")
                                .font(.system(size: 11))
                                .foregroundStyle(SenkaniTheme.textTertiary)
                        }
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            Spacer(minLength: 0)

            // Open themes folder button
            Rectangle()
                .fill(SenkaniTheme.inactiveBorder)
                .frame(height: 1)

            Button {
                openThemesFolder()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text("Open Themes Folder")
                        .font(.system(size: 10))
                }
                .foregroundStyle(SenkaniTheme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            Button {
                refreshThemes()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text("Refresh")
                        .font(.system(size: 10))
                }
                .foregroundStyle(SenkaniTheme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .background(SenkaniTheme.paneBody)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refreshThemes()
        }
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(SenkaniTheme.inactiveBorder.opacity(0.5))
                .frame(height: 1)
                .padding(.horizontal, 12)

            HStack {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .tracking(0.8)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Theme row

    private func themeRow(
        name: String,
        isSelected: Bool,
        isBundled: Bool,
        previewColors: [String],
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? SenkaniTheme.accentAnalytics : SenkaniTheme.textTertiary.opacity(0.3))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(name)
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? SenkaniTheme.textPrimary : SenkaniTheme.textSecondary)

                        if isBundled {
                            Text("Built-in")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(SenkaniTheme.textTertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(SenkaniTheme.textTertiary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                    }

                    // Color preview swatches
                    HStack(spacing: 3) {
                        ForEach(previewColors.prefix(5), id: \.self) { hex in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: hex))
                                .frame(width: 12, height: 8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .strokeBorder(SenkaniTheme.textTertiary.opacity(0.2), lineWidth: 0.5)
                                )
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(SenkaniTheme.accentAnalytics)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(isSelected ? SenkaniTheme.accentAnalytics.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    /// Extract 5 representative colors from a theme file for the swatch preview.
    private func previewColors(for url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(VSCodeThemeJSON.self, from: data),
              let colors = raw.colors else {
            return ["#1A1A1A", "#282828", "#E0E0E0", "#4A9EE0", "#98C379"]
        }

        return [
            colors["editor.background"] ?? "#1A1A1A",
            colors["sideBar.background"] ?? "#282828",
            colors["foreground"] ?? "#E0E0E0",
            colors["terminal.ansiGreen"] ?? "#98C379",
            colors["terminal.ansiBlue"] ?? "#4A9EE0"
        ]
    }

    private func loadThemeEntry(_ entry: ThemeEngine.ThemeEntry) {
        do {
            if entry.isBundled {
                try theme.loadBundledTheme(from: entry.url)
            } else {
                try theme.loadTheme(from: entry.url)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Actions

    private func refreshThemes() {
        allThemes = theme.availableThemes()
    }

    private func openThemesFolder() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".senkani/themes")
        // Ensure directory exists before opening
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(path)
    }
}
