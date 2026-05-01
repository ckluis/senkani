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

    /// Pane type entries. One per pane type. Source of truth is
    /// `PaneGalleryBuilder.allEntries()` — keep IDs in sync via the parity test
    /// in `CommandPaletteTests` so the palette can never advertise a pane the
    /// gallery doesn't ship (or vice versa).
    public static func paneEntries() -> [CommandEntryData] {
        return PaneGalleryBuilder.allEntries().map { entry in
            CommandEntryData(
                id: "pane:\(entry.id)",
                title: "New \(entry.name)",
                subtitle: entry.description,
                icon: entry.icon,
                category: "Panes"
            )
        }
    }

    /// Action entries. Empty until each candidate (toggles, close-all, run
    /// benchmark, export session) is wired through `CommandPaletteView` with a
    /// concrete callback. The palette must never display a row that does
    /// nothing on Enter — see `onboarding-p1-command-palette-contract` and the
    /// `noInertActionEntries` test.
    public static func actionEntries() -> [CommandEntryData] {
        return []
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
