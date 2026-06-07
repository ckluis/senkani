import Testing
import Foundation
@testable import Core

// V.9b-2 — ArtifactGalleryFilterModel tests.
//
// 6 tests covering the chip-state → ArtifactFilter mapping the
// SwiftUI toolbar consumes:
//   1. Source-pane chip toggle excludes the deselected pane.
//   2. Tag chips compose OR-within.
//   3. Version range filters by min/max bounds.
//   4. Since-date filters by created-at lower bound.
//   5. Combined source + tag + version + since composes AND-across.
//   6. clearAll() returns the model to unconstrained; list returns
//      the full record set.

private let fixedDate = Date(timeIntervalSince1970: 1_716_000_000)

private func record(
    pane: ArtifactSourcePane,
    surface: String,
    row: String,
    tags: Set<String>,
    version: Int = 1,
    createdAt: Date = fixedDate
) -> ArtifactRecord {
    ArtifactRecord(
        id: ArtifactID(sourcePane: pane, surfaceKey: surface, rowOrPath: row),
        sourcePane: pane,
        tags: tags,
        version: version,
        createdAt: createdAt
    )
}

// In-memory provider so the tests focus on the chip-state model and
// store filter composition — not on disk/sqlite mechanics, which
// V.9a's ArtifactStoreTests already cover exhaustively.
private struct InMemoryArtifactProvider: ArtifactSourceProvider {
    let sourcePane: ArtifactSourcePane
    let records: [ArtifactRecord]

    func list() -> [ArtifactRecord] { records }
    func read(_ id: ArtifactID) throws -> ArtifactBody {
        ArtifactBody("")
    }
    func versions(of id: ArtifactID) -> [ArtifactRecord] { [] }
}

// Three providers, one per source pane, each carrying a handful of
// records that span the four filter dimensions. Created-at values
// are spaced so the since-filter test can pick an unambiguous cut.
private func fixtureStore() -> ArtifactStore {
    let diary = InMemoryArtifactProvider(
        sourcePane: .paneDiary,
        records: [
            record(pane: .paneDiary, surface: "ws", row: "terminal",
                   tags: ["bug", "ux"], version: 1,
                   createdAt: fixedDate),
            record(pane: .paneDiary, surface: "ws", row: "agent",
                   tags: ["security"], version: 2,
                   createdAt: fixedDate.addingTimeInterval(3600)),
        ]
    )
    let sprint = InMemoryArtifactProvider(
        sourcePane: .sprintReview,
        records: [
            record(pane: .sprintReview, surface: "filterRule",
                   row: "rule-7", tags: ["ux", "review"],
                   version: 3, createdAt: fixedDate.addingTimeInterval(7200)),
        ]
    )
    let fs = InMemoryArtifactProvider(
        sourcePane: .filesystem,
        records: [
            record(pane: .filesystem, surface: "snapshot",
                   row: "/tmp/a.txt", tags: ["bug"], version: 1,
                   createdAt: fixedDate.addingTimeInterval(10800)),
            record(pane: .filesystem, surface: "snapshot",
                   row: "/tmp/b.txt", tags: ["security", "ux"],
                   version: 4, createdAt: fixedDate.addingTimeInterval(14400)),
        ]
    )
    return ArtifactStore(providers: [diary, sprint, fs])
}

// MARK: - 1. Source-pane chip filtering

@Suite("V.9b-2 ArtifactGalleryFilterModel — source-pane chips")
struct ArtifactGalleryFilterModelSourcePaneTests {

    @Test("toggling paneDiary off excludes paneDiary records from list result")
    func toggleSourcePaneOff() {
        let store = fixtureStore()
        var model = ArtifactGalleryFilterModel.unconstrained

        // Sanity: default model returns every record (5 total).
        #expect(store.list(filter: model.filter).count == 5)

        model.toggleSourcePane(.paneDiary)

        let result = store.list(filter: model.filter)
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.sourcePane != .paneDiary })
        // The two non-paneDiary lanes survive in full.
        #expect(result.contains { $0.sourcePane == .sprintReview })
        #expect(result.contains { $0.sourcePane == .filesystem })
    }
}

// MARK: - 2. Tag chip composition (OR-within)

@Suite("V.9b-2 ArtifactGalleryFilterModel — tag chips")
struct ArtifactGalleryFilterModelTagChipsTests {

