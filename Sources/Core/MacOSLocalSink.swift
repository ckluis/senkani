import Foundation

/// Phase T.6b — `MacOSLocalSink`.
///
/// Bridges a `NotifyEvent` into a macOS local notification (banner +
/// sound from Notification Center). The sink itself stays platform-
/// neutral — it talks to a `LocalNotifierBridge` injected at init.
/// Production wiring (in `SenkaniApp`) supplies a bridge backed by
/// `UNUserNotificationCenter`; CI uses `SpyLocalNotifierBridge`.
///
/// Why the protocol seam: `Core` is shared by the CLI / MCP server /
/// App, none of which can take an unguarded dependency on
/// `UserNotifications.framework` (bundle-only API, requires a code-
/// signed app). The protocol keeps Core test-pure and lets the App
/// own the OS hand-off.
public protocol LocalNotifierBridge: Sendable {
    /// Schedule one immediate banner notification. Implementations
    /// MUST NOT block — real bridges hand off to a background queue
    /// and return. A throw propagates to `NotificationFanout`, which
    /// swallows it per the T.6a non-blocking contract.
    ///
    /// `subtitle` may be empty (some events have no second line);
    /// `body` is always populated.
    func post(title: String, subtitle: String, body: String) throws
}

/// No-op bridge. Default wiring when the App hasn't installed a real
/// `UNUserNotificationCenter`-backed bridge yet (e.g. headless CLI
/// runs). Mirrors the `NullProseCadenceCompiler` pattern — silent,
/// never throws.
public struct NullLocalNotifierBridge: LocalNotifierBridge {
    public init() {}
    public func post(title: String, subtitle: String, body: String) throws {
        // intentionally empty
    }
}

/// Test-time bridge. Records every call so tests can assert on the
/// title/subtitle/body the sink derived from a `NotifyEvent`.
/// Thread-safe via `NSLock`.
public final class SpyLocalNotifierBridge: LocalNotifierBridge, @unchecked Sendable {
    public struct Posted: Equatable, Sendable {
        public let title: String
        public let subtitle: String
        public let body: String
    }

    private let lock = NSLock()
    private var _posted: [Posted] = []
    /// When non-nil, every `post` records the call AND throws. Used
    /// to assert the fan-out's swallow-throws contract still holds
    /// for the real (not just MockNotificationSink) sink type.
    public var errorToThrow: Error?

    public init(errorToThrow: Error? = nil) {
        self.errorToThrow = errorToThrow
    }

    public var posted: [Posted] {
        lock.lock()
        defer { lock.unlock() }
        return _posted
    }

    public func post(title: String, subtitle: String, body: String) throws {
        lock.lock()
        _posted.append(Posted(title: title, subtitle: subtitle, body: body))
        let err = errorToThrow
        lock.unlock()
        if let err { throw err }
    }

    public func reset() {
        lock.lock()
        _posted.removeAll()
        lock.unlock()
    }
}

/// Sink that turns a `NotifyEvent` into a local banner via a bridge.
public struct MacOSLocalSink: NotificationSink, Sendable {
    private let bridge: LocalNotifierBridge

    public init(bridge: LocalNotifierBridge = NullLocalNotifierBridge()) {
        self.bridge = bridge
    }

    public func notify(_ event: NotifyEvent) throws {
        let p = Self.payload(for: event)
        try bridge.post(title: p.title, subtitle: p.subtitle, body: p.body)
    }

    /// Deterministic mapping `NotifyEvent` → banner copy. Public so
    /// tests can pin the wire shape without standing up a bridge.
    public static func payload(for event: NotifyEvent) -> (title: String, subtitle: String, body: String) {
        switch event {
        case .notifyDone(let tool, let summary):
            return ("Senkani — done", tool, summary)
        case .notifyFailure(let tool, let reason):
            return ("Senkani — failed", tool, reason)
        case .scheduleEnd(let scheduleId, let summary):
            return ("Senkani — schedule", scheduleId, summary)
        }
    }
}
