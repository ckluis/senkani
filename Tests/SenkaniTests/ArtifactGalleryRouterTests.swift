import Testing
import Foundation
@testable import Core

// V.9b-1 — ArtifactGalleryRouter tests.
//
// 8 tests covering the navigation contract the SwiftUI view consumes:
//   1. PaneDiary route extracts workspace + pane slugs from ID
//   2. SprintReview route extracts kind + rowId from ID
//   3. Filesystem route resolves absolute path against artifactsDirectory
//   4. ID-source-pane mismatch returns nil (defensive)
//   5. Malformed ID (too few parts) returns nil
//   6. PaneSlug with embedded colons survives parse round-trip
//   7. Reveal-sheet canonical copy carries source-pane + hit count
//   8. Reveal-sheet copy varies per source-pane lane

private let fixedDate = Date(timeIntervalSince1970: 1_716_500_000)

private func makeRecord(
    sourcePane: ArtifactSourcePane,
    surfaceKey: String,
    rowOrPath: String,
    redacted: Bool = false
) -> ArtifactRecord {
    ArtifactRecord(
        id: ArtifactID(sourcePane: sourcePane, surfaceKey: surfaceKey, rowOrPath: rowOrPath),
        sourcePane: sourcePane,
        tags: [],
        version: 1,
        createdAt: fixedDate,
        previousVersion: nil,
        redactionMarker: redacted ? ArtifactRedactionMarker(
            sourcePane: sourcePane,
            hitPatternNames: ["ANTHROPIC_API_KEY"],
            hitCount: 1
        ) : nil
    )
}

// MARK: - 1-3. Happy-path routes per source pane

@Suite("V.9b-1 ArtifactGalleryRouter — per-source-pane routes")
struct ArtifactGalleryRouterRouteTests {

    @Test("paneDiary record routes to openOrFocusPaneDiary with workspace + pane slugs")
    func paneDiaryRoute() {
        let r = makeRecord(sourcePane: .paneDiary, surfaceKey: "ws-A", rowOrPath: "terminal")
        let route = ArtifactGalleryRouter.route(for: r, artifactsDirectory: "/tmp/v9b/artifacts")
        #expect(route == .openOrFocusPaneDiary(workspaceSlug: "ws-A", paneSlug: "terminal"))
    }

    @Test("sprintReview record routes to focusSprintReview with kind + rowId")
    func sprintReviewRoute() {
        let r = makeRecord(sourcePane: .sprintReview, surfaceKey: "filterRule", rowOrPath: "rule-7")
        let route = ArtifactGalleryRouter.route(for: r, artifactsDirectory: "/tmp/v9b/artifacts")
        #expect(route == .focusSprintReview(rowId: "rule-7", kind: "filterRule"))
    }

    @Test("filesystem record routes to revealInFinder with absolute path")
    func filesystemRoute() {
        let r = makeRecord(sourcePane: .filesystem, surfaceKey: "notes", rowOrPath: "notes.v3.md")
        let route = ArtifactGalleryRouter.route(for: r, artifactsDirectory: "/tmp/v9b/artifacts")
        #expect(route == .revealInFinder(absolutePath: "/tmp/v9b/artifacts/notes.v3.md"))
    }
}

// MARK: - 4-6. Defensive parsing

@Suite("V.9b-1 ArtifactGalleryRouter — defensive parsing")
struct ArtifactGalleryRouterDefensiveTests {

    @Test("ID prefix mismatching the record's sourcePane returns nil")
    func sourcePaneMismatch() {
        // sourcePane says .paneDiary but the ID's prefix says filesystem.
        // Production-grade IDs never have this mismatch; the router
        // defends by returning nil rather than misrouting.
        let id = ArtifactID("filesystem:ws-A:terminal")
        let r = ArtifactRecord(
            id: id, sourcePane: .paneDiary, tags: [],
            version: 1, createdAt: fixedDate
        )
        let route = ArtifactGalleryRouter.route(for: r, artifactsDirectory: "/tmp/v9b/artifacts")
        #expect(route == nil)
    }

    @Test("Malformed ID with too few colon-separated parts returns nil")
    func malformedID() {
        let id = ArtifactID("paneDiary:ws-A")  // missing the third segment
        let r = ArtifactRecord(
            id: id, sourcePane: .paneDiary, tags: [],
            version: 1, createdAt: fixedDate
        )
        let route = ArtifactGalleryRouter.route(for: r, artifactsDirectory: "/tmp/v9b/artifacts")
        #expect(route == nil)
    }

    @Test("Path segment with embedded colons survives parse round-trip")
    func embeddedColons() {
        // Filesystem filenames may contain colons (legal on macOS HFS+
        // for the basename portion in some encodings). The parser
        // rejoins parts[2...] preserving the trailing colons.
        let r = makeRecord(sourcePane: .filesystem, surfaceKey: "weird",
                           rowOrPath: "name:with:colons.md")
        let route = ArtifactGalleryRouter.route(for: r, artifactsDirectory: "/tmp/v9b/artifacts")
        #expect(route == .revealInFinder(absolutePath: "/tmp/v9b/artifacts/name:with:colons.md"))
    }
}

// MARK: - 7-8. Reveal-sheet canonical copy

@Suite("V.9b-1 ArtifactGalleryRouter — reveal-sheet canonical copy")
struct RevealSheetCopyTests {

    @Test("Reveal-sheet copy carries source-pane + hit count + audit-row mention")
    func revealCopyShape() {
        let copy = ArtifactGalleryRouter.revealSheetCopy(sourcePane: .paneDiary, hitCount: 3)
        #expect(copy.contains("paneDiary"))
        #expect(copy.contains("3"))
        #expect(copy.contains("artifact.secret.allow"))
        #expect(copy.contains("audit chain"))
        // Norman P0: the copy is canonical — pin it verbatim.
        #expect(copy == "Reveal redacted body? Source: paneDiary. Redaction marker hits: 3. This writes an artifact.secret.allow row to your audit chain.")
    }

    @Test("Reveal-sheet copy varies per source-pane lane")
    func revealCopyVariesByLane() {
        let diary = ArtifactGalleryRouter.revealSheetCopy(sourcePane: .paneDiary, hitCount: 1)
        let fs = ArtifactGalleryRouter.revealSheetCopy(sourcePane: .filesystem, hitCount: 1)
        let review = ArtifactGalleryRouter.revealSheetCopy(sourcePane: .sprintReview, hitCount: 1)
        #expect(diary != fs)
        #expect(diary != review)
        #expect(fs != review)
        #expect(diary.contains("paneDiary"))
        #expect(fs.contains("filesystem"))
        #expect(review.contains("sprintReview"))
    }
}
