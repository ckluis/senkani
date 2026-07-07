import Foundation

/// V.3c — Pure-Core, SwiftUI-free refresh coordinator that drives the shipped
/// `PaneMetadataProbes` (via a `PaneMetadataResolver` wired with those probe
/// closures) on two cadences:
///
///  1. **5s port poll.** A `DispatchSourceTimer` (default 5s, the
///     `RetentionScheduler` pattern) whose tick re-ingests every tracked pane's
///     port, branch, and PR. The branch/PR legs on the poll are the *coarse*
///     fallback for anything FSEvents misses; their real cost is bounded by the
///     probes' own 60s PR-TTL cache (no new TTL logic here). A synchronous
///     `tickNow()` seam exercises the poll cycle deterministically in tests with
///     no wall-clock wait (mirrors `RetentionScheduler.tickNow`).
///
///  2. **FSEvents branch refresh.** A per-pane `GitHeadWatcher` on
///     `<workingDirectory>/.git` that, on a `HEAD` / `refs/heads/*` change,
///     re-ingests the branch and (because the branch changed) the PR — the
///     low-latency path between polls.
///
/// ## Ownership: the resolver holds the probes, the coordinator schedules ingest
/// The shipped design wires the real `PaneMetadataProbes` closures into the
/// `PaneMetadataResolver` (`resolver.ingestPort/Branch/PR` route through them —
/// see `PaneMetadataResolver`'s injected-closure seams). This coordinator does
/// NOT hold probes; it schedules `ingest*` calls. `phase-v3d` constructs the
/// resolver with the live probes + this coordinator with live pane fields.
///
/// ## Silent-degrade semantics (operator-visible pick — bullet 7)
/// The probe seam is `(_) -> Int?` / `-> String?` / `-> PRRef?`, which
/// **conflates failure and absence**: `PaneMetadataProbes` returns `nil` both
/// when a probe FAILS (spawn-fail, missing binary) and when it SUCCEEDS with
/// nothing (port closed, detached HEAD, no PR) — its documented contract is
/// "a degraded probe just means 'no chip'." A degraded probe therefore CLEARS
/// only its own field (no-chip), and NEVER touches the other cached fields
/// (`ingest*` merges field-by-field) — so prior branch/PR/agent-status metadata
/// survives a port-probe failure intact, the cache is never corrupted, and the
/// coordinator logs NOTHING on the degrade path. Retaining a stale value would
/// instead surface a phantom chip for a port that has actually closed, which is
/// the worse failure for a best-effort chip. (Adversarial-bar decision
/// 2026-07-05: "stale value retained vs cleared — pick and test": CLEARED.)
///
/// Pure-Core: no `import SwiftUI`, no `SenkaniApp` coupling.
public final class PaneMetadataRefreshCoordinator: @unchecked Sendable {

    /// Injectable branch-watch seam. Production uses `GitHeadWatcher`; tests
    /// inject a fake whose `onChange` they fire synchronously for deterministic
    /// FSEvents-free branch-refresh assertions.
    public typealias BranchWatcherFactory =
        @Sendable (_ gitDir: String, _ onChange: @escaping @Sendable () -> Void) -> BranchChangeWatching

    /// Default 5s poll cadence (parent acceptance bullet 4: "the 5s port poll").
    public static let defaultPollInterval: TimeInterval = 5

    private struct TrackedPane {
        let paneId: String
        let portProbeKey: String
        let workingDirectory: String
        let watcher: BranchChangeWatching
    }

    private let resolver: PaneMetadataResolver
    private let pollInterval: TimeInterval
    private let makeWatcher: BranchWatcherFactory
    private let queue = DispatchQueue(label: "com.senkani.pane-refresh", qos: .utility)

    private let lock = NSLock()
    private var panes: [String: TrackedPane] = [:]
    private var timer: DispatchSourceTimer?
    private var running = false

    /// - Parameters:
    ///   - resolver: the shipped resolver, wired (by the caller) with the real
    ///     port/branch/PR probe closures.
    ///   - pollInterval: port-poll cadence. Defaults to 5s.
    ///   - branchWatcherFactory: seam producing a per-pane branch watcher.
    ///     Defaults to a real `GitHeadWatcher` on the pane's `.git` directory.
    public init(
        resolver: PaneMetadataResolver,
        pollInterval: TimeInterval = PaneMetadataRefreshCoordinator.defaultPollInterval,
        branchWatcherFactory: @escaping BranchWatcherFactory = { gitDir, onChange in
            GitHeadWatcher(gitDir: gitDir, handler: onChange)
        }
    ) {
        self.resolver = resolver
        self.pollInterval = pollInterval
        self.makeWatcher = branchWatcherFactory
    }

    deinit {
        stop()
    }

    // MARK: - Pane tracking

