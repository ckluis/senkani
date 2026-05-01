import Foundation

// MARK: - PaneCacheType

/// How a tile decides when its data goes stale. Modeled on Glance's
/// `cacheType`: a tile either never refreshes (`infinite`), refreshes
/// after a fixed interval (`duration`), or aligns to the next hour
/// boundary (`onTheHour`).
public enum PaneCacheType: String, Sendable, Codable, CaseIterable {
    case infinite
    case duration
    case onTheHour
}

// MARK: - PaneRefreshState

/// Per-tile refresh state. Required fields per Glance's `widgetBase`:
/// `cacheType`, `cacheDuration`, `nextUpdate`, `retryCount`, `lastError`,
/// `notice`, `contentAvailable`. Persisting this struct (round 2) gives
/// every tile a tamper-evident, hash-chained schedule row.
public struct PaneRefreshState: Sendable, Equatable {
    public var cacheType: PaneCacheType
    public var cacheDuration: TimeInterval
    public var nextUpdate: Date
    public var retryCount: Int
    public var lastError: String?
    public var notice: String?
    public var contentAvailable: Bool

    public init(
        cacheType: PaneCacheType = .duration,
        cacheDuration: TimeInterval = 60,
        nextUpdate: Date = .distantPast,
        retryCount: Int = 0,
        lastError: String? = nil,
        notice: String? = nil,
        contentAvailable: Bool = false
    ) {
        self.cacheType = cacheType
        self.cacheDuration = cacheDuration
        self.nextUpdate = nextUpdate
        self.retryCount = retryCount
        self.lastError = lastError
        self.notice = notice
        self.contentAvailable = contentAvailable
    }
}

// MARK: - PaneRefreshContext

public struct PaneRefreshContext: Sendable {
    public let now: Date
    public init(now: Date = Date()) { self.now = now }
}

// MARK: - PaneRefreshOutcome

/// What an `update(ctx:)` call yielded. `partial` preserves the prior
/// `contentAvailable` flag and surfaces `notice` to the UI; the tile
/// keeps showing stale-but-usable content. `failure` flips the tile
/// into retry-backoff mode without clearing `contentAvailable`.
public enum PaneRefreshOutcome: Sendable, Equatable {
    case success
    case partial(notice: String)
    case failure(error: String)
}

// MARK: - PaneRefreshBackoff

/// Squared retry backoff: 1, 4, 9, 16, 25 minutes... Capped at
/// `cap` seconds. Glance's `widgetBase.scheduleEarlyUpdate` uses the
/// same shape, capped by the natural `nextUpdate` rather than a fixed
/// ceiling — `StatefulPaneRefresher.scheduleEarlyUpdate` enforces both.
public enum PaneRefreshBackoff {
    public static let defaultCapSeconds: TimeInterval = 1800

    public static func nextRetryDelay(
        retryCount: Int,
        cap: TimeInterval = defaultCapSeconds
    ) -> TimeInterval {
        let n = max(1, retryCount)
        let seconds = Double(n * n) * 60
        return min(seconds, cap)
    }
}

// MARK: - PaneRefreshScheduler

/// Per-tile refresh contract borrowed from Glance's widget scheduler.
/// Dashboard / Analytics / Sidebar / monitoring tiles conform; the
/// host (DashboardView, MetricsStore, ...) calls `requiresUpdate(now:)`
/// on a tick and dispatches `update(ctx:)` through a bounded worker
/// pool when it returns true.
public protocol PaneRefreshScheduler: AnyObject, Sendable {
    /// Snapshot of the current refresh state. Implementations must
    /// return a value-type copy under whatever lock they use.
    var state: PaneRefreshState { get }

    /// True iff the tile should be refreshed now.
    func requiresUpdate(now: Date) -> Bool

    /// Perform the refresh. Implementations transition `state`
    /// according to the outcome and call `scheduleNextUpdate` /
    /// `scheduleEarlyUpdate` as appropriate.
    func update(ctx: PaneRefreshContext) async

    /// Set `nextUpdate` to the natural next boundary for the
    /// current `cacheType`. Called after `success` and `partial`.
    func scheduleNextUpdate(now: Date)

    /// Set `nextUpdate` to a retry-backoff time (capped by the
    /// natural next boundary). Called after `failure`.
    func scheduleEarlyUpdate(now: Date)
}

// MARK: - StatefulPaneRefresher

/// Reference implementation of `PaneRefreshScheduler`. Concrete tiles
/// either embed this and forward, or compose a fetch closure into it
/// directly. Thread-safe — all `state` mutations go through `lock`.
public final class StatefulPaneRefresher: PaneRefreshScheduler, @unchecked Sendable {
    public typealias Fetch = @Sendable (PaneRefreshContext) async -> PaneRefreshOutcome

    private let lock = NSLock()
    private var _state: PaneRefreshState
    private let fetch: Fetch
    private let retryCap: TimeInterval

