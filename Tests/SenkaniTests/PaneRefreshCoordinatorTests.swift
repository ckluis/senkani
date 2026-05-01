import Testing
import Foundation
@testable import Core

@Suite("PaneRefreshCoordinator — V.1 round 2 wiring + bounded pool")
struct PaneRefreshCoordinatorTests {

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-prc-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func cleanup(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }

    @Test("tick() runs each tile through the pool and persists the outcome")
    func tickPersistsOutcomes() async {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        let coord = PaneRefreshCoordinator(
            database: db,
            projectRoot: "/tmp/proj",
            budgetBurnFetch: { _ in .success },
            validationQueueFetch: { _ in .success },
            repoDirtyStateFetch: { _ in .partial(notice: "git unavailable") }
        )

        await coord.tick(now: Date(timeIntervalSince1970: 1_700_000_000))
        db.flushWrites()

        let snapshot = coord.snapshot()
        #expect(snapshot.budgetBurn.contentAvailable)
        #expect(snapshot.validationQueue.contentAvailable)
        #expect(snapshot.repoDirtyState.notice == "git unavailable")

        // Persistence: every tile got at least one row.
        let states = db.paneRefreshStates(projectRoot: "/tmp/proj")
        #expect(states.count == 3)
    }

    @Test("rehydrate() restores tile state from the DB")
    func rehydrateRestoresState() async {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        // First coordinator runs once to seed persistence.
        let coordA = PaneRefreshCoordinator(
            database: db,
            projectRoot: "/tmp/proj-rehydrate",
            budgetBurnFetch: { _ in .success },
            validationQueueFetch: { _ in .partial(notice: "still warming") },
            repoDirtyStateFetch: { _ in .failure(error: "git not found") }
        )
        await coordA.tick(now: Date(timeIntervalSince1970: 1_700_000_000))
        db.flushWrites()

        // Second coordinator simulates a process restart: same project, fresh
        // refreshers. Without rehydrate(), the initial state is empty.
        let coordB = PaneRefreshCoordinator(
            database: db,
            projectRoot: "/tmp/proj-rehydrate",
            budgetBurnFetch: { _ in .success },
            validationQueueFetch: { _ in .success },
            repoDirtyStateFetch: { _ in .success }
        )
        // Pre-rehydrate: starts blank.
        #expect(coordB.snapshot().budgetBurn.contentAvailable == false)

        coordB.rehydrate()

        let restored = coordB.snapshot()
        #expect(restored.budgetBurn.contentAvailable == true)
        #expect(restored.validationQueue.notice == "still warming")
        #expect(restored.repoDirtyState.lastError == "git not found")
    }

    @Test("Bounded worker pool caps concurrency at maxConcurrent across simultaneous tile wakes")
    func boundedPoolEnforcement() async {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        // 12 simultaneous tile wakes from a single tick are simulated by
        // dispatching 12 fetches through the coordinator's pool directly. The
        // peak concurrency must stay ≤ 4 (the coordinator's default cap).
        let coord = PaneRefreshCoordinator(
            database: db,
            projectRoot: "/tmp/proj-pool",
            budgetBurnFetch: { _ in .success },
            validationQueueFetch: { _ in .success },
            repoDirtyStateFetch: { _ in .success }
        )

        actor Tracker {
            private(set) var peak = 0
            private(set) var current = 0
            func enter() { current += 1; if current > peak { peak = current } }
            func exit() { current -= 1 }
        }
        let tracker = Tracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await coord.pool.run {
                        await tracker.enter()
                        // Yield once so other waiters get a chance to be
                        // dispatched concurrently — exposes any cap leak.
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        await tracker.exit()
                    }
                }
            }
        }

        let peak = await tracker.peak
        #expect(peak <= 4, "expected pool peak ≤ 4, got \(peak)")
        #expect(peak >= 1, "expected pool peak ≥ 1, got \(peak)")
    }

    @Test("Coordinator surfaces failure outcomes through snapshot.lastError")
    func failureOutcomeSurfacesInSnapshot() async {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        let coord = PaneRefreshCoordinator(
            database: db,
            projectRoot: "/tmp/proj-failure",
            budgetBurnFetch: { _ in .failure(error: "rate-limited") },
            validationQueueFetch: { _ in .success },
            repoDirtyStateFetch: { _ in .success }
        )
        await coord.tick(now: Date(timeIntervalSince1970: 1_700_000_000))
        let snap = coord.snapshot()
        #expect(snap.budgetBurn.lastError == "rate-limited")
        #expect(snap.budgetBurn.retryCount == 1)
    }
}
