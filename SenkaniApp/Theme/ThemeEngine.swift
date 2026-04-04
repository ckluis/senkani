import SwiftUI
import Foundation
import Core

// MARK: - VS Code Theme JSON Types

/// Raw VS Code theme JSON structure.
struct VSCodeThemeJSON: Codable {
    let name: String?
    let type: String?
    let colors: [String: String]?
    let tokenColors: [VSCodeTokenColor]?
}

struct VSCodeTokenColor: Codable {
    let name: String?
    let scope: VSCodeTokenScope?
    let settings: VSCodeTokenSettings?
}

/// Token scope can be a single string or an array of strings.
enum VSCodeTokenScope: Codable {
    case single(String)
    case multiple([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .single(str)
        } else if let arr = try? container.decode([String].self) {
            self = .multiple(arr)
        } else {
            self = .single("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let s): try container.encode(s)
        case .multiple(let a): try container.encode(a)
        }
    }

    var scopes: [String] {
        switch self {
        case .single(let s): return [s]
        case .multiple(let a): return a
        }
    }
}

struct VSCodeTokenSettings: Codable {
    let foreground: String?
    let background: String?
    let fontStyle: String?
}

// MARK: - ThemeEngine

/// Live theme engine that loads VS Code `.json` theme files and provides
/// resolved colors for all Senkani surfaces. Singleton accessed via
/// `ThemeEngine.shared` or injected into the SwiftUI environment.
@MainActor @Observable
final class ThemeEngine {
    static let shared = ThemeEngine()

    // MARK: - Resolved colors (every view reads these)

    /// App-level background behind everything.
    var appBackground: Color
    /// Pane shell / card background.
    var paneShell: Color
    /// Inset body inside a pane (darker than shell).
    var paneBody: Color
    /// Sidebar background.
    var sidebarBackground: Color
    /// Status bar background.
    var statusBarBackground: Color
    /// Primary text.
    var textPrimary: Color
    /// Secondary / muted text.
    var textSecondary: Color
    /// Tertiary / very muted text.
    var textTertiary: Color
    /// Focused pane border color.
    var focusBorder: Color
    /// Unfocused pane border.
    var inactiveBorder: Color

    // MARK: - Terminal ANSI palette

    var ansiBlack: Color
    var ansiRed: Color
    var ansiGreen: Color
    var ansiYellow: Color
    var ansiBlue: Color
    var ansiMagenta: Color
    var ansiCyan: Color
    var ansiWhite: Color
    var ansiBrightBlack: Color
    var ansiBrightRed: Color
    var ansiBrightGreen: Color
    var ansiBrightYellow: Color
    var ansiBrightBlue: Color
    var ansiBrightMagenta: Color
    var ansiBrightCyan: Color
    var ansiBrightWhite: Color

    // MARK: - Accent colors derived from ANSI (pane type accents)

    var accentTerminal: Color { ansiGreen }
    var accentAnalytics: Color { ansiBlue }
    var accentPreview: Color { ansiYellow }

    // MARK: - Savings color

    var savingsGreen: Color { ansiGreen }

    // MARK: - Overlay

    var dimOverlay: Color { Color.black.opacity(0.42) }

    // MARK: - Feature toggle colors (semantic, not theme-derived)

    let toggleFilter = Color.blue
    let toggleCache = Color.green
    let toggleSecrets = Color.orange
    let toggleIndexer = Color.purple
    /// Warm amber/gold for terse mode toggle.
    let toggleTerse = Color(red: 0.85, green: 0.65, blue: 0.13)

    // MARK: - Theme metadata

    var currentThemeName: String = "Default Dark"

    /// URL of the currently loaded theme file (nil for embedded default).
    var currentThemeURL: URL?

    // MARK: - Init

