import SwiftUI

/// Centralized color palette for Senkani's dark, dense, tool-native UI.
/// Inspired by Flock's design system. All colors are hardcoded dark theme
/// defaults; eventually this could load VS Code theme JSON.
enum SenkaniTheme {
    // MARK: - Backgrounds (darkest to lightest)

    /// App-level background behind everything. #0E0E0E
    static let appBackground = Color(red: 0.055, green: 0.055, blue: 0.055)

    /// Pane shell / card background. #1A1A1A
    static let paneShell = Color(red: 0.102, green: 0.102, blue: 0.102)

    /// Inset body inside a pane (darker than shell). #131313
    static let paneBody = Color(red: 0.075, green: 0.075, blue: 0.075)

    /// Sidebar background. #111111
    static let sidebarBackground = Color(red: 0.067, green: 0.067, blue: 0.067)

    /// Status bar background. #0C0C0C
    static let statusBarBackground = Color(red: 0.047, green: 0.047, blue: 0.047)

    // MARK: - Text

    /// Primary text. #E0E0E0
    static let textPrimary = Color(red: 0.878, green: 0.878, blue: 0.878)

    /// Secondary / muted text. #808080
    static let textSecondary = Color(red: 0.502, green: 0.502, blue: 0.502)

    /// Tertiary / very muted text. #505050
    static let textTertiary = Color(red: 0.314, green: 0.314, blue: 0.314)

    // MARK: - Pane type accent colors

    /// Terminal accent. #3FB068
    static let accentTerminal = Color(red: 0.247, green: 0.690, blue: 0.408)

    /// Analytics accent. #4A9EE0
    static let accentAnalytics = Color(red: 0.290, green: 0.620, blue: 0.878)

    /// Preview accent (markdown, HTML). #D4A017
    static let accentPreview = Color(red: 0.831, green: 0.627, blue: 0.090)

    // MARK: - Focus / dim

    /// Overlay applied to unfocused panes: black at 42% opacity (58% of content visible).
    static let dimOverlay = Color.black.opacity(0.42)

    /// Focused pane border color.
    static let focusBorder = Color(red: 0.4, green: 0.5, blue: 0.7)

    /// Unfocused pane border. #2A2A2A
    static let inactiveBorder = Color(red: 0.165, green: 0.165, blue: 0.165)

    // MARK: - Feature toggle colors

    static let toggleFilter = Color.blue
    static let toggleCache = Color.green
    static let toggleSecrets = Color.orange
    static let toggleIndexer = Color.purple

    // MARK: - Savings

    static let savingsGreen = Color(red: 0.247, green: 0.690, blue: 0.408)

    // MARK: - Layout constants

    /// Default pane column width in the horizontal canvas.
    static let defaultColumnWidth: CGFloat = 360

    /// Minimum pane column width.
    static let minColumnWidth: CGFloat = 280

    /// Maximum pane column width.
    static let maxColumnWidth: CGFloat = 500

    /// Gap between pane columns.
    static let columnSpacing: CGFloat = 8

    /// Pane header height.
    static let headerHeight: CGFloat = 32

    /// Accent line thickness at top of pane.
    static let accentLineHeight: CGFloat = 1.5

    /// Status bar height.
    static let statusBarHeight: CGFloat = 25

    /// Sidebar width.
    static let sidebarWidth: CGFloat = 180

    /// Corner radius for pane shells.
    static let paneCornerRadius: CGFloat = 6

    // MARK: - Animation

    /// Standard dim/undim transition.
    static let focusAnimation: Animation = .easeInOut(duration: 0.15)

    // MARK: - Helpers

    /// Returns the accent color for a given pane type.
    static func accentColor(for type: PaneType) -> Color {
        switch type {
        case .terminal: return accentTerminal
        case .analytics: return accentAnalytics
        case .markdownPreview, .htmlPreview: return accentPreview
        }
    }

    /// Returns the SF Symbol name for a given pane type.
    static func iconName(for type: PaneType) -> String {
        switch type {
        case .terminal: return "terminal"
        case .analytics: return "chart.bar"
        case .markdownPreview: return "doc.richtext"
        case .htmlPreview: return "globe"
        }
    }
}
