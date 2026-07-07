import Testing
import Foundation
@testable import Core

// MARK: - Test helpers

/// Thread-safe recorder of the probe keys a fixture probe was called with —
/// lets a test assert both invocation COUNT and which pane keys were probed.
private final class KeyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []
    func record(_ k: String) { lock.lock(); keys.append(k); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return keys.count }
    func count(of k: String) -> Int { lock.lock(); defer { lock.unlock() }; return keys.filter { $0 == k }.count }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return keys }
}

/// Deterministic stand-in for `GitHeadWatcher` — the test fires `onChange`
/// synchronously, so branch-refresh wiring is exercised with no FSEvents.
private final class FakeBranchWatcher: BranchChangeWatching, @unchecked Sendable {
    let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var _started = false
    private var _stopped = false
    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func start() { lock.lock(); _started = true; lock.unlock() }
    func stop() { lock.lock(); _stopped = true; lock.unlock() }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }
}

/// Captures the fake watcher created for each `.git` dir so a test can start,
/// inspect, and fire it.
private final class FakeWatcherRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var watchers: [String: FakeBranchWatcher] = [:]
    func factory() -> PaneMetadataRefreshCoordinator.BranchWatcherFactory {
        return { [self] gitDir, onChange in
            let w = FakeBranchWatcher(onChange: onChange)
            lock.lock(); watchers[gitDir] = w; lock.unlock()
            return w
        }
    }
    func watcher(gitDir: String) -> FakeBranchWatcher? {
        lock.lock(); defer { lock.unlock() }; return watchers[gitDir]
    }
    func fire(gitDir: String) { watcher(gitDir: gitDir)?.onChange() }
}

/// Thread-safe log-event name collector for the silent-degrade sink assertion.
private final class NameBag: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

/// Wait up to `timeout` for `condition`. Generous default rides out non-FSEvents
/// peer-suite CPU pressure under the parallel runner (mirrors FileWatcherTests).
private func waitFor(timeout: TimeInterval = 8.0, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}

// MARK: - Core coordinator behavior (FSEvents-free, deterministic)

@Suite("V.3c — PaneMetadataRefreshCoordinator")
struct PaneMetadataRefreshCoordinatorTests {

    /// Bullet 2 — 5s port poll: the synchronous `tickNow()` seam ingests the
    /// probed port with no wall-clock wait.
    @Test("tickNow ingests the probed port into the resolver cache (no wall-clock wait)")
    func portPollTickLandsSynchronously() {
        let portRec = KeyRecorder()
        let resolver = PaneMetadataResolver(
            portProbe: { key in portRec.record(key); return 8080 },
            branchProbe: { _ in nil },
            prProbe: { _ in nil }
        )
        let coord = PaneMetadataRefreshCoordinator(
            resolver: resolver, pollInterval: 5,
            branchWatcherFactory: { _, onChange in FakeBranchWatcher(onChange: onChange) }
        )
        coord.addPane(paneId: "p1", portProbeKey: "4242", workingDirectory: "/tmp/v3c-wd1")

        coord.tickNow()

        #expect(portRec.count(of: "4242") == 1)
        #expect(resolver.metadata(for: "p1")?.port == 8080)
    }

    /// Bullet 4 — PR refresh triggers exactly one `prProbe` on a branch-change,
    /// keyed by the freshly-resolved branch, and the ref lands.
    @Test("A branch-change triggers exactly one prProbe and lands the PR ref")
    func branchChangeTriggersSinglePRProbe() {
        let prRec = KeyRecorder()
        let resolver = PaneMetadataResolver(
            portProbe: { _ in nil },
            branchProbe: { _ in "feature-x" },
            prProbe: { branch in prRec.record(branch); return PaneMetadata.PRRef(number: 7, url: "https://x/pull/7") }
        )
        let registry = FakeWatcherRegistry()
        let coord = PaneMetadataRefreshCoordinator(
            resolver: resolver, pollInterval: 5, branchWatcherFactory: registry.factory()
        )
        coord.addPane(paneId: "p1", portProbeKey: "1", workingDirectory: "/tmp/v3c-wd1")

        // Only a branch-change event — no poll tick.
        registry.fire(gitDir: "/tmp/v3c-wd1/.git")

        #expect(prRec.snapshot == ["feature-x"], "PR probed exactly once, keyed by the new branch")
        #expect(resolver.metadata(for: "p1")?.branch == "feature-x")
        #expect(resolver.metadata(for: "p1")?.prRef == PaneMetadata.PRRef(number: 7, url: "https://x/pull/7"))
    }

