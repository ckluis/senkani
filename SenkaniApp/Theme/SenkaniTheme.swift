import SwiftUI

/// Centralized color palette for Senkani's dark, dense, tool-native UI.
/// All color properties now delegate to `ThemeEngine.shared` so they
/// respond to live theme changes while keeping the familiar static API.
/// Layout constants, animations, and helpers remain unchanged.
@MainActor
enum SenkaniTheme {
    // MARK: - Backgrounds (darkest to lightest)

    /// App-level background behind everything.
    static var appBackground: Color { ThemeEngine.shared.appBackground }

    /// Pane shell / card background.
    static var paneShell: Color { ThemeEngine.shared.paneShell }

    /// Inset body inside a pane (darker than shell).
    static var paneBody: Color { ThemeEngine.shared.paneBody }

    /// Sidebar background.
    static var sidebarBackground: Color { ThemeEngine.shared.sidebarBackground }

    /// Status bar background.
    static var statusBarBackground: Color { ThemeEngine.shared.statusBarBackground }

    // MARK: - Text

    /// Primary text.
    static var textPrimary: Color { ThemeEngine.shared.textPrimary }

    /// Secondary / muted text.
    static var textSecondary: Color { ThemeEngine.shared.textSecondary }

    /// Tertiary / very muted text.
    static var textTertiary: Color { ThemeEngine.shared.textTertiary }

    // MARK: - Pane type accent colors

    /// Terminal accent (theme ANSI green).
    static var accentTerminal: Color { ThemeEngine.shared.accentTerminal }

    /// Analytics accent (theme ANSI blue).
    static var accentAnalytics: Color { ThemeEngine.shared.accentAnalytics }

    /// Preview accent (theme ANSI yellow).
    static var accentPreview: Color { ThemeEngine.shared.accentPreview }

    /// Skill Library accent (theme ANSI magenta).
    static var accentSkillLibrary: Color { ThemeEngine.shared.ansiMagenta }

    /// Knowledge Base accent (theme ANSI cyan).
    static var accentKnowledgeBase: Color { ThemeEngine.shared.ansiCyan }

    /// Model Manager accent (theme ANSI blue).
    static var accentModelManager: Color { ThemeEngine.shared.ansiBlue }

    /// Schedule Manager accent (theme ANSI blue).
    static var accentScheduleManager: Color { ThemeEngine.shared.ansiBlue }

    // MARK: - Focus / dim

    /// Overlay applied to unfocused panes: black at 42% opacity (58% of content visible).
    static var dimOverlay: Color { ThemeEngine.shared.dimOverlay }

    /// Focused pane border color.
    static var focusBorder: Color { ThemeEngine.shared.focusBorder }

    /// Unfocused pane border.
    static var inactiveBorder: Color { ThemeEngine.shared.inactiveBorder }

    // MARK: - Feature toggle colors

    static var toggleFilter: Color { ThemeEngine.shared.toggleFilter }
    static var toggleCache: Color { ThemeEngine.shared.toggleCache }
    static var toggleSecrets: Color { ThemeEngine.shared.toggleSecrets }
    static var toggleIndexer: Color { ThemeEngine.shared.toggleIndexer }

    // MARK: - Savings

    static var savingsGreen: Color { ThemeEngine.shared.savingsGreen }

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

    /// Pane entrance spring animation.
    static let paneEntranceAnimation: Animation = .spring(response: 0.4, dampingFraction: 0.8)

    /// Pane exit animation.
    static let paneExitAnimation: Animation = .easeOut(duration: 0.2)

    /// Scale for focused panes.
    static let focusedScale: CGFloat = 1.0

    /// Scale for unfocused panes (barely perceptible depth).
    static let unfocusedScale: CGFloat = 0.995

    // MARK: - Helpers

    /// Returns the accent color for a given pane type.
    static func accentColor(for type: PaneType) -> Color {
        switch type {
        case .terminal: return accentTerminal
        case .analytics: return accentAnalytics
        case .markdownPreview, .htmlPreview: return accentPreview
        case .skillLibrary: return accentSkillLibrary
        case .knowledgeBase: return accentKnowledgeBase
        case .modelManager: return accentModelManager
        case .scheduleManager: return accentScheduleManager
        }
    }

    /// Returns the SF Symbol name for a given pane type.
    static func iconName(for type: PaneType) -> String {
        switch type {
        case .terminal: return "terminal"
        case .analytics: return "chart.bar"
        case .markdownPreview: return "doc.richtext"
        case .htmlPreview: return "globe"
        case .skillLibrary: return "puzzlepiece.extension"
        case .knowledgeBase: return "magnifyingglass"
        case .modelManager: return "brain"
        case .scheduleManager: return "calendar.badge.clock"
        }
    }

    /// Returns a short description for a given pane type.
    static func description(for type: PaneType) -> String {
        switch type {
        case .terminal: return "Run commands and AI agents"
        case .analytics: return "Charts and cost tracking"
        case .markdownPreview: return "Live preview .md files"
        case .htmlPreview: return "Preview web pages"
        case .skillLibrary: return "Browse your AI skills"
        case .knowledgeBase: return "Search your AI history"
        case .modelManager: return "Download and manage ML models"
        case .scheduleManager: return "View scheduled tasks"
        }
    }

    /// Returns a human-readable display name for a given pane type.
    static func displayName(for type: PaneType) -> String {
        switch type {
        case .terminal: return "Terminal"
        case .analytics: return "Analytics"
        case .markdownPreview: return "Markdown Preview"
        case .htmlPreview: return "HTML Preview"
        case .skillLibrary: return "Skill Library"
        case .knowledgeBase: return "Knowledge Base"
        case .modelManager: return "Model Manager"
        case .scheduleManager: return "Schedules"
        }
    }
}
