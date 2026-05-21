import Foundation
import UserNotifications
import Core

/// T.6 production hookup. Called once from `SenkaniGUI.init()` to
/// (1) request UN authorization, (2) load the disk config, (3)
/// build a `NotificationRouter` over `StdoutSink` + a
/// UN-backed `MacOSLocalSink`, and (4) install it into the
/// process-global `NotificationDelivery` holder.
///
/// **Why a free function, not a service object.** The bootstrap
/// has no per-instance state — it wires `NotificationDelivery`
/// once and returns. A free function keeps the App init readable
/// and avoids another `@Observable` lifetime to track.
///
/// **Authorization.** First call requests `.alert + .sound` from
/// `UNUserNotificationCenter`. macOS shows the operator's TCC
/// prompt; the operator grants or denies once. Subsequent App
/// launches see the cached decision and never re-prompt. A denied
/// grant does NOT prevent the router from being installed —
/// `MacOSLocalSink` still fires; UN silently swallows the request
/// at the OS layer.
///
/// **Failure modes.** If the App is running unbundled / unsigned,
/// `UNUserNotificationCenter.current()` returns a center whose
/// `add(_:)` no-ops at the OS layer. The router is still installed;
/// the fan-out still runs; the banner just never appears. This is
/// the right behavior — operators running an unsigned dev build
/// shouldn't get an authorization prompt, and they don't get
/// banners. Production-signed builds get both.
enum NotificationBootstrap {

    /// Default config path: `~/.senkani/notifications.json`. The
    /// disk-shape mirrors `NotificationRouter.Config`; see that
    /// type for the JSON schema.
    static func defaultConfigPath() -> String {
        let home = NSString("~/.senkani/notifications.json").expandingTildeInPath
        return home
    }

    /// One-shot bootstrap. Idempotent at the
    /// `NotificationDelivery.install` boundary — calling twice
    /// replaces the previously installed router.
    ///
    /// `configPath` defaults to `~/.senkani/notifications.json`.
    /// Tests can pass a path under `withTestHome`.
    ///
    /// `bridge` defaults to a real `UNNotifierBridge`; tests pass
    /// a `SpyLocalNotifierBridge` so they can assert on payloads
    /// without standing up a UN center.
    static func bootstrap(
        configPath: String? = nil,
        bridge: LocalNotifierBridge? = nil
    ) {
        let resolvedConfigPath = configPath ?? defaultConfigPath()
        let resolvedBridge = bridge ?? UNNotifierBridge()

        let config = NotificationRouter.loadConfig(from: resolvedConfigPath)
            ?? NotificationRouter.Config(sinks: [:])  // empty config → default-on for every sink

        let stdoutSink = StdoutSink()
        let macosSink = MacOSLocalSink(bridge: resolvedBridge)

        let router = NotificationRouter.make(
            sinks: [
                (name: "stdout", sink: stdoutSink),
                (name: "macos_local", sink: macosSink)
            ],
            config: config
        )

        NotificationDelivery.install(router)
    }

    /// Request notification authorization from the user. Safe to
    /// call repeatedly — `UNUserNotificationCenter` caches the
    /// decision after the first prompt. Async-firing-and-forget:
    /// the App proceeds whether or not the operator grants.
    ///
    /// Pulled out from `bootstrap(...)` so unit tests can install
    /// a router without triggering the TCC prompt (which would
    /// hang the test suite in CI).
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // intentionally empty — denial is OK; the router is
            // installed regardless.
        }
    }
}
