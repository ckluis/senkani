import Testing
import Foundation
@testable import Core

@Suite("Pane Gallery")
struct PaneGalleryTests {

    @Test func allEntriesCoversAll20PaneTypes() {
        let entries = PaneGalleryBuilder.allEntries()
        #expect(entries.count == 20, "Should have 20 pane types, got \(entries.count)")
    }

    @Test func dashboardIsPresent() {
        // Regression pin: the pre-refactor AddPaneSheet shipped with
        // Dashboard missing from its 16-entry list. Never again.
        let entries = PaneGalleryBuilder.allEntries()
        #expect(entries.contains { $0.id == "dashboard" },
                "Dashboard pane must be in the gallery")
    }

    @Test func everyEntryHasUniqueID() {
        let entries = PaneGalleryBuilder.allEntries()
        let ids = entries.map(\.id)
        #expect(Set(ids).count == ids.count, "IDs must be unique")
    }

    @Test func launchMapMatchesGallery() {
        // Regression pin: `artifactGallery` shipped in the gallery (and so in
        // the ⌘K palette rows) but was missing from the command palette's
        // launch map, making "New Artifact Gallery" a silent dead click. The
        // app-target launchers (ContentView.addPaneByTypeId + AddPaneSheet)
        // now derive from PaneGalleryBuilder.launchMap, so this Core test is
        // the single guard that every gallery id has a launch path and that
        // the launch map advertises no id the gallery doesn't ship.
        let galleryIDs = Set(PaneGalleryBuilder.allEntries().map(\.id))
        let launchIDs = Set(PaneGalleryBuilder.launchMap.keys)
        let galleryOnly = galleryIDs.subtracting(launchIDs)
        let launchOnly = launchIDs.subtracting(galleryIDs)
        #expect(galleryOnly.isEmpty,
                "Gallery ships panes with no launch path (dead ⌘K rows): \(galleryOnly)")
        #expect(launchOnly.isEmpty,
                "Launch map references ids not in the gallery: \(launchOnly)")
    }

    @Test func everyLaunchIDResolvesToNonEmptyDefaultTitle() {
        // The ⌘K command palette (ContentView.addPaneByTypeId) titles a new
        // pane via PaneGalleryBuilder.defaultTitle(forLaunchID:), matching the
        // Add-Pane sheet. Every launchMap key MUST resolve to a non-nil,
        // non-empty title — a nil would fall back to the camelCase id (the
        // ugly-title defect this guards), and an empty title would render a
        // blank pane header.
        for id in PaneGalleryBuilder.launchMap.keys {
            let title = PaneGalleryBuilder.defaultTitle(forLaunchID: id)
            #expect(title != nil,
                    "launchMap key '\(id)' has no gallery entry — would fall back to ugly id.capitalized")
            #expect(!(title ?? "").isEmpty,
                    "launchMap key '\(id)' resolves to an empty defaultTitle")
        }
    }

    @Test func camelCaseLaunchIDsResolveToCleanTitles() {
        // Regression pin: the ⌘K palette shipped `typeId.capitalized`, so a
        // camelCase gallery id collapsed to one mangled word
        // (`artifactGallery` → "Artifactgallery") while the Add-Pane sheet
        // showed the clean `defaultTitle`. Both surfaces must now agree.
        let expected: [String: String] = [
            "artifactGallery": "Artifacts",
            "openAIServedRequests": "Served Requests",
            "skillLibrary": "Skills",
            "agentTimeline": "Timeline",
            "knowledgeBase": "Knowledge",
            "sprintReview": "Sprint Review",
        ]
        for (id, title) in expected {
            #expect(PaneGalleryBuilder.defaultTitle(forLaunchID: id) == title,
                    "Launch id '\(id)' should title to '\(title)', not id.capitalized")
        }
    }

    @Test func unknownLaunchIDResolvesToNil() {
        #expect(PaneGalleryBuilder.defaultTitle(forLaunchID: "nonexistentPaneId") == nil,
                "An id with no gallery entry must return nil so the caller can fall back")
    }

    @Test func everyCategoryHasAtMostSixEntries() {
        // Acceptance bullet: ≤6 cells per category so the gallery stays
        // skimmable.
        let grouped = PaneGalleryBuilder.categorized()
        for group in grouped {
            #expect(group.entries.count <= 6,
                    "Category '\(group.category)' has \(group.entries.count) entries (max 6)")
        }
    }

    @Test func everyEntryBelongsToAKnownCategory() {
        let known = Set(PaneGalleryBuilder.categoryOrder)
        for entry in PaneGalleryBuilder.allEntries() {
            #expect(known.contains(entry.category),
                    "Entry '\(entry.id)' has unknown category '\(entry.category)'")
        }
    }

    @Test func categorizationIsTotal() {
        // Every pane appears in exactly one category; no pane is dropped.
        let grouped = PaneGalleryBuilder.categorized()
        let groupedCount = grouped.reduce(0) { $0 + $1.entries.count }
        #expect(groupedCount == PaneGalleryBuilder.allEntries().count,
                "Categorization lost \(PaneGalleryBuilder.allEntries().count - groupedCount) entries")
    }

    @Test func categoryOrderIsStable() {
        let grouped = PaneGalleryBuilder.categorized()
        let actualOrder = grouped.map(\.category)
        let expectedOrder = PaneGalleryBuilder.categoryOrder.filter { cat in
            PaneGalleryBuilder.allEntries().contains { $0.category == cat }
        }
        #expect(actualOrder == expectedOrder, "Category order drifted")
    }

    @Test func descriptionsAreShortEnoughForTwoLineCard() {
        // Acceptance bullet: ≤80-char description (Podmajersky microcopy bar).
        for entry in PaneGalleryBuilder.allEntries() {
            #expect(entry.description.count <= 80,
                    "Entry '\(entry.id)' description is \(entry.description.count) chars (max 80): \(entry.description)")
        }
    }

    @Test func filterIsCaseInsensitiveOnName() {
        let all = PaneGalleryBuilder.allEntries()
        let upper = PaneGalleryBuilder.filter(all, query: "TERMINAL")
        let lower = PaneGalleryBuilder.filter(all, query: "terminal")
        #expect(upper.contains { $0.id == "terminal" })
        #expect(lower.contains { $0.id == "terminal" })
        #expect(upper.count == lower.count)
    }

    @Test func filterMatchesDescription() {
        let all = PaneGalleryBuilder.allEntries()
        let filtered = PaneGalleryBuilder.filter(all, query: "syntax highlighting")
        #expect(filtered.contains { $0.id == "codeEditor" },
                "Filter should match the codeEditor description substring")
    }

    @Test func emptyQueryReturnsAll() {
        let all = PaneGalleryBuilder.allEntries()
        let filtered = PaneGalleryBuilder.filter(all, query: "")
        #expect(filtered.count == all.count)
    }

    @Test func categorizedHandlesFilterResults() {
        // When a filter shrinks entries to one category, only that
        // category appears in the grouped output.
        let all = PaneGalleryBuilder.allEntries()
        let filtered = PaneGalleryBuilder.filter(all, query: "dashboard")
        let grouped = PaneGalleryBuilder.categorized(filtered)
        #expect(grouped.count == 1, "One hit should collapse to one category")
        #expect(grouped.first?.category == "Data & Insights")
    }
}
