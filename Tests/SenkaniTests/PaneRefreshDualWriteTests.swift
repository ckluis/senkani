import Testing
import Foundation
@testable import Core

/// U.9b-2 — PaneRefreshCoordinator dual-write onto SessionWorkQueue
/// (feature-flagged, default-OFF). 2 tests per the build plan / parent
/// acceptance bullets 4-5.
///
/// FLAKE-DISCIPLINE (Carmack R7/R8): the dual-write leg runs SYNCHRONOUSLY
/// inside `PaneRefreshCoordinator.tick`'s EXISTING `withTaskGroup` child task
/// under the `PaneRefreshWorkerPool` `maxConcurrent` ceiling — NO second
/// cooperative-pool hop, NO `Task.detached(.utility)`. These tests drive the
/// real coordinator with deterministic fetch closures (no network, no
/// wall-clock dependence beyond the injected `now`), so they are
/// structurally free of the starvation pattern.
@Suite("PaneRefreshCoordinator — U.9b-2 dual-write")
struct PaneRefreshDualWriteTests {

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u9b2-test-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private static func eventCount(_ db: SessionDatabase, _ type: String, projectRoot: String) -> Int {
        db.flushWrites()
        return db.eventCounts(projectRoot: projectRoot)
            .first(where: { $0.eventType == type })?.count ?? 0
    }

    private static func busRowCount(_ db: SessionDatabase, projectRoot: String) -> Int {
        db.flushWrites()
        return db.sessionWorkQueueStore.diagnostics(projectRoot: projectRoot)
            .byKind[PaneRefreshDualWrite.kind] ?? 0
    }

