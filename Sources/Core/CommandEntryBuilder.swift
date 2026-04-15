import Foundation

/// Data model for command palette entries. Lives in Core for testability.
public struct CommandEntryData: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let icon: String
    public let category: String  // "Panes", "Themes", "Actions"

    public init(id: String, title: String, subtitle: String, icon: String, category: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.category = category
    }
}

/// Builds and filters command palette entries.
public enum CommandEntryBuilder {

    /// Pane type entries. One per pane type.
    public static func paneEntries() -> [CommandEntryData] {
        let types: [(id: String, name: String, desc: String, icon: String)] = [
            ("terminal", "New Terminal", "Run commands and AI agents", "terminal"),
            ("browser", "New Browser", "WKWebView — docs, localhost, APIs", "globe"),
            ("markdownPreview", "New Markdown Preview", "Live rendered markdown from file", "doc.richtext"),
            ("htmlPreview", "New HTML Preview", "Render HTML with CSP sandboxing", "safari"),
            ("scratchpad", "New Scratchpad", "Auto-saving markdown notepad", "note.text"),
            ("logViewer", "New Log Viewer", "Tail files with color filtering", "doc.text.magnifyingglass"),
            ("diffViewer", "New Diff Viewer", "Side-by-side file comparison", "arrow.left.arrow.right"),
            ("analytics", "New Analytics", "Savings charts and cost projections", "chart.line.uptrend.xyaxis"),
            ("skillLibrary", "New Skill Library", "Browse AI skills", "book.closed"),
            ("knowledgeBase", "New Knowledge Base", "Project knowledge entities", "brain.head.profile"),
            ("modelManager", "New Model Manager", "Download and manage ML models", "cpu"),
            ("schedules", "New Schedules", "Manage recurring tasks via launchd", "calendar"),
            ("savingsTest", "New Savings Test", "Benchmark optimizations", "gauge.with.dots.needle.67percent"),
            ("codeEditor", "New Code Editor", "Tree-sitter syntax highlighting", "curlybraces"),
            ("agentTimeline", "New Agent Timeline", "Tool call history", "clock.arrow.circlepath"),
            ("dashboard", "New Dashboard", "Multi-project portfolio overview", "chart.bar.doc.horizontal"),
        ]
        return types.map { t in
            CommandEntryData(id: "pane:\(t.id)", title: t.name, subtitle: t.desc, icon: t.icon, category: "Panes")
        }
    }

    /// Action entries. Global commands like toggles, close-all, settings.
    public static func actionEntries() -> [CommandEntryData] {
        return [
            CommandEntryData(id: "action:toggle_filter", title: "Toggle Filter", subtitle: "Enable/disable output compression", icon: "line.3.horizontal.decrease.circle", category: "Actions"),
            CommandEntryData(id: "action:toggle_cache", title: "Toggle Cache", subtitle: "Enable/disable session file cache", icon: "arrow.triangle.2.circlepath", category: "Actions"),
            CommandEntryData(id: "action:toggle_secrets", title: "Toggle Secrets", subtitle: "Enable/disable secret redaction", icon: "lock.shield", category: "Actions"),
            CommandEntryData(id: "action:toggle_indexer", title: "Toggle Indexer", subtitle: "Enable/disable symbol navigation", icon: "list.bullet.indent", category: "Actions"),
            CommandEntryData(id: "action:toggle_terse", title: "Toggle Terse", subtitle: "Enable/disable output minimization", icon: "text.word.spacing", category: "Actions"),
            CommandEntryData(id: "action:close_all", title: "Close All Panes", subtitle: "Remove all panes from workspace", icon: "xmark.square", category: "Actions"),
            CommandEntryData(id: "action:run_benchmark", title: "Run Benchmark", subtitle: "Execute the token savings test suite", icon: "gauge.with.dots.needle.67percent", category: "Actions"),
            CommandEntryData(id: "action:export_session", title: "Export Session", subtitle: "Save session data as JSON", icon: "square.and.arrow.up", category: "Actions"),
        ]
    }

    /// Filter entries by search query (case-insensitive substring match on title + subtitle).
    public static func filter(_ entries: [CommandEntryData], query: String) -> [CommandEntryData] {
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.title.localizedCaseInsensitiveContains(query)
            || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    /// Group entries by category, preserving order within each group.
    public static func grouped(_ entries: [CommandEntryData]) -> [(category: String, entries: [CommandEntryData])] {
        let order = ["Panes", "Actions", "Themes"]
        var groups: [String: [CommandEntryData]] = [:]
        for entry in entries {
            groups[entry.category, default: []].append(entry)
        }
        return order.compactMap { cat in
            guard let items = groups[cat], !items.isEmpty else { return nil }
            return (category: cat, entries: items)
        }
    }
}
