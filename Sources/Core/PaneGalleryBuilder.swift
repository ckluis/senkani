import Foundation

/// Data model for Add-Pane gallery entries. Lives in Core for testability.
/// Mirrors CommandEntryBuilder — string IDs decouple Core from the app
/// target's PaneType enum.
public struct PaneGalleryEntry: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let icon: String
    public let category: String
    public let defaultTitle: String

    public init(id: String, name: String, description: String, icon: String, category: String, defaultTitle: String) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.category = category
        self.defaultTitle = defaultTitle
    }
}

/// Categorized pane gallery for the Add-Pane sheet.
///
/// Categories (Morville + Norman) are mutually-exclusive and collectively-
/// exhaustive across the 20 pane types. Order is stable for display.
public enum PaneGalleryBuilder {

    public static let categoryOrder: [String] = [
        "Shell & Agents",
        "AI & Models",
        "Data & Insights",
        "Docs & Code",
    ]

    /// All 20 pane types with category assignments. Adding a new PaneType
    /// requires adding an entry here AND registering it in the app target's
    /// string→PaneType map (see AddPaneSheet + ContentView).
    public static func allEntries() -> [PaneGalleryEntry] {
        return [
            // Shell & Agents — where you TALK to tools
            PaneGalleryEntry(id: "terminal", name: "Terminal",
                description: "Run commands and AI agents",
                icon: "terminal", category: "Shell & Agents",
                defaultTitle: "Terminal"),
            PaneGalleryEntry(id: "agentTimeline", name: "Agent Timeline",
                description: "Live feed of optimization events",
                icon: "clock.arrow.circlepath", category: "Shell & Agents",
                defaultTitle: "Timeline"),

            // AI & Models — senkani's intelligence surfaces
            PaneGalleryEntry(id: "skillLibrary", name: "Skill Library",
                description: "Browse your AI skills",
                icon: "book.closed", category: "AI & Models",
                defaultTitle: "Skills"),
            PaneGalleryEntry(id: "knowledgeBase", name: "Knowledge Base",
                description: "Project knowledge entities + decisions",
                icon: "brain.head.profile", category: "AI & Models",
                defaultTitle: "Knowledge"),
            PaneGalleryEntry(id: "modelManager", name: "Models",
                description: "Download and manage ML models",
                icon: "cpu", category: "AI & Models",
                defaultTitle: "Models"),
            PaneGalleryEntry(id: "sprintReview", name: "Sprint Review",
                description: "Review staged compound-learning proposals",
                icon: "sparkles.rectangle.stack", category: "AI & Models",
                defaultTitle: "Sprint Review"),
            PaneGalleryEntry(id: "artifactGallery", name: "Artifact Gallery",
                description: "Browse diaries, sprint snapshots, and on-disk artifacts",
                icon: "rectangle.stack.badge.person.crop", category: "AI & Models",
                defaultTitle: "Artifacts"),
            PaneGalleryEntry(id: "ollamaLauncher", name: "Ollama",
                description: "Local LLM chat via Ollama",
                icon: "cpu.fill", category: "AI & Models",
                defaultTitle: "Ollama"),

            // Data & Insights — where you MEASURE and schedule
            PaneGalleryEntry(id: "dashboard", name: "Dashboard",
                description: "Multi-project portfolio overview",
                icon: "chart.bar.doc.horizontal", category: "Data & Insights",
                defaultTitle: "Dashboard"),
            PaneGalleryEntry(id: "analytics", name: "Analytics",
                description: "Charts and cost tracking",
                icon: "chart.line.uptrend.xyaxis", category: "Data & Insights",
                defaultTitle: "Analytics"),
            PaneGalleryEntry(id: "savingsTest", name: "Savings Test",
                description: "Benchmark optimization savings",
                icon: "gauge.with.dots.needle.67percent", category: "Data & Insights",
                defaultTitle: "Savings Test"),
            PaneGalleryEntry(id: "schedules", name: "Schedules",
                description: "View scheduled tasks",
                icon: "calendar", category: "Data & Insights",
                defaultTitle: "Schedules"),
            PaneGalleryEntry(id: "logViewer", name: "Log Viewer",
                description: "Tail and filter log files",
                icon: "doc.text.magnifyingglass", category: "Data & Insights",
                defaultTitle: "Log"),
            PaneGalleryEntry(id: "openAIServedRequests", name: "Served Requests",
                description: "Live feed of OpenAI-compatible served requests",
                icon: "network", category: "Data & Insights",
                defaultTitle: "Served Requests"),

            // Docs & Code — where you READ and edit
            PaneGalleryEntry(id: "codeEditor", name: "Code Editor",
                description: "View code with syntax highlighting",
                icon: "curlybraces", category: "Docs & Code",
                defaultTitle: "Code"),
            PaneGalleryEntry(id: "markdownPreview", name: "Markdown Preview",
                description: "Live preview .md files",
                icon: "doc.richtext", category: "Docs & Code",
                defaultTitle: "Markdown"),
            PaneGalleryEntry(id: "htmlPreview", name: "HTML Preview",
                description: "Preview web pages with CSP sandboxing",
                icon: "safari", category: "Docs & Code",
                defaultTitle: "HTML"),
            PaneGalleryEntry(id: "browser", name: "Browser",
                description: "Browse URLs and localhost",
                icon: "globe", category: "Docs & Code",
                defaultTitle: "Browser"),
            PaneGalleryEntry(id: "diffViewer", name: "Diff Viewer",
                description: "Compare files side by side",
                icon: "arrow.left.arrow.right", category: "Docs & Code",
                defaultTitle: "Diff"),
            PaneGalleryEntry(id: "scratchpad", name: "Scratchpad",
                description: "Quick notes and scratch space",
                icon: "note.text", category: "Docs & Code",
                defaultTitle: "Notes"),
        ]
    }