    init() {
        // Initialize with default dark values (same as the original hardcoded SenkaniTheme)
        appBackground = Color(red: 0.055, green: 0.055, blue: 0.055)
        paneShell = Color(red: 0.102, green: 0.102, blue: 0.102)
        paneBody = Color(red: 0.075, green: 0.075, blue: 0.075)
        sidebarBackground = Color(red: 0.067, green: 0.067, blue: 0.067)
        statusBarBackground = Color(red: 0.047, green: 0.047, blue: 0.047)
        textPrimary = Color(red: 0.878, green: 0.878, blue: 0.878)
        textSecondary = Color(red: 0.502, green: 0.502, blue: 0.502)
        textTertiary = Color(red: 0.314, green: 0.314, blue: 0.314)
        focusBorder = Color(red: 0.4, green: 0.5, blue: 0.7)
        inactiveBorder = Color(red: 0.165, green: 0.165, blue: 0.165)

        // ANSI defaults
        ansiBlack = Color(hex: "#1A1A1A")
        ansiRed = Color(hex: "#E05A4A")
        ansiGreen = Color(hex: "#3FB068")
        ansiYellow = Color(hex: "#D4A017")
        ansiBlue = Color(hex: "#4A9EE0")
        ansiMagenta = Color(hex: "#C678DD")
        ansiCyan = Color(hex: "#56B6C2")
        ansiWhite = Color(hex: "#E2E2E2")
        ansiBrightBlack = Color(hex: "#444444")
        ansiBrightRed = Color(hex: "#FF6B6B")
        ansiBrightGreen = Color(hex: "#5CDB95")
        ansiBrightYellow = Color(hex: "#FFCA3A")
        ansiBrightBlue = Color(hex: "#74B9FF")
        ansiBrightMagenta = Color(hex: "#E056FD")
        ansiBrightCyan = Color(hex: "#81ECEC")
        ansiBrightWhite = Color(hex: "#FFFFFF")
    }

    // MARK: - Load Theme

    /// Load a VS Code theme from a JSON file URL.
    ///
    /// SECURITY: Validates the theme file through ThemeValidator before loading.
    /// This checks file size, JSON structure, color format, and rejects
    /// embedded scripts/URLs/format strings.
    func loadTheme(from url: URL) throws {
        // Security gate: validate before parsing
        _ = try ThemeValidator.validate(at: url)

        let data = try Data(contentsOf: url)
        let raw = try JSONDecoder().decode(VSCodeThemeJSON.self, from: data)
        applyVSCodeTheme(raw)
        currentThemeURL = url
        currentThemeName = raw.name ?? url.deletingPathExtension().lastPathComponent

        // Persist selection
        UserDefaults.standard.set(url.path, forKey: "senkani.selectedThemePath")
    }

    /// Reset to the embedded default dark theme.
    func loadDefaultDark() {
        let engine = ThemeEngine()  // fresh instance with defaults
        appBackground = engine.appBackground
        paneShell = engine.paneShell
        paneBody = engine.paneBody
        sidebarBackground = engine.sidebarBackground
        statusBarBackground = engine.statusBarBackground
        textPrimary = engine.textPrimary
        textSecondary = engine.textSecondary
        textTertiary = engine.textTertiary
        focusBorder = engine.focusBorder
        inactiveBorder = engine.inactiveBorder
        ansiBlack = engine.ansiBlack
        ansiRed = engine.ansiRed
        ansiGreen = engine.ansiGreen
        ansiYellow = engine.ansiYellow
        ansiBlue = engine.ansiBlue
        ansiMagenta = engine.ansiMagenta
        ansiCyan = engine.ansiCyan
        ansiWhite = engine.ansiWhite
        ansiBrightBlack = engine.ansiBrightBlack
        ansiBrightRed = engine.ansiBrightRed
        ansiBrightGreen = engine.ansiBrightGreen
        ansiBrightYellow = engine.ansiBrightYellow
        ansiBrightBlue = engine.ansiBrightBlue
        ansiBrightMagenta = engine.ansiBrightMagenta
        ansiBrightCyan = engine.ansiBrightCyan
        ansiBrightWhite = engine.ansiBrightWhite
        currentThemeName = "Default Dark"
        currentThemeURL = nil

        UserDefaults.standard.removeObject(forKey: "senkani.selectedThemePath")
    }

