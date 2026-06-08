import Foundation

/// Owns three Dashboard tile refreshers and dispatches sweeps through a
/// bounded `PaneRefreshWorkerPool`. Persists every outcome via
/// `PaneRefreshStateStore` so tile state survives an app restart.
///
/// V.1 round 2 milestone — see `spec/app.md` "Dashboard tile refresh
/// contract" for the host-pattern + the per-tile `cacheDuration` rationale.
///
/// Tile inventory shipped this round:
///   - `budget_burn`        — monthly cost burn ($/month). Cache 30 s.
///   - `validation_queue`   — undelivered validation_results count. Cache 5 s.
///   - `repo_dirty_state`   — repo dirty bool. Cache 10 s.
///
/// FSEvents-driven invalidation for `repo_dirty_state` is deferred to a
/// follow-up round; the 10 s polling cadence is the bridge until then.
public final class PaneRefreshCoordinator: @unchecked Sendable {
    public static let budgetBurnTileId      = "budget_burn"
    public static let validationQueueTileId = "validation_queue"
    public static let repoDirtyStateTileId  = "repo_dirty_state"

    /// Snapshot of every tile's current state — what DashboardView reads.
    public struct Snapshot: Sendable, Equatable {
        public var budgetBurn: PaneRefreshState
        public var validationQueue: PaneRefreshState
        public var repoDirtyState: PaneRefreshState

        public init(
            budgetBurn: PaneRefreshState,
            validationQueue: PaneRefreshState,
            repoDirtyState: PaneRefreshState
        ) {
            self.budgetBurn = budgetBurn
            self.validationQueue = validationQueue
            self.repoDirtyState = repoDirtyState
        }
    }

    public let projectRoot: String
    public let pool: PaneRefreshWorkerPool

    private let database: SessionDatabase
    private let budgetBurn: StatefulPaneRefresher
    private let validationQueue: StatefulPaneRefresher
    private let repoDirtyState: StatefulPaneRefresher

    /// U.9b-2 — loads the default-OFF `WorkBusConfig.dualWrite` flag.
    /// Default reads `~/.senkani/work-bus.json` (missing ⇒ dualWrite=false),
    /// so production is byte-identical to U.9a unless an operator opts in
    /// per project root. Tests inject a loader to force the flag on/off.
    private let workBusConfigLoader: @Sendable () -> WorkBusConfig

    /// Tile ids in declaration order; used for round-trip iteration in tests.
    public let tileIds: [String] = [
        PaneRefreshCoordinator.budgetBurnTileId,
        PaneRefreshCoordinator.validationQueueTileId,
        PaneRefreshCoordinator.repoDirtyStateTileId,
    ]

    public init(
        database: SessionDatabase,
        projectRoot: String,
        budgetBurnFetch: @escaping @Sendable (PaneRefreshContext) async -> PaneRefreshOutcome,
        validationQueueFetch: @escaping @Sendable (PaneRefreshContext) async -> PaneRefreshOutcome,
        repoDirtyStateFetch: @escaping @Sendable (PaneRefreshContext) async -> PaneRefreshOutcome,
        maxConcurrent: Int = 4,
        workBusConfigLoader: @escaping @Sendable () -> WorkBusConfig = { (try? WorkBusConfigStore.load()) ?? WorkBusConfig() }
    ) {
        self.database = database
        self.projectRoot = projectRoot
        self.pool = PaneRefreshWorkerPool(maxConcurrent: maxConcurrent)
        self.workBusConfigLoader = workBusConfigLoader

        self.budgetBurn = StatefulPaneRefresher(
            initialState: PaneRefreshState(cacheType: .duration, cacheDuration: 30),
            fetch: budgetBurnFetch
        )
        self.validationQueue = StatefulPaneRefresher(
            initialState: PaneRefreshState(cacheType: .duration, cacheDuration: 5),
            fetch: validationQueueFetch
        )
        self.repoDirtyState = StatefulPaneRefresher(
            initialState: PaneRefreshState(cacheType: .duration, cacheDuration: 10),
            fetch: repoDirtyStateFetch
        )
    }

    /// Replace each refresher's state from `pane_refresh_state`. Call once
    /// before the first `tick`. No-op for tiles without persisted history.
    public func rehydrate() {
        let states = database.paneRefreshStates(projectRoot: projectRoot)
        if let s = states[Self.budgetBurnTileId] { budgetBurn.replaceState(s) }
        if let s = states[Self.validationQueueTileId] { validationQueue.replaceState(s) }
        if let s = states[Self.repoDirtyStateTileId] { repoDirtyState.replaceState(s) }
        if !states.isEmpty {
            database.recordEvent(
                type: "pane_refresh.rehydrated",
                projectRoot: projectRoot,
                delta: states.count
            )
        }
    }

    /// Sweep all tiles whose `requiresUpdate(now:)` returns true. Each due
    /// tile dispatches through the worker pool; persistence fires after the
    /// outcome lands.
    public func tick(now: Date = Date()) async {
        // U.9b-2 — read the default-OFF dual-write flag ONCE per tick so the
        // off-path adds zero work and the on-path is deterministic across the
        // sweep. NOT re-read per tile.
        let dualWrite = workBusConfigLoader().dualWrite
        await withTaskGroup(of: Void.self) { group in
            for (tileId, refresher) in self.allRefreshers() {
                guard refresher.requiresUpdate(now: now) else { continue }
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.pool.run {
                        await refresher.update(ctx: PaneRefreshContext(now: now))
                        self.database.recordPaneRefreshState(
                            projectRoot: self.projectRoot,
                            tileId: tileId,
                            state: refresher.state
                        )
                        // U.9b-2 — dual-write bus leg (default-OFF). Only runs
                        // when an operator opted in via `WorkBusConfig.dualWrite`.
                        // Runs SYNCHRONOUSLY inside THIS existing withTaskGroup
                        // child task, under the pool's `maxConcurrent` ceiling —
                        // NO second cooperative-pool hop (Carmack no-flake). When
                        // off, this block is never entered and the path is
                        // byte-identical to U.9a (zero bus rows, zero parity
                        // counters). The in-process leg is considered delivered
                        // when the tile has usable content.
                        if dualWrite {
                            PaneRefreshDualWrite.run(
                                db: self.database,
                                projectRoot: self.projectRoot,
                                tileId: tileId,
                                inProcessLegOK: refresher.state.contentAvailable
                            )
                        }
                    }
                }
            }
        }
    }

    /// Current snapshot — DashboardView reads this to render the three tiles.
    public func snapshot() -> Snapshot {
        Snapshot(
            budgetBurn: budgetBurn.state,
            validationQueue: validationQueue.state,
            repoDirtyState: repoDirtyState.state
        )
    }

    /// Tile-id → refresher iteration helper. Internal — kept on the
    /// coordinator so `tick`'s per-tile dispatch matches the snapshot order.
    private func allRefreshers() -> [(String, StatefulPaneRefresher)] {
        [
            (Self.budgetBurnTileId, budgetBurn),
            (Self.validationQueueTileId, validationQueue),
            (Self.repoDirtyStateTileId, repoDirtyState),
        ]
    }
}
