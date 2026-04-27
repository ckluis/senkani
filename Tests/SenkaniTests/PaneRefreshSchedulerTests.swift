import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func fixedFetch(_ outcome: PaneRefreshOutcome)
    -> @Sendable (PaneRefreshContext) async -> PaneRefreshOutcome {
    return { _ in outcome }
}

private actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; if current > peak { peak = current } }
    func exit() { current -= 1 }
}

// MARK: - requiresUpdate

@Suite(.serialized)
struct PaneRefreshSchedulerRequiresUpdateTests {

    @Test func infiniteWithoutContentRequiresUpdate() {
        let scheduler = StatefulPaneRefresher(
            initialState: PaneRefreshState(cacheType: .infinite, contentAvailable: false),
            fetch: fixedFetch(.success))
        #expect(scheduler.requiresUpdate(now: Date()))
    }

    @Test func infiniteWithContentDoesNotRequireUpdate() {
        let scheduler = StatefulPaneRefresher(
            initialState: PaneRefreshState(cacheType: .infinite, contentAvailable: true),
            fetch: fixedFetch(.success))
        #expect(!scheduler.requiresUpdate(now: Date()))
    }

    @Test func durationRequiresUpdateWhenPastNextUpdate() {
        let now = Date()
        let scheduler = StatefulPaneRefresher(
            initialState: PaneRefreshState(
                cacheType: .duration, cacheDuration: 60,
                nextUpdate: now.addingTimeInterval(-1)),
            fetch: fixedFetch(.success))
        #expect(scheduler.requiresUpdate(now: now))
    }

    @Test func durationDoesNotRequireUpdateWhenCacheFresh() {
        let now = Date()
        let scheduler = StatefulPaneRefresher(
            initialState: PaneRefreshState(
                cacheType: .duration, cacheDuration: 60,
                nextUpdate: now.addingTimeInterval(30)),
            fetch: fixedFetch(.success))
        #expect(!scheduler.requiresUpdate(now: now))
    }
}

// MARK: - scheduleNextUpdate

@Suite(.serialized)
struct PaneRefreshSchedulerScheduleNextTests {

    @Test func durationSetsNextUpdateToNowPlusInterval() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = StatefulPaneRefresher(
            initialState: PaneRefreshState(cacheType: .duration, cacheDuration: 120),
            fetch: fixedFetch(.success))
        await scheduler.update(ctx: PaneRefreshContext(now: now))
        #expect(scheduler.state.nextUpdate == now.addingTimeInterval(120))
    }

    @Test func infiniteParksNextUpdateInDistantFuture() async {
        let scheduler = StatefulPaneRefresher(
            initialState: PaneRefreshState(cacheType: .infinite),
            fetch: fixedFetch(.success))
        await scheduler.update(ctx: PaneRefreshContext(now: Date()))
        #expect(scheduler.state.nextUpdate == .distantFuture)
        #expect(!scheduler.requiresUpdate(now: Date()))
    }

    @Test func onTheHourAlignsToNextHourBoundary() async {
        // 12:34:56 local — next hour is 13:00:00.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let now = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 27,
            hour: 12, minute: 34, second: 56))!
        let expected = cal.date(from: DateComponents(
            year: 2026, month: 4, day: 27,
            hour: 13, minute: 0, second: 0))!
        let scheduler = StatefulPaneRefresher(
            initialState: PaneRefreshState(cacheType: .onTheHour),
            fetch: fixedFetch(.success))
        await scheduler.update(ctx: PaneRefreshContext(now: now))
        #expect(scheduler.state.nextUpdate == expected)
    }
}

// MARK: - scheduleEarlyUpdate / squared backoff

@Suite(.serialized)
struct PaneRefreshSchedulerEarlyUpdateTests {

    @Test func backoffIsSquaredMinutes() {
        // 1 → 60s, 2 → 240s, 3 → 540s.
        #expect(PaneRefreshBackoff.nextRetryDelay(retryCount: 1) == 60)
        #expect(PaneRefreshBackoff.nextRetryDelay(retryCount: 2) == 240)
        #expect(PaneRefreshBackoff.nextRetryDelay(retryCount: 3) == 540)
    }

    @Test func backoffCapsAtCeiling() {
        // retry=10 → 6000s, but cap=1800s.
        #expect(PaneRefreshBackoff.nextRetryDelay(retryCount: 10) == 1800)
    }