    /// Restore the user's last selected theme (call on app launch).
    ///
    /// If no theme was previously selected, defaults to "One Dark Pro" from bundled themes.
    ///
    /// SECURITY: The persisted path is re-validated before loading.
    /// loadTheme() runs ThemeValidator, so even a tampered UserDefaults
    /// path cannot load a malicious file.
    func restoreLastTheme() {
        let savedPath = UserDefaults.standard.string(forKey: "senkani.selectedThemePath")

        // Handle bundled theme references (stored as "bundled:filename.json")
        if let saved = savedPath, saved.hasPrefix("bundled:") {
            let filename = String(saved.dropFirst("bundled:".count))
            if let bundlePath = Bundle.module.resourcePath {
                let bundleURL = URL(fileURLWithPath: bundlePath)
                    .appendingPathComponent("Themes")
                    .appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: bundleURL.path) {
                    try? loadBundledTheme(from: bundleURL)
                    return
                }
            }
        }

        // Handle user theme paths
        if let path = savedPath, !path.hasPrefix("bundled:") {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return }

            // Resolve symlinks to prevent escape from themes directory
            let resolved = url.resolvingSymlinksInPath()
            let themesDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".senkani/themes").resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(themesDir.path + "/") else {
                // Theme file is not in the expected directory — refuse to load
                UserDefaults.standard.removeObject(forKey: "senkani.selectedThemePath")
                return
            }

