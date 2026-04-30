import Testing
import Foundation
@testable import Core

// V.12a — DiffAnnotation type + DiffAnnotationLayout helpers.
@Suite("DiffAnnotation") struct DiffAnnotationTests {

    // MARK: - Frozen vocabulary

    @Test func severityVocabIsExactlyFourCases() {
        // The vocab is frozen as part of V.12a. If this test fires,
        // someone added or removed a severity case — that's a schema
        // break (rawValue is persisted by V.12b+).
        #expect(DiffAnnotationSeverity.allCases.count == 4)
        #expect(Set(DiffAnnotationSeverity.allCases.map(\.rawValue))
                == ["must-fix", "suggestion", "question", "nit"])
    }

    @Test func everyCaseHasLabelGlyphAndDistinctWeight() {
        let weights = DiffAnnotationSeverity.allCases.map(\.visualWeight)
        #expect(Set(weights).count == weights.count,
                "visualWeight must be distinct so sort ordering is stable")
        for sev in DiffAnnotationSeverity.allCases {
            #expect(!sev.label.isEmpty)
            #expect(!sev.glyphName.isEmpty)
        }
    }

    @Test func mustFixOutweighsAllOthers() {
        let mf = DiffAnnotationSeverity.mustFix.visualWeight
        for other in DiffAnnotationSeverity.allCases where other != .mustFix {
            #expect(mf > other.visualWeight, "must-fix must outweigh \(other.rawValue)")
        }
    }

    @Test func severityCodableRoundTrip() throws {
        let sev = DiffAnnotationSeverity.suggestion
        let data = try JSONEncoder().encode(sev)
        let decoded = try JSONDecoder().decode(DiffAnnotationSeverity.self, from: data)
        #expect(decoded == .suggestion)
        // Rawvalue is the on-disk form — assert the literal so a
        // future rename trips this test, not just the round-trip.
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw == "\"suggestion\"")
    }

    // MARK: - DiffAnnotation value type

    @Test func diffAnnotationIsIdentifiableWithStableId() {
        let id = UUID()
        let a = DiffAnnotation(id: id,
                               hunkId: UUID(),
                               severity: .nit,
                               body: "trailing whitespace",
                               authoredBy: "agent:senkani")
        #expect(a.id == id)
    }

    // MARK: - groupByHunk

    @Test func groupByHunkSortsBySeverityWeightDesc() {
        let h = makeHunk()
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        let nit = DiffAnnotation(hunkId: h.id, severity: .nit, body: "n", authoredBy: "x", createdAt: older)
        let must = DiffAnnotation(hunkId: h.id, severity: .mustFix, body: "m", authoredBy: "x", createdAt: newer)
        let q = DiffAnnotation(hunkId: h.id, severity: .question, body: "q", authoredBy: "x", createdAt: older)

        let grouped = DiffAnnotationLayout.groupByHunk([nit, must, q], hunks: [h])
        let order = grouped[h.id]?.map(\.severity)
        #expect(order == [.mustFix, .question, .nit])
    }

    @Test func groupByHunkBreaksTiesByCreatedAtAsc() {
        let h = makeHunk()
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        let a = DiffAnnotation(hunkId: h.id, severity: .suggestion, body: "older", authoredBy: "x", createdAt: older)
        let b = DiffAnnotation(hunkId: h.id, severity: .suggestion, body: "newer", authoredBy: "x", createdAt: newer)

        let grouped = DiffAnnotationLayout.groupByHunk([b, a], hunks: [h])
        let bodies = grouped[h.id]?.map(\.body)
        #expect(bodies == ["older", "newer"])
    }

    @Test func groupByHunkDropsAnnotationsWithUnknownHunkId() {
        let h = makeHunk()
        let stray = DiffAnnotation(hunkId: UUID(), severity: .mustFix, body: "stray", authoredBy: "x")
        let valid = DiffAnnotation(hunkId: h.id, severity: .nit, body: "valid", authoredBy: "x")

        let grouped = DiffAnnotationLayout.groupByHunk([stray, valid], hunks: [h])
        #expect(grouped[h.id]?.count == 1)
        #expect(grouped.values.flatMap { $0 }.count == 1)
    }

    // MARK: - sidebarOrder

    @Test func sidebarOrderWalksHunksTopToBottom() {
        let h1 = makeHunk(originalStart: 1, modifiedStart: 1)
        let h2 = makeHunk(originalStart: 50, modifiedStart: 50)
        let a1 = DiffAnnotation(hunkId: h1.id, severity: .nit, body: "first-hunk", authoredBy: "x")
        let a2 = DiffAnnotation(hunkId: h2.id, severity: .mustFix, body: "second-hunk", authoredBy: "x")

        // Pass annotations in reverse to assert order is hunk-driven, not input-driven.
        let ordered = DiffAnnotationLayout.sidebarOrder([a2, a1], hunks: [h1, h2])
        #expect(ordered.map(\.body) == ["first-hunk", "second-hunk"])
    }

    @Test func sidebarOrderEmptyWhenNoMatchingHunks() {
        let h = makeHunk()
        let stray = DiffAnnotation(hunkId: UUID(), severity: .mustFix, body: "stray", authoredBy: "x")
        let ordered = DiffAnnotationLayout.sidebarOrder([stray], hunks: [h])
        #expect(ordered.isEmpty)
    }

    // MARK: - severityCounts

    @Test func severityCountsCoverAllFourTagsEvenWhenEmpty() {
        // Frozen vocab ⇒ every render must show all four counts (even
        // zeros) so the chip row layout stays stable.
        let counts = DiffAnnotationLayout.severityCounts([])
        #expect(counts.count == 4)
        for sev in DiffAnnotationSeverity.allCases {
            #expect(counts[sev] == 0)
        }
    }

    @Test func severityCountsTallyBySeverity() {
        let h = makeHunk()
        let anns = [
            DiffAnnotation(hunkId: h.id, severity: .mustFix, body: "", authoredBy: "x"),
            DiffAnnotation(hunkId: h.id, severity: .mustFix, body: "", authoredBy: "x"),
            DiffAnnotation(hunkId: h.id, severity: .nit, body: "", authoredBy: "x"),
            DiffAnnotation(hunkId: h.id, severity: .question, body: "", authoredBy: "x"),
        ]
        let counts = DiffAnnotationLayout.severityCounts(anns)
        #expect(counts[.mustFix] == 2)
        #expect(counts[.nit] == 1)
        #expect(counts[.question] == 1)
        #expect(counts[.suggestion] == 0)
    }

    // MARK: - Helpers

    private func makeHunk(originalStart: Int = 1, modifiedStart: Int = 1) -> DiffHunk {
        DiffHunk(
            removedLines: ["old"],
            addedLines: ["new"],
            originalStartLine: originalStart,
            modifiedStartLine: modifiedStart
        )
    }
}