    /// Canonical launch map: gallery entry `id` → `PaneType` raw value.
    ///
    /// Single source of truth for the string→PaneType binding the app target
    /// resolves via `PaneType(rawValue:)`. It lives in Core (not the
    /// non-importable `SenkaniApp` executable target) so the
    /// gallery-id ⇄ launch-path parity is unit-testable — the defect class
    /// this guards is "a gallery id with no launch path" (a dead ⌘K row),
    /// which `PaneGalleryTests.launchMapMatchesGallery` now fails CI on.
    ///
    /// The app target's command palette (`ContentView.addPaneByTypeId`) and
    /// Add-Pane sheet (`AddPaneSheet.idToType`) DERIVE their
    /// `[String: PaneType]` launchers from this map rather than hand-mirroring
    /// it, so the two app surfaces can no longer drift from each other or from
    /// the gallery.
    ///
    /// Almost every id maps to the identically-named `PaneType` case; the sole
    /// exception is `schedules` → `scheduleManager`. Adding a pane type: add an
    /// entry in `allEntries()` AND a row here — the parity test enforces both.
    public static let launchMap: [String: String] = [
        "terminal": "terminal",
        "agentTimeline": "agentTimeline",
        "skillLibrary": "skillLibrary",
        "knowledgeBase": "knowledgeBase",
        "modelManager": "modelManager",
        "sprintReview": "sprintReview",
        "artifactGallery": "artifactGallery",
        "ollamaLauncher": "ollamaLauncher",
        "dashboard": "dashboard",
        "analytics": "analytics",
        "savingsTest": "savingsTest",
        "schedules": "scheduleManager",
        "logViewer": "logViewer",
        "openAIServedRequests": "openAIServedRequests",
        "codeEditor": "codeEditor",
        "markdownPreview": "markdownPreview",
        "htmlPreview": "htmlPreview",
        "browser": "browser",
        "diffViewer": "diffViewer",
        "scratchpad": "scratchpad",
    ]

    /// Display title for a launch id (a `launchMap` key / gallery `id`).
    ///
    /// Both launch surfaces resolve the new pane's title through the gallery's
    /// `defaultTitle` so the SAME pane gets the SAME title regardless of where
    /// it was launched: the Add-Pane sheet (`AddPaneSheet`, which holds the
    /// entry directly) and the ⌘K command palette
    /// (`ContentView.addPaneByTypeId`, which resolves through this helper).
    /// The bug this closes: the palette used `id.capitalized`, which mangles
    /// camelCase ids (`artifactGallery` → "Artifactgallery") while the sheet
    /// showed the clean `defaultTitle` ("Artifacts") — one pane, two names.
    ///
    /// Returns nil if no entry matches; `launchMapMatchesGallery` guarantees
    /// every `launchMap` key has a matching gallery entry, so callers using a
    /// `launchMap` key always get a non-nil title.
    public static func defaultTitle(forLaunchID id: String) -> String? {
        return allEntries().first(where: { $0.id == id })?.defaultTitle
    }

    /// Entries grouped by category, in `categoryOrder`. Empty categories
    /// are omitted. Within a category, entries preserve `allEntries()` order.
    public static func categorized(_ entries: [PaneGalleryEntry] = allEntries())
        -> [(category: String, entries: [PaneGalleryEntry])] {
        var groups: [String: [PaneGalleryEntry]] = [:]
        for entry in entries {
            groups[entry.category, default: []].append(entry)
        }
        return categoryOrder.compactMap { cat in
            guard let items = groups[cat], !items.isEmpty else { return nil }
            return (category: cat, entries: items)
        }
    }

    /// Case-insensitive substring filter on name + description.
    public static func filter(_ entries: [PaneGalleryEntry], query: String) -> [PaneGalleryEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(query)
            || $0.description.localizedCaseInsensitiveContains(query)
        }
    }
}