            try? loadTheme(from: resolved)
            return
        }

        // No saved theme — default to One Dark Pro if available in bundle
        if savedPath == nil {
            if let bundlePath = Bundle.module.resourcePath {
                let oneDarkURL = URL(fileURLWithPath: bundlePath)
                    .appendingPathComponent("Themes")
                    .appendingPathComponent("one-dark-pro.json")
                if FileManager.default.fileExists(atPath: oneDarkURL.path) {
                    try? loadBundledTheme(from: oneDarkURL)
                    return
                }
            }
        }
    }

    // MARK: - Available Themes

    /// Metadata for a theme entry in the picker.
    struct ThemeEntry: Identifiable {
        let id: String  // unique key (filename or "default-dark")
        let name: String
        let url: URL
        let isBundled: Bool
        let type: String  // "dark" or "light"
    }

    /// Returns bundled theme URLs from the app bundle's `Themes/` resource directory.
    func bundledThemes() -> [ThemeEntry] {
        guard let bundlePath = Bundle.module.resourcePath else { return [] }
        let themesDir = URL(fileURLWithPath: bundlePath).appendingPathComponent("Themes")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: themesDir,
            includingPropertiesForKeys: [.nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let raw = try? JSONDecoder().decode(VSCodeThemeJSON.self, from: data) else {
                    return nil
                }
                let displayName = raw.name ?? url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                    .localizedCapitalized
                return ThemeEntry(
                    id: "bundled:\(url.lastPathComponent)",
                    name: displayName,
                    url: url,
                    isBundled: true,
                    type: raw.type ?? "dark"
                )
            }
    }

    /// Scans `~/.senkani/themes/` for user-installed `.json` theme files.
    func userThemes() -> [ThemeEntry] {
        let themesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".senkani/themes")

        // Ensure the directory exists
        try? FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: themesDir,
            includingPropertiesForKeys: [.nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let resolvedThemesDir = themesDir.resolvingSymlinksInPath()

        return contents
            .filter { $0.pathExtension.lowercased() == "json" }
            // SECURITY: Resolve symlinks and reject any that escape the themes directory
            .filter { url in
                let resolved = url.resolvingSymlinksInPath()
                return resolved.path.hasPrefix(resolvedThemesDir.path + "/")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let raw = try? JSONDecoder().decode(VSCodeThemeJSON.self, from: data) else {
                    return nil
                }
                let displayName = raw.name ?? url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                    .localizedCapitalized
                return ThemeEntry(
                    id: "user:\(url.lastPathComponent)",
                    name: displayName,
                    url: url,
                    isBundled: false,
                    type: raw.type ?? "dark"
                )
            }
    }

    /// Returns all available themes: bundled first, then user-installed.
    func availableThemes() -> [ThemeEntry] {
        return bundledThemes() + userThemes()
    }

    /// Load a bundled theme by name (skips ThemeValidator file-path security checks
    /// since bundled resources are trusted and not in ~/.senkani/themes/).
    func loadBundledTheme(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let raw = try JSONDecoder().decode(VSCodeThemeJSON.self, from: data)
        applyVSCodeTheme(raw)
        currentThemeURL = url
        currentThemeName = raw.name ?? url.deletingPathExtension().lastPathComponent

        // Persist selection with a bundled: prefix so restoreLastTheme knows
        UserDefaults.standard.set("bundled:\(url.lastPathComponent)", forKey: "senkani.selectedThemePath")
    }

    // MARK: - VS Code Mapping

    /// Apply a parsed VS Code theme JSON to all resolved colors.
    private func applyVSCodeTheme(_ raw: VSCodeThemeJSON) {
        let c = raw.colors ?? [:]

        func pick(_ keys: String..., fallback: String) -> Color {
            for key in keys {
                if let hex = c[key] {
                    return Color(hex: hex)
                }
            }
            return Color(hex: fallback)
        }

        // Workbench chrome (follows design.md canonical mapping)
        appBackground = pick("editor.background", fallback: "#0E0E0E")
        paneShell = pick("sideBar.background", "tab.inactiveBackground", fallback: "#1A1A1A")
        paneBody = pick("editor.background", fallback: "#131313")
        sidebarBackground = pick("sideBar.background", fallback: "#1A1A1A")
        statusBarBackground = pick("statusBar.background", "titleBar.activeBackground", fallback: "#1A1A1A")
        textPrimary = pick("sideBar.foreground", "foreground", fallback: "#E0E0E0")
        textSecondary = pick("descriptionForeground", fallback: "#808080")
        textTertiary = pick("descriptionForeground", fallback: "#505050")
        focusBorder = pick("focusBorder", fallback: "#66809B")
        inactiveBorder = pick("panel.border", "contrastBorder", fallback: "#2A2A2A")

        // ANSI palette
        ansiBlack = pick("terminal.ansiBlack", fallback: "#1A1A1A")
        ansiRed = pick("terminal.ansiRed", fallback: "#E05A4A")
        ansiGreen = pick("terminal.ansiGreen", fallback: "#3FB068")
        ansiYellow = pick("terminal.ansiYellow", fallback: "#D4A017")
        ansiBlue = pick("terminal.ansiBlue", fallback: "#4A9EE0")
        ansiMagenta = pick("terminal.ansiMagenta", fallback: "#C678DD")
        ansiCyan = pick("terminal.ansiCyan", fallback: "#56B6C2")
        ansiWhite = pick("terminal.ansiWhite", fallback: "#E2E2E2")
        ansiBrightBlack = pick("terminal.ansiBrightBlack", fallback: "#444444")
        ansiBrightRed = pick("terminal.ansiBrightRed", fallback: "#FF6B6B")
        ansiBrightGreen = pick("terminal.ansiBrightGreen", fallback: "#5CDB95")
        ansiBrightYellow = pick("terminal.ansiBrightYellow", fallback: "#FFCA3A")
        ansiBrightBlue = pick("terminal.ansiBrightBlue", fallback: "#74B9FF")
        ansiBrightMagenta = pick("terminal.ansiBrightMagenta", fallback: "#E056FD")
        ansiBrightCyan = pick("terminal.ansiBrightCyan", fallback: "#81ECEC")
        ansiBrightWhite = pick("terminal.ansiBrightWhite", fallback: "#FFFFFF")
    }
}

// MARK: - Hex Color Extension

extension Color {
    /// Create a Color from a hex string (supports #RGB, #RRGGBB, #RRGGBBAA).
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b, a: Double
        switch hex.count {
        case 3: // RGB
            r = Double((int >> 8) & 0xF) / 15.0
            g = Double((int >> 4) & 0xF) / 15.0
            b = Double(int & 0xF) / 15.0
            a = 1.0
        case 6: // RRGGBB
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
            a = 1.0
        case 8: // RRGGBBAA
            r = Double((int >> 24) & 0xFF) / 255.0
            g = Double((int >> 16) & 0xFF) / 255.0
            b = Double((int >> 8) & 0xFF) / 255.0
            a = Double(int & 0xFF) / 255.0
        default:
            r = 0; g = 0; b = 0; a = 1.0
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Environment Key

private struct ThemeEngineKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: ThemeEngine = ThemeEngine.shared
}

extension EnvironmentValues {
    var themeEngine: ThemeEngine {
        get { self[ThemeEngineKey.self] }
        set { self[ThemeEngineKey.self] = newValue }
    }
}
