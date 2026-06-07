import Foundation

/// Process-global delivery point for `NotifyEvent`. Production code
/// fires events via `NotificationDelivery.deliver(_:)`; SenkaniApp
/// installs the live `NotificationRouter` (with a UN-backed
/// `MacOSLocalSink`) at boot via `install(_:)`. CLI / test
/// processes that never call `install(_:)` see a no-op default —
/// the call site doesn't need to know who's listening.
///
/// Threading: every accessor is serialized by an internal `NSLock`.
/// `deliver(_:)` snapshots the current router under the lock, then
/// dispatches outside the lock so a slow sink can't block other
/// producers.
///
/// This holder is the *only* mutable global state introduced by
/// T.6 production-hookup; the router itself is a value type and
/// the sinks are either stateless or `Sendable`.
public enum NotificationDelivery {

    nonisolated(unsafe) private static var _router: NotificationRouter?
    private static let lock = NSLock()

    /// Install (or replace) the production router. Called by
    /// SenkaniApp's notification bootstrap once UN authorization has
    /// been requested and the disk config has been loaded.
    public static func install(_ router: NotificationRouter) {
        lock.lock()
        _router = router
        lock.unlock()
    }

    /// Fan `event` out to every sink subscribed to its event class.
    /// No-op when no router has been installed — the default state
    /// for CLI / test processes.
    public static func deliver(_ event: NotifyEvent) {
        lock.lock()
        let router = _router
        lock.unlock()
        router?.deliver(event)
    }

    /// True iff `install(_:)` has been called this process. Lets
    /// callers gate "do the work that emits the event" when no one
    /// is listening (rare — the producers above are already
    /// no-op-cheap, but the predicate is exposed for tests).
    public static var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _router != nil
    }

    /// TEST ONLY. Clears the installed router so a subsequent test
    /// can install a spy without inheriting prior state. The full
    /// suite runs in parallel by default; tests that touch this
    /// holder MUST install + assert + reset within their own scope.
    public static func resetForTesting() {
        lock.lock()
        _router = nil
        lock.unlock()
    }
}
