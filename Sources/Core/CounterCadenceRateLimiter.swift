import Foundation

// MARK: - CounterCadenceRateLimiter
//
// Phase U.8 — counter-cadence schedules ("every 10th tool_call") fire
// from `HookRouter` post-tool reactions, not from launchd. That means
// they can run as fast as the user produces tool events, which is the
// amplification scenario Hermes calls out: a power user fires 100
// sessions in a day → a "every 10th" cadence becomes a 10-fires-in-
// minutes cudgel.
//
// This rate limiter caps counter cadences at one fire per `minimum`
// interval (default 60s). It is the load-bearing guard between
// `HookRouter` and `ScheduleStore` for counter-cadence schedules.
//
// Single-instance, value-typed via Mutex — one limiter per process.

public final class CounterCadenceRateLimiter: @unchecked Sendable {
    private let minimum: TimeInterval
    private let lock = NSLock()
    private var lastFire: [String: Date] = [:]

    public init(minimum: TimeInterval = 60) {
        self.minimum = minimum
    }

    /// Returns true if `scheduleName` may fire at `now`. Caller MUST
    /// honor the result — a false reply means "skip this fire, do not
    /// retry-on-loop".
    ///
    /// On true, the limiter records `now` as the new last-fire time
    /// (so two callers with the same scheduleName cannot both pass
    /// the gate within the minimum window).
    public func allow(scheduleName: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let prev = lastFire[scheduleName], now.timeIntervalSince(prev) < minimum {
            return false
        }
        lastFire[scheduleName] = now
        return true
    }

    /// Read-only inspection: when did `scheduleName` last fire? Returns
    /// nil if it has not fired yet under this limiter's lifetime.
    public func lastFireTime(for scheduleName: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastFire[scheduleName]
    }

    /// Reset all tracked fire times. Intended for tests.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastFire.removeAll()
    }
}