    @Test func failureSchedulesEarlyRetryCappedByNaturalNextUpdate() async {
        // Duration cache of 30s → natural nextUpdate = now + 30.
        // First failure → squared backoff = 60s. 30 < 60, so the
        // capped early time wins.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = StatefulPaneRefresher(
            initialState: PaneRefreshState(cacheType: .duration, cacheDuration: 30),
            fetch: fixedFetch(.failure(error: "network down")))
        await scheduler.update(ctx: PaneRefreshContext(now: now))
        let snap = scheduler.state
        #expect(snap.retryCount == 1)
        #expect(snap.lastError == "network down")
        #expect(snap.nextUpdate == now.addingTimeInterval(30))
    }

    @Test func failureBackoffWinsWhenSmallerThanNatural() async {
        // Duration cache of 1 hour → natural nextUpdate = now + 3600.
        // First failure → 60s. 60 < 3600, early time wins.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = StatefulPaneRefresher(
            initialState: PaneRefreshState(cacheType: .duration, cacheDuration: 3600),
            fetch: fixedFetch(.failure(error: "timeout")))
        await scheduler.update(ctx: PaneRefreshContext(now: now))
        #expect(scheduler.state.nextUpdate == now.addingTimeInterval(60))
    }
}

// MARK: - outcome handling

@Suite(.serialized)
struct PaneRefreshSchedulerOutcomeTests {

    @Test func successClearsErrorAndNotice() async {
        let now = Date()
        let scheduler = StatefulPaneRefresher(
            initialState: PaneRefreshState(
                cacheType: .duration, cacheDuration: 60,
                retryCount: 3, lastError: "stale", notice: "warming",
                contentAvailable: false),
            fetch: fixedFetch(.success))
        await scheduler.update(ctx: PaneRefreshContext(now: now))
        let snap = scheduler.state
        #expect(snap.retryCount == 0)
        #expect(snap.lastError == nil)
        #expect(snap.notice == nil)
        #expect(snap.contentAvailable)
    }

    @Test func partialPreservesContentAndSurfacesNotice() async {
        let now = Date()
        let scheduler = StatefulPaneRefresher(
            initialState: PaneRefreshState(
                cacheType: .duration, cacheDuration: 60,
                retryCount: 2, lastError: "previous",
                contentAvailable: true),
            fetch: fixedFetch(.partial(notice: "showing cached")))
        await scheduler.update(ctx: PaneRefreshContext(now: now))
        let snap = scheduler.state
        #expect(snap.contentAvailable)        // preserved
        #expect(snap.retryCount == 2)         // not bumped on partial
        #expect(snap.lastError == nil)        // cleared
        #expect(snap.notice == "showing cached")
        #expect(snap.nextUpdate == now.addingTimeInterval(60))
    }

    @Test func failurePreservesPriorContentAvailable() async {
        let now = Date()
        let scheduler = StatefulPaneRefresher(
            initialState: PaneRefreshState(
                cacheType: .duration, cacheDuration: 60,
                contentAvailable: true),
            fetch: fixedFetch(.failure(error: "boom")))
        await scheduler.update(ctx: PaneRefreshContext(now: now))
        let snap = scheduler.state
        #expect(snap.contentAvailable)
        #expect(snap.retryCount == 1)
        #expect(snap.lastError == "boom")
    }
}

// MARK: - PaneRefreshWorkerPool

@Suite(.serialized)
struct PaneRefreshWorkerPoolTests {

    @Test func boundedConcurrencyCapped() async {
        let pool = PaneRefreshWorkerPool(maxConcurrent: 2)
        let tracker = ConcurrencyTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await pool.run {
                        await tracker.enter()
                        try? await Task.sleep(nanoseconds: 25_000_000)
                        await tracker.exit()
                    }
                }
            }
        }
        let peak = await tracker.peak
        #expect(peak <= 2)
        #expect(peak >= 1)
    }

    @Test func saturatedPoolQueuesWaiters() async throws {
        let pool = PaneRefreshWorkerPool(maxConcurrent: 1)
        let started = ConcurrencyTracker()

        async let first: Void = pool.run {
            await started.enter()
            try? await Task.sleep(nanoseconds: 80_000_000)
            await started.exit()
        }
        // Give `first` a moment to acquire the only slot.
        try await Task.sleep(nanoseconds: 15_000_000)
        async let second: Void = pool.run {
            await started.enter()
            await started.exit()
        }
        // Mid-flight: one running, one queued.
        try await Task.sleep(nanoseconds: 15_000_000)
        let inflight = await pool.currentInflight
        let waiting = await pool.pendingWaiters
        #expect(inflight == 1)
        #expect(waiting == 1)

        _ = await (first, second)
        let finalInflight = await pool.currentInflight
        let finalWaiting = await pool.pendingWaiters
        #expect(finalInflight == 0)
        #expect(finalWaiting == 0)
        let peak = await started.peak
        #expect(peak == 1)
    }

    @Test func returnsClosureValue() async {
        let pool = PaneRefreshWorkerPool(maxConcurrent: 3)
        let result = await pool.run { 42 }
        #expect(result == 42)
    }
}