    /// Run a coordinator across a 10-tick fixture. Each tick advances the
    /// clock by 60 s so every tile (5/10/30 s cache) becomes due and refreshes
    /// at least once. Returns the final snapshot for byte-comparison.
    private static func runTenTicks(
        _ coord: PaneRefreshCoordinator,
        start: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async -> PaneRefreshCoordinator.Snapshot {
        for i in 0..<10 {
            await coord.tick(now: start.addingTimeInterval(Double(i) * 60))
        }
        return coord.snapshot()
    }

    // MARK: - Test 1: default-OFF — in-process-only; state matches baseline; zero bus rows; counters untouched

    @Test("dualWrite=false reproduces U.9a exactly: tile state matches in-process-only baseline over a 10-tick fixture; zero pane_refresh bus rows; no parity counters")
    func dualWriteOffIsDefaultSafe() async {
        // Pin the default at the flag itself.
        #expect(WorkBusConfig().dualWrite == false, "WorkBusConfig must default to dualWrite=false")

        // Deterministic fetch outcomes shared by both coordinators so the
        // tile-state trajectories are directly comparable.
        let budgetFetch: @Sendable (PaneRefreshContext) async -> PaneRefreshOutcome = { _ in .success }
        let validationFetch: @Sendable (PaneRefreshContext) async -> PaneRefreshOutcome = { _ in .partial(notice: "warming") }
        let repoFetch: @Sendable (PaneRefreshContext) async -> PaneRefreshOutcome = { _ in .failure(error: "git not found") }

        // Baseline: a coordinator that has NO dual-write capability invoked
        // (default loader ⇒ dualWrite=false). This is the U.9a tile-state path.
        let (dbBase, _) = Self.makeDB()
        let root = "/tmp/senkani-u9b2-off"
        let baseline = PaneRefreshCoordinator(
            database: dbBase, projectRoot: root,
            budgetBurnFetch: budgetFetch,
            validationQueueFetch: validationFetch,
            repoDirtyStateFetch: repoFetch
            // workBusConfigLoader omitted ⇒ default reads disk ⇒ dualWrite=false
        )
        let baselineSnapshot = await Self.runTenTicks(baseline)

        // Explicit dualWrite=false coordinator on a fresh DB. Must produce
        // byte-identical tile state AND write zero bus rows / zero counters.
        let (db, _) = Self.makeDB()
        let coord = PaneRefreshCoordinator(
            database: db, projectRoot: root,
            budgetBurnFetch: budgetFetch,
            validationQueueFetch: validationFetch,
            repoDirtyStateFetch: repoFetch,
            workBusConfigLoader: { WorkBusConfig(dualWrite: false) }
        )
        let offSnapshot = await Self.runTenTicks(coord)

        // Tile state matches the in-process-only baseline byte-for-byte.
        #expect(offSnapshot == baselineSnapshot,
                "dualWrite=false tile state must match the in-process-only baseline over the 10-tick fixture")
        // And the trajectory is sane (each tile reflects its deterministic outcome).
        #expect(offSnapshot.budgetBurn.contentAvailable, "budget tile refreshed (success)")
        #expect(offSnapshot.validationQueue.notice == "warming", "validation tile shows partial notice")
        #expect(offSnapshot.repoDirtyState.lastError == "git not found", "repo tile shows failure")

        // Zero bus rows for pane_refresh; zero parity counters.
        #expect(Self.busRowCount(db, projectRoot: root) == 0,
                "dualWrite=false must write zero session_work_queue rows for pane_refresh")
        for counter in [AutoValidateDualWrite.parityMatch, AutoValidateDualWrite.parityDiverge,
                        AutoValidateDualWrite.parityBusOnly, AutoValidateDualWrite.parityInProcessOnly] {
            #expect(Self.eventCount(db, counter, projectRoot: root) == 0,
                    "dualWrite=false must not emit \(counter)")
        }
    }

    // MARK: - Test 2: dualWrite=true — each refreshed tile enqueues + .parity_match; maxConcurrent ceiling preserved

    @Test("dualWrite=true: each refreshed tile enqueues a pane_refresh bus row + .parity_match; bus dispatch respects the same maxConcurrent ceiling as PaneRefreshWorkerPool")
    func dualWriteOnEnqueuesAndRespectsCeiling() async {
        let (db, _) = Self.makeDB()
        let root = "/tmp/senkani-u9b2-on"

        let coord = PaneRefreshCoordinator(
            database: db, projectRoot: root,
            budgetBurnFetch: { _ in .success },
            validationQueueFetch: { _ in .success },
            repoDirtyStateFetch: { _ in .success },
            workBusConfigLoader: { WorkBusConfig(dualWrite: true) }
        )

        // Single tick from .distantPast-equivalent: all 3 tiles are due and
        // refresh successfully (contentAvailable ⇒ inProcessLegOK == true).
        await coord.tick(now: Date(timeIntervalSince1970: 1_700_000_000))

        // Each refreshed tile enqueued exactly one pane_refresh bus row.
        #expect(Self.busRowCount(db, projectRoot: root) == 3,
                "dualWrite=true must enqueue one pane_refresh bus row per refreshed tile (3 tiles)")
        // Both legs OK for every tile ⇒ exactly 3 .parity_match, nothing else.
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityMatch, projectRoot: root) == 3,
                "every refreshed tile with both legs OK must emit one .parity_match")
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityDiverge, projectRoot: root) == 0)
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityBusOnly, projectRoot: root) == 0)
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityInProcessOnly, projectRoot: root) == 0)

        // maxConcurrent ceiling preserved: the dual-write leg runs INSIDE the
        // pool's `run {}` block, so it cannot exceed the pool's cap. Verify the
        // pool's cap directly + that saturating it never breaches the ceiling.
        let ceiling = await coord.pool.maxConcurrent
        #expect(ceiling == 4, "default PaneRefreshWorkerPool ceiling is 4")

        actor Tracker {
            private(set) var peak = 0
            private(set) var current = 0
            func enter() { current += 1; if current > peak { peak = current } }
            func exit() { current -= 1 }
        }
        let tracker = Tracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await coord.pool.run {
                        await tracker.enter()
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        await tracker.exit()
                    }
                }
            }
        }
        let peak = await tracker.peak
        #expect(peak <= ceiling,
                "bus dispatch through the pool must never exceed maxConcurrent (\(ceiling)); got peak \(peak)")
        #expect(peak >= 1, "pool must admit at least one worker")
    }
}
