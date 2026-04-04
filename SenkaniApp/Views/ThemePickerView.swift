import SwiftUI

/// A list of available VS Code themes with live preview.
/// Themes are loaded from `~/.senkani/themes/` as `.json` files.
struct ThemePickerView: View {
    @Environment(\.themeEngine) private var theme
    @State private var themes: [(name: String, url: URL)] = []
    @State private var errorMessage: String?

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
                    // Default dark theme
                    themeRow(
                        name: "Default Dark",
                        isSelected: theme.currentThemeURL == nil
                    ) {
                        theme.loadDefaultDark()
                        errorMessage = nil
                    }

                    Rectangle()
                        .fill(SenkaniTheme.inactiveBorder.opacity(0.5))
                        .frame(height: 1)
                        .padding(.horizontal, 12)

                    // User themes from ~/.senkani/themes/
                    if themes.isEmpty {
                        VStack(spacing: 8) {
                            Text("No custom themes found")
                                .font(.system(size: 11))
                                .foregroundStyle(SenkaniTheme.textTertiary)
                            Text("Drop VS Code .json theme files into:")
                                .font(.system(size: 10))
                                .foregroundStyle(SenkaniTheme.textTertiary)
                            Text("~/.senkani/themes/")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(SenkaniTheme.textSecondary)
                        }
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(Array(themes.enumerated()), id: \.offset) { _, themeEntry in
                            themeRow(
                                name: themeEntry.name,
                                isSelected: theme.currentThemeURL == themeEntry.url
                            ) {
                                do {
                                    try theme.loadTheme(from: themeEntry.url)
                                    errorMessage = nil
                                } catch {
                                    errorMessage = "Failed: \(error.localizedDescription)"
                                }
                            }
                        }
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

    // MARK: - Theme row

    private func themeRow(name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? SenkaniTheme.accentAnalytics : SenkaniTheme.textTertiary.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? SenkaniTheme.textPrimary : SenkaniTheme.textSecondary)

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

    // MARK: - Actions

    private func refreshThemes() {
        themes = theme.availableThemes()
    }

    private func openThemesFolder() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".senkani/themes")
        // Ensure directory exists before opening
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(path)
    }
}
