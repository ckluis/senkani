import Testing
import Foundation
@testable import Core

@Suite("PaneRefreshTileDisplay — V.1 round 3 notice surface + a11y")
struct PaneRefreshTileDisplayTests {

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-prtd-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func cleanup(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }

    @Test("Normal state — no notice strip, no error strip, tile reads value text via a11y")
    func normalStateNoStrips() {
        let state = PaneRefreshState(
            cacheType: .duration,
            cacheDuration: 30,
            nextUpdate: .distantFuture,
            retryCount: 0,
            lastError: nil,
            notice: nil,
            contentAvailable: true
        )
        let d = PaneRefreshTileDisplay(tileTitle: "Budget Burn", state: state, valueText: "30s cache")

        #expect(d.tone == .normal)
        #expect(d.hasNoticeStrip == false)
        #expect(d.hasErrorStrip == false)
        #expect(d.iconSystemName == nil)
        #expect(d.accessibilityLabel == "Budget Burn, 30s cache")
    }

    @Test("Notice state — warning tone, triangle icon, a11y label includes 'partial:'")
    func noticeStateRendersWarningStrip() {
        let state = PaneRefreshState(
            cacheType: .duration,
            cacheDuration: 30,
            nextUpdate: .distantFuture,
            retryCount: 0,
            lastError: nil,
            notice: "no spend yet",
            contentAvailable: true
        )
        let d = PaneRefreshTileDisplay(tileTitle: "Budget Burn", state: state, valueText: "30s cache")

        #expect(d.tone == .warning)
        #expect(d.hasNoticeStrip == true)
        #expect(d.hasErrorStrip == false)
        #expect(d.noticeText == "no spend yet")
        #expect(d.iconSystemName == "exclamationmark.triangle.fill")
        #expect(d.accessibilityLabel == "Budget Burn, partial: no spend yet")
    }

    @Test("Error state — error tone, octagon icon, distinct from warning, a11y reads 'error:'")
    func errorStateRendersErrorStripDistinctFromNotice() {
        let state = PaneRefreshState(
            cacheType: .duration,
            cacheDuration: 30,
            nextUpdate: .distantFuture,
            retryCount: 1,
            lastError: "rate-limited",
            notice: nil,
            contentAvailable: false
        )
        let d = PaneRefreshTileDisplay(tileTitle: "Validation Queue", state: state, valueText: "warming")

        #expect(d.tone == .error)
        #expect(d.hasErrorStrip == true)
        #expect(d.hasNoticeStrip == false)
        #expect(d.errorText == "rate-limited")
        #expect(d.iconSystemName == "exclamationmark.octagon.fill")
        #expect(d.accessibilityLabel == "Validation Queue, error: rate-limited")
    }

    @Test("Error precedence — when both lastError and notice are set, error wins so the UI never shows both strips")
    func errorPrecedenceOverNotice() {
        // Defensive case: the scheduler clears notice on success and clears
        // lastError on partial, so this combo shouldn't normally exist. But
        // if a future code path sets both, error must win — Norman's "single
        // dominant signal per tile" rule.
        let state = PaneRefreshState(
            cacheType: .duration,
            cacheDuration: 30,
            nextUpdate: .distantFuture,
            retryCount: 1,
            lastError: "fixture failure",
            notice: "stale",
            contentAvailable: false
        )
        let d = PaneRefreshTileDisplay(tileTitle: "Repo Dirty", state: state, valueText: "10s cache")

        #expect(d.tone == .error)
        #expect(d.hasErrorStrip == true)
        #expect(d.hasNoticeStrip == false)
        #expect(d.noticeText == nil)
    }

    @Test("Warming a11y — tile with no content available reads 'warming'")
    func warmingStateA11yReadsWarming() {
        let state = PaneRefreshState(
            cacheType: .duration,
            cacheDuration: 5,
            nextUpdate: .distantPast,
            retryCount: 0,
            lastError: nil,
            notice: nil,
            contentAvailable: false
        )
        let d = PaneRefreshTileDisplay(tileTitle: "Validation Queue", state: state, valueText: "warming")

        #expect(d.tone == .normal)
        #expect(d.accessibilityLabel == "Validation Queue, warming")
    }

    @Test("Fixture fetch — fails twice, then yields partial(notice:) on the third call (round-trip through coordinator + worker pool)")
    func fixtureFailureYieldsNoticeOnThirdCall() async {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        let fixtureFetch = paneRefreshFixtureFetch(
            failuresBeforePartial: 2,
            notice: "upstream degraded",
            failureMessage: "fixture failure"
        )

        let coord = PaneRefreshCoordinator(
            database: db,
            projectRoot: "/tmp/proj-fixture",
            budgetBurnFetch: fixtureFetch,
            validationQueueFetch: { _ in .success },
            repoDirtyStateFetch: { _ in .success }
        )

        // Drive the budget-burn tile through 3 ticks. Each tick advances `now`
        // past the cache boundary so the tile is due again. Use a 60-second
        // tile cache (the default) and step in 120-second hops.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        await coord.tick(now: t0)
        let s1 = coord.snapshot()
        #expect(s1.budgetBurn.lastError == "fixture failure")
        #expect(s1.budgetBurn.notice == nil)
        #expect(s1.budgetBurn.retryCount == 1)

        // Second tick — still failing.
        await coord.tick(now: t0.addingTimeInterval(7200))
        let s2 = coord.snapshot()
        #expect(s2.budgetBurn.lastError == "fixture failure")
        #expect(s2.budgetBurn.retryCount == 2)
        #expect(s2.budgetBurn.notice == nil)

        // Third tick — fixture flips to partial, notice surfaces, lastError
        // clears, retryCount stays put (partial doesn't bump it).
        await coord.tick(now: t0.addingTimeInterval(14400))
        let s3 = coord.snapshot()
        #expect(s3.budgetBurn.notice == "upstream degraded")
        #expect(s3.budgetBurn.lastError == nil)

        // Display projection over the round-tripped state — UI strip would
        // render the warning chrome with a11y label including the notice.
        let display = PaneRefreshTileDisplay(
            tileTitle: "Budget Burn",
            state: s3.budgetBurn,
            valueText: "30s cache"
        )
        #expect(display.tone == .warning)
        #expect(display.hasNoticeStrip == true)
        #expect(display.accessibilityLabel == "Budget Burn, partial: upstream degraded")
    }
}
