import Testing
import Foundation
@testable import Core

@Suite("Command Palette")
struct CommandPaletteTests {

    // MARK: - Parity with PaneGallery (the single source of truth)
    //
    // The command palette and the Add-Pane sheet must agree on what panes
    // exist. A pane in one but not the other is either an inert command-
    // palette row (advertised but won't launch through the gallery's typeMap)
    // or a hidden gallery entry (launchable via the sheet but invisible to
    // ⌘K search). Both regressions are silent without parity coverage.

    @Test func paneEntriesMatchPaneGalleryIDs() {
        let paletteIDs = Set(CommandEntryBuilder.paneEntries().map {
            String($0.id.dropFirst("pane:".count))
        })
        let galleryIDs = Set(PaneGalleryBuilder.allEntries().map(\.id))
        let paletteOnly = paletteIDs.subtracting(galleryIDs)
        let galleryOnly = galleryIDs.subtracting(paletteIDs)
        #expect(paletteOnly.isEmpty,
                "Command palette advertises panes the gallery doesn't ship")
        #expect(galleryOnly.isEmpty,
                "Pane gallery ships panes the command palette can't find")
    }

    @Test func paneEntriesMatchPaneGalleryCount() {
        #expect(CommandEntryBuilder.paneEntries().count
                == PaneGalleryBuilder.allEntries().count)
    }

    @Test func paneEntriesIncludeOllamaLauncher() {
        let titles = CommandEntryBuilder.paneEntries().map(\.title)
        #expect(titles.contains("New Ollama"),
                "Ollama pane must be reachable from ⌘K, not just AddPaneSheet")
    }

    // MARK: - Honesty contract: no inert actions
    //
    // CommandPaletteView.executeEntry only handles `pane:` IDs; any
    // `action:*` row dismisses without effect. Until each action gets a
    // concrete callback wired through CommandPaletteView, actionEntries()
    // must stay empty so the palette never advertises something it can't do.

    @Test func noInertActionEntries() {
        #expect(CommandEntryBuilder.actionEntries().isEmpty,
                "Action entries must be empty until wired with a real callback")
    }

    // MARK: - Hygiene

    @Test func paneEntriesHaveNoDuplicateIDs() {
        let ids = CommandEntryBuilder.paneEntries().map(\.id)
        #expect(ids.count == Set(ids).count, "Duplicate pane IDs in palette")
    }

    @Test func paneEntriesHaveNonEmptyCopy() {
        for entry in CommandEntryBuilder.paneEntries() {
            #expect(!entry.title.isEmpty, "Empty title: \(entry.id)")
            #expect(!entry.subtitle.isEmpty, "Empty subtitle: \(entry.id)")
            #expect(!entry.icon.isEmpty, "Empty icon: \(entry.id)")
        }
    }

    // MARK: - Filter / grouping behaviors (kept from prior coverage)

    @Test func searchFilteringWorks() {
        let all = CommandEntryBuilder.paneEntries() + CommandEntryBuilder.actionEntries()
        let filtered = CommandEntryBuilder.filter(all, query: "term")
        #expect(filtered.contains { $0.title.contains("Terminal") },
                "Searching 'term' should match Terminal")
    }

    @Test func emptySearchShowsAll() {
        let all = CommandEntryBuilder.paneEntries() + CommandEntryBuilder.actionEntries()
        let filtered = CommandEntryBuilder.filter(all, query: "")
        #expect(filtered.count == all.count, "Empty search should return all entries")
    }

    @Test func categoryGroupingShowsPanes() {
        let all = CommandEntryBuilder.paneEntries() + CommandEntryBuilder.actionEntries()
        let groups = CommandEntryBuilder.grouped(all)
        let categories = groups.map(\.category)
        #expect(categories.contains("Panes"))
        #expect(!categories.contains("Actions"),
                "Empty Actions category must not render a header")
    }

    @Test func filterCaseInsensitive() {
        let all = CommandEntryBuilder.paneEntries()
        let filtered = CommandEntryBuilder.filter(all, query: "TERMINAL")
        #expect(filtered.contains { $0.title == "New Terminal" },
                "Case-insensitive search should match")
    }
}
