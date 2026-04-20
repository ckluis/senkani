import Testing
import Foundation
@testable import Core

@Suite("Command Palette")
struct CommandPaletteTests {

    @Test func paneEntriesIncludeAllTypes() {
        let entries = CommandEntryBuilder.paneEntries()
        #expect(entries.count == 17, "Should have 17 pane types, got \(entries.count)")
    }

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

    @Test func categoryGroupingCorrect() {
        let all = CommandEntryBuilder.paneEntries() + CommandEntryBuilder.actionEntries()
        let groups = CommandEntryBuilder.grouped(all)
        let categories = groups.map(\.category)
        #expect(categories.contains("Panes"))
        #expect(categories.contains("Actions"))
    }

    @Test func actionEntriesHaveIds() {
        let actions = CommandEntryBuilder.actionEntries()
        for action in actions {
            #expect(!action.id.isEmpty, "Action '\(action.title)' should have non-empty ID")
        }
    }

    @Test func filterCaseInsensitive() {
        let all = CommandEntryBuilder.paneEntries()
        let filtered = CommandEntryBuilder.filter(all, query: "TERMINAL")
        #expect(filtered.contains { $0.title == "New Terminal" },
                "Case-insensitive search should match")
    }
}