    @Test("two tag chips compose OR-within: union of matching artifacts")
    func tagChipsOrWithin() {
        let store = fixtureStore()
        var model = ArtifactGalleryFilterModel.unconstrained

        model.addTagChip("bug")
        model.addTagChip("review")

        let result = store.list(filter: model.filter)
        // "bug": paneDiary/terminal (v1) + filesystem/a.txt (v1)
        // "review": sprintReview/rule-7 (v3)
        // Union: 3 records.
        #expect(result.count == 3)
        let ids = Set(result.map(\.id.raw))
        #expect(ids.contains("paneDiary:ws:terminal"))
        #expect(ids.contains("filesystem:snapshot:/tmp/a.txt"))
        #expect(ids.contains("sprintReview:filterRule:rule-7"))
    }
}

// MARK: - 3. Version range filtering

@Suite("V.9b-2 ArtifactGalleryFilterModel — version range")
struct ArtifactGalleryFilterModelVersionRangeTests {

    @Test("min=2 max=3 returns only v2 and v3 records")
    func versionRange2to3() {
        let store = fixtureStore()
        var model = ArtifactGalleryFilterModel.unconstrained
        model.versionMin = 2
        model.versionMax = 3

        let result = store.list(filter: model.filter)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.version >= 2 && $0.version <= 3 })
        // v1 and v4 records are excluded.
        #expect(!result.contains { $0.version == 1 })
        #expect(!result.contains { $0.version == 4 })
    }
}

// MARK: - 4. Since-date filtering

@Suite("V.9b-2 ArtifactGalleryFilterModel — since")
struct ArtifactGalleryFilterModelSinceTests {

    @Test("since cuts records older than the threshold")
    func sinceCutsOlder() {
        let store = fixtureStore()
        var model = ArtifactGalleryFilterModel.unconstrained
        // Cut at +5400s — half-way between the +3600 paneDiary/agent
        // row and the +7200 sprintReview row. Three records survive:
        // sprintReview (+7200), filesystem/a (+10800), filesystem/b
        // (+14400).
        model.since = fixedDate.addingTimeInterval(5400)

        let result = store.list(filter: model.filter)
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.createdAt >= model.since! })
    }
}

// MARK: - 5. Combined AND-across composition

@Suite("V.9b-2 ArtifactGalleryFilterModel — combined")
struct ArtifactGalleryFilterModelCombinedTests {

    @Test("source + tag + version + since compose AND-across")
    func combinedAndAcross() {
        let store = fixtureStore()
        var model = ArtifactGalleryFilterModel.unconstrained
        // Restrict to filesystem only.
        model.toggleSourcePane(.paneDiary)
        model.toggleSourcePane(.sprintReview)
        // Tag chip: "ux" — matches paneDiary/terminal (excluded by
        // pane filter), sprintReview/rule-7 (excluded), and
        // filesystem/b.txt (v4, +14400).
        model.addTagChip("ux")
        // Version range 3-5 keeps v4 and rejects v1.
        model.versionMin = 3
        model.versionMax = 5
        // Since cut at +12000 keeps only filesystem/b.txt (+14400).
        model.since = fixedDate.addingTimeInterval(12000)

        let result = store.list(filter: model.filter)
        #expect(result.count == 1)
        let only = result[0]
        #expect(only.sourcePane == .filesystem)
        #expect(only.tags.contains("ux"))
        #expect(only.version == 4)
        #expect(only.createdAt >= model.since!)
    }
}

// MARK: - 6. Clear filter

@Suite("V.9b-2 ArtifactGalleryFilterModel — clear")
struct ArtifactGalleryFilterModelClearTests {

    @Test("clearAll() resets every dimension; list returns full set")
    func clearAllRestoresFullList() {
        let store = fixtureStore()
        var model = ArtifactGalleryFilterModel.unconstrained

        // Apply a multi-dimension filter — list shrinks.
        model.toggleSourcePane(.paneDiary)
        model.addTagChip("ux")
        model.versionMin = 3
        model.since = fixedDate.addingTimeInterval(1000)

        let filteredCount = store.list(filter: model.filter).count
        #expect(filteredCount < 5)
        #expect(!model.isUnconstrained)

        // Clear — list returns the full 5-record set.
        model.clearAll()
        #expect(model.isUnconstrained)
        #expect(model.filter == ArtifactFilter.unconstrained)
        #expect(store.list(filter: model.filter).count == 5)
    }
}
