import Foundation
import UserNotifications
import Core

/// T.6 production bridge. Conforms to `Core.LocalNotifierBridge` by
/// scheduling an immediate `UNNotificationRequest` against the
/// default user-notification center.
///
/// **Non-blocking contract.** `MacOSLocalSink` documents that bridge
/// implementations MUST NOT block the caller; the UN API itself is
/// already async (the completion handler is invoked off-thread), so
/// `post(...)` returns as soon as the request is enqueued.
///
/// **Authorization is the App boot's job, not this bridge's.** The
/// bridge does NOT call `requestAuthorization`. By the time the
/// first `NotifyEvent` reaches this bridge, the App has either
/// (a) been granted notification permission and the banner is
/// delivered, (b) been denied and UN silently swallows the request,
/// or (c) the App is unbundled / unsigned and UN no-ops at the OS
/// level. In every case, fan-out is non-blocking. See
/// `NotificationBootstrap.swift` for the authorization request.
///
/// **Why the throw is unused in the happy path.** `MacOSLocalSink`
/// invokes `try bridge.post(...)`; `NotificationFanout.deliver`
/// swallows any throw per the T.6a non-blocking contract. We
/// `throw` from `post` only when constructing the request payload
/// fails (which it shouldn't — `UNMutableNotificationContent` has
/// no documented failure modes). The throw path is reserved for
/// future telemetry / failure reporting.
struct UNNotifierBridge: LocalNotifierBridge {

    /// Optional override of the notification center accessor. Tests
    /// pass a closure returning a fake center; production calls
    /// `UNUserNotificationCenter.current()`.
    private let centerProvider: @Sendable () -> UNUserNotificationCenter

    init(centerProvider: @Sendable @escaping () -> UNUserNotificationCenter = { UNUserNotificationCenter.current() }) {
        self.centerProvider = centerProvider
    }

    func post(title: String, subtitle: String, body: String) throws {
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = .default

        // Identifier: a UUID per request so a fast double-fire doesn't
        // collapse two events into one banner via UN's identifier
        // collapsing.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // nil = deliver immediately
        )

        // `add(_:withCompletionHandler:)` is non-blocking: the SDK
        // enqueues the request and returns. The completion handler
        // fires on a UN-managed background queue with a UN error
        // (e.g. authorization denied). We don't propagate that error
        // back to the producer — by design, a denied permission
        // should NOT cause the producer to throw. The error is
        // available for future telemetry hookup.
        centerProvider().add(request) { _ in
            // intentionally empty — see contract above
        }
    }
}