    public init(
        initialState: PaneRefreshState,
        retryCap: TimeInterval = PaneRefreshBackoff.defaultCapSeconds,
        fetch: @escaping Fetch
    ) {
        self._state = initialState
        self.retryCap = retryCap
        self.fetch = fetch
    }

    public var state: PaneRefreshState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public func requiresUpdate(now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch _state.cacheType {
        case .infinite:
            return !_state.contentAvailable
        case .duration, .onTheHour:
            return now >= _state.nextUpdate
        }
    }

    public func update(ctx: PaneRefreshContext) async {
        let outcome = await fetch(ctx)
        applyOutcome(outcome, now: ctx.now)
    }

    public func scheduleNextUpdate(now: Date) {
        lock.lock(); defer { lock.unlock() }
        _state.nextUpdate = naturalNextUpdate(now: now, state: _state)
    }

    public func scheduleEarlyUpdate(now: Date) {
        lock.lock(); defer { lock.unlock() }
        let delay = PaneRefreshBackoff.nextRetryDelay(
            retryCount: _state.retryCount, cap: retryCap)
        let early = now.addingTimeInterval(delay)
        let natural = naturalNextUpdate(now: now, state: _state)
        // Glance: cap the early retry by the natural nextUpdate so
        // a slow-moving tile doesn't retry past its own freshness
        // budget. For .infinite there is no natural boundary, so the
        // early time stands.
        switch _state.cacheType {
        case .infinite:
            _state.nextUpdate = early
        case .duration, .onTheHour:
            _state.nextUpdate = min(early, natural)
        }
    }

    /// Test/host hook: replace the state wholesale. Useful for
    /// rehydrating from `SessionDatabase` in round 2.
    public func replaceState(_ new: PaneRefreshState) {
        lock.lock(); defer { lock.unlock() }
        _state = new
    }

    private func applyOutcome(_ outcome: PaneRefreshOutcome, now: Date) {
        lock.lock()
        switch outcome {
        case .success:
            _state.retryCount = 0
            _state.lastError = nil
            _state.notice = nil
            _state.contentAvailable = true
            _state.nextUpdate = naturalNextUpdate(now: now, state: _state)
            lock.unlock()
        case .partial(let notice):
            // Preserve prior contentAvailable. Don't bump retryCount —
            // the tile produced something usable.
            _state.lastError = nil
            _state.notice = notice
            _state.nextUpdate = naturalNextUpdate(now: now, state: _state)
            lock.unlock()
        case .failure(let error):
            _state.retryCount += 1
            _state.lastError = error
            let delay = PaneRefreshBackoff.nextRetryDelay(
                retryCount: _state.retryCount, cap: retryCap)
            let early = now.addingTimeInterval(delay)
            let natural = naturalNextUpdate(now: now, state: _state)
            switch _state.cacheType {
            case .infinite:
                _state.nextUpdate = early
            case .duration, .onTheHour:
                _state.nextUpdate = min(early, natural)
            }
            lock.unlock()
        }
    }

    private func naturalNextUpdate(now: Date, state: PaneRefreshState) -> Date {
        switch state.cacheType {
        case .infinite:
            return .distantFuture
        case .duration:
            return now.addingTimeInterval(state.cacheDuration)
        case .onTheHour:
            return Self.nextHourBoundary(after: now)
        }
    }

    static func nextHourBoundary(after date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        guard let topOfThisHour = cal.date(from: comps) else {
            return date.addingTimeInterval(3600)
        }
        return topOfThisHour.addingTimeInterval(3600)
    }
}

// MARK: - PaneRefreshWorkerPool

/// Bounded concurrency pool. The host calls `run { ... }` for each
/// due tile; at most `maxConcurrent` updates run in parallel, the
/// rest queue and resume in FIFO order.
///
/// Used for monitoring tiles that hit network endpoints (Glance's
/// `monitor` and `change-detection` widgets). A pane-refresh sweep
/// typically picks `maxConcurrent` ≈ 4 — enough to overlap I/O
/// without creating thundering-herd traffic when many tiles wake
/// at the same boundary.
public actor PaneRefreshWorkerPool {
    public let maxConcurrent: Int
    private var inflight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int) {
        precondition(maxConcurrent > 0, "maxConcurrent must be positive")
        self.maxConcurrent = maxConcurrent
    }

    /// Run `work` under the pool's concurrency cap. Returns the
    /// closure's value once it completes.
    public func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await work()
        release()
        return result
    }

    /// Number of currently-running tasks. Intended for tests + diagnostics.
    public var currentInflight: Int { inflight }

    /// Number of tasks queued waiting for a slot. Intended for tests + diagnostics.
    public var pendingWaiters: Int { waiters.count }

    private func acquire() async {
        if inflight < maxConcurrent {
            inflight += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        // The releasing task handed us the slot — it kept `inflight`
        // unchanged on its way out, so we don't bump it here.
    }

    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            // Hand the slot off — `inflight` stays the same.
            next.resume()
        } else {
            inflight -= 1
        }
    }
}