    /// Track a pane. Creates its branch watcher (rooted at
    /// `<workingDirectory>/.git`); if the coordinator is already running, the
    /// watcher starts immediately. Adding a pane does NOT eagerly probe — the
    /// first refresh happens on the next poll tick or the first FS event, so
    /// tests drive refreshes deterministically via `tickNow()` / the injected
    /// watcher's `onChange`.
    ///
    /// Re-adding an existing `paneId` replaces the prior registration (its old
    /// watcher is stopped first) — idempotent from the caller's view.
    public func addPane(paneId: String, portProbeKey: String, workingDirectory: String) {
        let gitDir = workingDirectory + "/.git"
        let watcher = makeWatcher(gitDir) { [weak self] in
            self?.handleBranchChange(paneId: paneId)
        }
        lock.lock()
        let previous = panes[paneId]?.watcher
        let shouldStart = running
        panes[paneId] = TrackedPane(
            paneId: paneId,
            portProbeKey: portProbeKey,
            workingDirectory: workingDirectory,
            watcher: watcher
        )
        lock.unlock()

        previous?.stop()
        if shouldStart { watcher.start() }
    }

    /// Stop and untrack a pane. Its branch watcher tears down and no further
    /// probes fire for it — a poll tick after removal skips it, and a
    /// concurrently in-flight FS callback no-ops because `handleBranchChange`
    /// re-checks membership under the lock.
    public func removePane(paneId: String) {
        lock.lock()
        let watcher = panes.removeValue(forKey: paneId)?.watcher
        lock.unlock()
        // stop() OUTSIDE the lock: GitHeadWatcher.stop() drains its own queue,
        // and an in-flight onChange re-enters handleBranchChange → acquires this
        // lock. Holding it across stop() would deadlock.
        watcher?.stop()
    }

    /// Snapshot of currently-tracked pane IDs (test/observability aid).
    public var trackedPaneIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(panes.keys)
    }

    // MARK: - Lifecycle

    /// Start the port poll + all tracked panes' branch watchers. Idempotent —
    /// starting an already-running coordinator is a no-op. The first poll tick
    /// fires after `pollInterval` (not immediately), so a `start()` in a test
    /// never races a probe against setup.
    public func start() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        let watchers = panes.values.map { $0.watcher }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.tickNow() }
        timer = t
        lock.unlock()

        watchers.forEach { $0.start() }
        t.resume()
    }

    /// Stop the port poll and every branch watcher. Idempotent. No timer is
    /// left suspended-and-released (which would crash) — the timer is always
    /// resumed in `start()` and cancelled here.
    public func stop() {
        lock.lock()
        if !running {
            lock.unlock()
            return
        }
        running = false
        timer?.cancel()
        timer = nil
        let watchers = panes.values.map { $0.watcher }
        lock.unlock()

        watchers.forEach { $0.stop() }
    }

    /// Whether the coordinator is currently running.
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    // MARK: - Refresh drivers

    /// Synchronously run one poll cycle for every tracked pane: re-ingest port,
    /// branch, and PR. The `DispatchSourceTimer` handler calls this every
    /// `pollInterval`; tests call it directly to exercise the poll with no
    /// wall-clock wait (the `RetentionScheduler.tickNow` seam).
    public func tickNow() {
        lock.lock()
        let snapshot = Array(panes.values)
        lock.unlock()
        for pane in snapshot {
            resolver.ingestPort(paneId: pane.paneId, probeKey: pane.portProbeKey)
            refreshBranchAndPR(paneId: pane.paneId, workingDirectory: pane.workingDirectory)
        }
    }

    /// FSEvents branch-change entry point. Re-ingests the branch, then — because
    /// the branch (may have) changed — the PR for the new branch, riding the
    /// probes' 60s PR-TTL cache. No-ops if the pane was removed between the FS
    /// callback and this call (membership re-checked under the lock), so a
    /// removed pane never gets a post-removal probe.
    private func handleBranchChange(paneId: String) {
        lock.lock()
        guard let pane = panes[paneId] else { lock.unlock(); return }
        let wd = pane.workingDirectory
        lock.unlock()
        refreshBranchAndPR(paneId: paneId, workingDirectory: wd)
    }

    /// Ingest branch, then ingest PR keyed by the freshly-resolved branch. When
    /// the branch degrades to nil (probe failure OR detached HEAD), the PR leg
    /// is skipped — there is no branch to key a PR lookup on.
    private func refreshBranchAndPR(paneId: String, workingDirectory: String) {
        resolver.ingestBranch(paneId: paneId, probeKey: workingDirectory)
        if let branch = resolver.metadata(for: paneId)?.branch {
            resolver.ingestPR(paneId: paneId, probeKey: branch)
        }
    }
}

/// Injectable branch-watch abstraction — the seam `PaneMetadataRefreshCoordinator`
/// uses so tests can substitute a fake for the real FSEvents `GitHeadWatcher`.
public protocol BranchChangeWatching: AnyObject {
    func start()
    func stop()
}

extension GitHeadWatcher: BranchChangeWatching {}