    /// Bullet 5 — pane add/remove: both tracked panes poll; removing one stops
    /// its watcher and halts its probes (no probe calls after removal).
    @Test("Removing a pane stops its watcher and halts its probes")
    func removePaneStopsDriversAndProbes() {
        let portRec = KeyRecorder()
        let resolver = PaneMetadataResolver(
            portProbe: { key in portRec.record(key); return 3000 },
            branchProbe: { _ in nil }, prProbe: { _ in nil }
        )
        let registry = FakeWatcherRegistry()
        let coord = PaneMetadataRefreshCoordinator(
            resolver: resolver, pollInterval: 5, branchWatcherFactory: registry.factory()
        )
        coord.start()
        defer { coord.stop() }
        coord.addPane(paneId: "a", portProbeKey: "aa", workingDirectory: "/tmp/v3c-a")
        coord.addPane(paneId: "b", portProbeKey: "bb", workingDirectory: "/tmp/v3c-b")
        #expect(registry.watcher(gitDir: "/tmp/v3c-a/.git")?.started == true)
        #expect(registry.watcher(gitDir: "/tmp/v3c-b/.git")?.started == true)

        coord.tickNow()
        #expect(portRec.count(of: "aa") == 1)
        #expect(portRec.count(of: "bb") == 1)

        coord.removePane(paneId: "a")
        #expect(registry.watcher(gitDir: "/tmp/v3c-a/.git")?.stopped == true, "removed pane's watcher tears down")
        #expect(coord.trackedPaneIDs == ["b"])

        coord.tickNow()
        #expect(portRec.count(of: "aa") == 1, "removed pane must not be probed after removal")
        #expect(portRec.count(of: "bb") == 2)
    }

    /// Bullet 6 — headless data-assembly latency stand-in for the GUI render
    /// timer: a resolver cache read + hover view-model struct assembly stays far
    /// under a generous budget at p95 (no CI flake).
    @Test("Hover data-assembly (cache read + view-model build) is well under budget at p95")
    func hoverAssemblyLatencyP95() {
        let resolver = PaneMetadataResolver(
            portProbe: { _ in 8080 },
            branchProbe: { _ in "feature/x" },
            prProbe: { _ in PaneMetadata.PRRef(number: 42, url: "https://x/pull/42") }
        )
        resolver.ingestPort(paneId: "p", probeKey: "k")
        resolver.ingestBranch(paneId: "p", probeKey: "k")
        resolver.ingestPR(paneId: "p", probeKey: "k")
        resolver.updateAgentStatus(paneId: "p", currentTool: "Edit", lastReplySummary: "did a thing")

        // Warm up (first calls pay one-time allocation costs).
        for _ in 0..<200 { _ = PaneHoverViewModel.build(from: resolver, paneId: "p") }

        let iterations = 2000
        var durations: [Double] = []
        durations.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            let vm = PaneHoverViewModel.build(from: resolver, paneId: "p")
            let end = DispatchTime.now().uptimeNanoseconds
            precondition(vm != nil)
            durations.append(Double(end &- start) / 1_000_000.0) // ms
        }
        durations.sort()
        let p95 = durations[Int(Double(iterations) * 0.95)]
        // The data path is microseconds; a 10ms p95 bound absorbs CI scheduler
        // jitter by ~1000x and cannot flake, while still proving the popover's
        // data assembly is nowhere near the parent's 100ms render budget.
        #expect(p95 < 10.0, "hover data-assembly p95 was \(p95)ms")

        // Correctness of the assembled labels.
        let vm = PaneHoverViewModel.build(from: resolver, paneId: "p")
        #expect(vm?.portLabel == "localhost:8080")
        #expect(vm?.branchLabel == "feature/x")
        #expect(vm?.prLabel == "#42")
        #expect(vm?.prURL == "https://x/pull/42")
        #expect(vm?.currentTool == "Edit")
    }

    /// Adversarial — start()/stop() idempotence and no timer leak. The
    /// start→stop→start cycle would crash if a `DispatchSourceTimer` were ever
    /// left suspended-and-released; reaching the end proves it isn't.
    @Test("start()/stop() are idempotent and leak no timer")
    func startStopIdempotent() {
        let resolver = PaneMetadataResolver()
        let registry = FakeWatcherRegistry()
        let coord = PaneMetadataRefreshCoordinator(
            resolver: resolver, pollInterval: 5, branchWatcherFactory: registry.factory()
        )
        coord.addPane(paneId: "a", portProbeKey: "aa", workingDirectory: "/tmp/v3c-a")
        #expect(!coord.isRunning)

        coord.start()
        coord.start() // second start is a no-op
        #expect(coord.isRunning)
        #expect(registry.watcher(gitDir: "/tmp/v3c-a/.git")?.started == true)

        coord.stop()
        coord.stop()  // second stop is a no-op
        #expect(!coord.isRunning)
        #expect(registry.watcher(gitDir: "/tmp/v3c-a/.git")?.stopped == true)

        // Restart after stop — a fresh timer, no crash.
        coord.start()
        #expect(coord.isRunning)
        coord.stop()
    }

    /// Adversarial — deinit tears the coordinator's watchers down even if the
    /// owner never called stop() (no watcher/timer leak on drop).
    @Test("deinit stops the coordinator's watchers")
    func deinitStopsWatchers() {
        let resolver = PaneMetadataResolver()
        let registry = FakeWatcherRegistry()
        do {
            let coord = PaneMetadataRefreshCoordinator(
                resolver: resolver, pollInterval: 5, branchWatcherFactory: registry.factory()
            )
            coord.addPane(paneId: "a", portProbeKey: "aa", workingDirectory: "/tmp/v3c-a")
            coord.start()
            #expect(registry.watcher(gitDir: "/tmp/v3c-a/.git")?.started == true)
            // coord drops at scope end → deinit → stop().
        }
        #expect(registry.watcher(gitDir: "/tmp/v3c-a/.git")?.stopped == true, "deinit must stop watchers")
    }
}

