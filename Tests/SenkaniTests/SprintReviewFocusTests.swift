import Testing
import Foundation
@testable import Core

// V.9b-1 follow-up — SprintReviewFocusRequest + SprintReviewFocusResolver tests.
//
// 6 tests across 2 suites covering:
//   - request(rowId:) sets target + bumps mutationStamp
//   - request(rowId:) is idempotent at the value level but always
//     bumps the stamp so repeated requests still drive scroll
//   - consume() clears targetRowId
//   - resolver returns the row id when the target matches an existing row
//   - resolver returns nil when the target doesn't match (silent no-op)
//   - resolver late-bind: target set before snapshot returns nil; same target
//     after snapshot loaded returns the match
//   - resolver matches staleness flag ids alongside section row ids

private func fixedDate() -> Date { Date(timeIntervalSince1970: 1_716_000_000) }

private func snapshot(withRowIds ids: [String]) -> SprintReviewSnapshot {
    let rows = ids.map { id in
        SprintReviewRow(
            id: id,
            kind: .filterRule,
            title: id,
            subtitle: "",
            recurrenceCount: 1,
            confidence: 0.5,
            lastSeenAt: fixedDate()
        )
    }
    return SprintReviewSnapshot(
        sections: rows.isEmpty ? [] : [SprintReviewSection(kind: .filterRule, rows: rows)],
        stalenessFlags: [],
        windowDays: 30
    )
}

// MARK: - SprintReviewFocusRequest

@MainActor
@Suite("V.9b-1 follow-up SprintReviewFocusRequest")
struct SprintReviewFocusRequestTests {

    @Test("request(rowId:) sets target and increments mutationStamp")
    func requestSetsTargetAndStamp() {
        let req = SprintReviewFocusRequest()
        let stampBefore = req.mutationStamp
        req.request(rowId: "row-7")
        #expect(req.targetRowId == "row-7")
        #expect(req.mutationStamp == stampBefore &+ 1)
    }

    @Test("request(rowId:) idempotent re-issue still bumps the stamp")
    func requestIdempotentBumpsStamp() {
        let req = SprintReviewFocusRequest()
        req.request(rowId: "x")
        let stamp1 = req.mutationStamp
        req.request(rowId: "x")
        #expect(req.targetRowId == "x")
        #expect(req.mutationStamp == stamp1 &+ 1)
    }

    @Test("consume() clears targetRowId without changing stamp")
    func consumeClearsTarget() {
        let req = SprintReviewFocusRequest(targetRowId: "abc")
        let stampBefore = req.mutationStamp
        req.consume()
        #expect(req.targetRowId == nil)
        #expect(req.mutationStamp == stampBefore)
    }
}

// MARK: - SprintReviewFocusResolver

@Suite("V.9b-1 follow-up SprintReviewFocusResolver")
struct SprintReviewFocusResolverTests {

    @Test("target matching an existing row returns the row id")
    func matchExistingRow() {
        let snap = snapshot(withRowIds: ["a", "b", "c"])
        #expect(SprintReviewFocusResolver.matchedRow(target: "b", snapshot: snap) == "b")
    }

    @Test("target with no matching row returns nil (silent no-op)")
    func noMatchReturnsNil() {
        let snap = snapshot(withRowIds: ["a", "b", "c"])
        #expect(SprintReviewFocusResolver.matchedRow(target: "z", snapshot: snap) == nil)
    }

    @Test("nil target returns nil")
    func nilTargetReturnsNil() {
        let snap = snapshot(withRowIds: ["a", "b"])
        #expect(SprintReviewFocusResolver.matchedRow(target: nil, snapshot: snap) == nil)
    }

    @Test("late-bind: target precedes snapshot — nil first, match after snapshot loads")
    func lateBindSequence() {
        let target = "row-late"
        // First pass: target set, snapshot empty (pane just opened).
        let empty = snapshot(withRowIds: [])
        #expect(SprintReviewFocusResolver.matchedRow(target: target, snapshot: empty) == nil)
        // Second pass: snapshot now contains the target row; same
        // target resolves. This is the late-bind contract — the pane
        // calls the resolver on both mutationStamp change AND snapshot
        // change, so whichever fires later catches the match.
        let loaded = snapshot(withRowIds: [target])
        #expect(SprintReviewFocusResolver.matchedRow(target: target, snapshot: loaded) == target)
    }

    @Test("staleness flag id matches alongside section row ids")
    func stalenessFlagMatches() {
        let snap = SprintReviewSnapshot(
            sections: [],
            stalenessFlags: [
                SprintReviewStalenessFlag(
                    artifactId: "stale-1",
                    kind: .filterRule,
                    idleDays: 100,
                    note: "idle for 100 days"
                )
            ],
            windowDays: 30
        )
        #expect(SprintReviewFocusResolver.matchedRow(target: "stale-1", snapshot: snap) == "stale-1")
    }
}
