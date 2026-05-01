import Foundation

/// One notification event the gate (or any future caller) can emit.
/// Round T.6a ships three variants — `notifyDone` for successful
/// completion of a confirmed action, `notifyFailure` for a denied or
/// failed action, and `scheduleEnd` for the natural-language schedule
/// runner to surface its tail event. Real adapters (Stdout, MacOSLocal,
/// Pushover) land in t6b/t6c; round 1 only defines the protocol + null
/// + mock implementations.
public enum NotifyEvent: Sendable, Equatable {
    /// A confirmed write/exec call completed successfully.
    case notifyDone(toolName: String, summary: String)
    /// A confirmed call was denied by the gate or failed during
    /// execution.
    case notifyFailure(toolName: String, reason: String)
    /// A scheduled task wrapped up. `scheduleId` is the operator-named
    /// schedule; `summary` is a one-liner for the notification body.
    case scheduleEnd(scheduleId: String, summary: String)
}

/// Output sink for `NotifyEvent`. Implementations fan out the event to
/// whatever channel they front (stdout, AppKit, HTTP). The protocol's
/// only contract is non-blocking: a slow or throwing sink does not
/// stall the caller.
public protocol NotificationSink: Sendable {
    /// Deliver one event. Implementations MUST NOT block the caller —
    /// real adapters dispatch to a background queue. A throw is caught
    /// at the fan-out layer and does not propagate.
    func notify(_ event: NotifyEvent) throws
}

/// No-op sink. Used in headless CI and as the default when no real
/// sink is wired in. Matches the `Null...` convention used elsewhere
/// in Core (e.g. `NullProseCadenceCompiler`).
public struct NullNotificationSink: NotificationSink {
    public init() {}
    public func notify(_ event: NotifyEvent) throws {
        // intentionally empty — null adapter
    }
}

/// Test-only sink that records every delivered event in order.
/// Thread-safe via NSLock. Tests assert on `delivered`.
public final class MockNotificationSink: NotificationSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _delivered: [NotifyEvent] = []
    /// When non-nil, `notify` throws this error after recording the
    /// event. Used to verify fan-out tolerance to a throwing adapter.
    public var errorToThrow: Error?

    public init(errorToThrow: Error? = nil) {
        self.errorToThrow = errorToThrow
    }

    public var delivered: [NotifyEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _delivered
    }

    public func notify(_ event: NotifyEvent) throws {
        lock.lock()
        _delivered.append(event)
        let err = errorToThrow
        lock.unlock()
        if let err { throw err }
    }

    public func reset() {
        lock.lock()
        _delivered.removeAll()
        lock.unlock()
    }
}

/// Fan-out helper. Delivers `event` to every sink, swallowing throws so
/// one bad adapter doesn't block the others. Round T.6a's contract:
/// "A throwing sink does not block other sinks in the fan-out."
public enum NotificationFanout {
    public static func deliver(_ event: NotifyEvent, to sinks: [NotificationSink]) {
        for sink in sinks {
            do {
                try sink.notify(event)
            } catch {
                // Swallow per the non-blocking contract. Round T.6b
                // adds a structured-log line here; round 1 stays
                // minimal because there are no real sinks yet.
            }
        }
    }
}