// MARK: - Silent degrade (Logger sink) — gated

@Suite("V.3c — PaneMetadataRefreshCoordinator silent degrade", .serialized, .loggerSinkGate)
struct PaneMetadataRefreshCoordinatorSilentDegradeTests {

    /// Bullet 7 — a failing/absent probe (spawn-fail, missing binary → nil)
    /// leaves the OTHER cached fields intact, corrupts nothing, and logs
    /// nothing on the degrade path.
    @Test("A degraded probe preserves other cached fields, no corruption, no log")
    func silentDegradePreservesOtherFields() {
        let resolver = PaneMetadataResolver(
            portProbe: { _ in nil },        // spawn-fail / missing binary → nil
            branchProbe: { _ in "main" },
            prProbe: { _ in nil }
        )
        // Seed prior good agent-status metadata.
        resolver.updateAgentStatus(paneId: "p", currentTool: "Edit", lastReplySummary: "did a thing")

        let bag = NameBag()
        Logger._setTestSink { name, _ in
            // Scope to our own vocabulary — peer suites emit production events
            // into this process-global sink under the parallel runner.
            if name.hasPrefix("pane_meta_refresh") { bag.add(name) }
        }
        defer { Logger._setTestSink(nil) }

        let coord = PaneMetadataRefreshCoordinator(
            resolver: resolver, pollInterval: 5,
            branchWatcherFactory: { _, onChange in FakeBranchWatcher(onChange: onChange) }
        )
        coord.addPane(paneId: "p", portProbeKey: "999", workingDirectory: "/tmp/v3c-wd")

        coord.tickNow() // port probe degrades to nil

        let m = resolver.metadata(for: "p")
        #expect(m != nil, "no cache corruption — the row survives")
        #expect(m?.currentTool == "Edit", "prior agent metadata intact after a port-probe failure")
        #expect(m?.lastReplySummary == "did a thing")
        #expect(m?.branch == "main", "branch leg unaffected by the port-probe failure")
        #expect(m?.port == nil, "degraded port = no chip (documented silent-degrade pick)")
        #expect(bag.all.isEmpty, "coordinator must emit no log on the degrade path; got \(bag.all)")
    }
}

// MARK: - FSEvents branch refresh (real FSEvents) — gated

@Suite("V.3c — PaneMetadataRefreshCoordinator FSEvents branch refresh", .serialized, .fsEventsGate)
struct PaneMetadataRefreshCoordinatorFSEventsTests {

    /// Bullet 3 — a real `HEAD` change under `.git` refreshes the branch in the
    /// resolver via the FSEvents-driven `GitHeadWatcher`. Uses the real git
    /// probe + a real temp git repo, gated by `.fsEventsGate` (per-process
    /// FSEvents kernel-resource serialization, mirroring FileWatcherTests).
    @Test("A real HEAD change under .git refreshes the branch through FSEvents")
    func headChangeRefreshesBranch() throws {
        let repo = NSTemporaryDirectory() + "senkani-v3c-fsevents-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let runner = SystemProcessRunner()
        func git(_ args: [String]) {
            _ = runner.run(executable: "/usr/bin/git", args: ["-C", repo] + args)
        }
        git(["init", "-q"])
        git(["config", "user.email", "t@example.com"])
        git(["config", "user.name", "t"])
        git(["commit", "-q", "--allow-empty", "-m", "init"]) // HEAD → main

        let probes = PaneMetadataProbes(runner: runner)
        let resolver = PaneMetadataResolver(branchProbe: probes.branchProbe)
        // Large poll cadence so ONLY FSEvents can drive the branch change within
        // the wait window — this proves the FSEvents path, not the port poll.
        let coord = PaneMetadataRefreshCoordinator(resolver: resolver, pollInterval: 3600)
        coord.addPane(paneId: "p", portProbeKey: "0", workingDirectory: repo)
        coord.start()
        defer { coord.stop() }

        // Seed the initial branch synchronously (start() defers its first tick).
        coord.tickNow()
        #expect(resolver.metadata(for: "p")?.branch == "main")

        // Let FSEvents finish registering, then switch branches.
        Thread.sleep(forTimeInterval: 0.2)
        git(["checkout", "-q", "-b", "feature-v3c"]) // rewrites .git/HEAD

        let refreshed = waitFor(timeout: 8.0) {
            resolver.metadata(for: "p")?.branch == "feature-v3c"
        }
        #expect(refreshed,
                "FSEvents HEAD change should refresh the branch; got \(String(describing: resolver.metadata(for: "p")?.branch))")
    }
}
