import Foundation

/// T.6 follow-up — headless semantics for the Settings → Notifications
/// matrix pane (item `t6-settings-notifications-matrix-ui-2026-05-21`).
///
/// The SwiftUI pane (`SenkaniApp/Views/NotificationsSettingsView.swift`)
/// renders a per-sink × per-event grid of checkboxes over
/// `NotificationRouter.Config`. Every cell read and every cell flip
/// funnels through this enum so the matrix semantics are CI-testable
/// without rendering a view:
///
/// - **Default-on contract preserved.** A sink absent from the config
///   subscribes to every event (the router's documented opt-OUT
///   posture — under-notification hides failures). `isEnabled` mirrors
///   exactly what `NotificationRouter.make` would do for that cell.
/// - **One flip changes one cell.** Toggling a cell on a sink with no
///   explicit entry first materializes the full default-on
///   subscription, then flips the single requested event — so the
///   operator's first opt-out never silently drops the other classes.
/// - **Deterministic bytes.** Event lists are written with known kinds
///   in `EventKind.allCases` order; unknown event names already in the
///   file (forward-compat: a newer senkani may have written classes
///   this build doesn't know) are preserved after them in their
///   original relative order. Combined with `Config.encoded()`'s
///   `.sortedKeys`, re-saves of an untouched matrix are byte-stable.
public enum NotificationMatrix {

    /// Is `(sink, event)` enabled under `config`? A sink with no
    /// explicit entry is default-on for every event class.
    public static func isEnabled(
        _ config: NotificationRouter.Config,
        sink: String,
        event: NotificationRouter.EventKind
    ) -> Bool {
        guard let subscription = config.sinks[sink] else { return true }
        return subscription.events.contains(event.rawValue)
    }

    /// Return a new config with the `(sink, event)` cell flipped.
    ///
    /// An absent sink is first materialized as the full default-on
    /// subscription so the flip changes EXACTLY one cell. Known events
    /// keep `EventKind.allCases` order; unknown event strings are
    /// preserved (deduplicated) after them in original relative order.
    /// Other sinks' entries are untouched.
    public static func toggled(
        _ config: NotificationRouter.Config,
        sink: String,
        event: NotificationRouter.EventKind
    ) -> NotificationRouter.Config {
        let knownOrder = NotificationRouter.EventKind.allCases.map(\.rawValue)
        let current = config.sinks[sink]?.events ?? knownOrder

        var enabled = Set(current)
        if enabled.contains(event.rawValue) {
            enabled.remove(event.rawValue)
        } else {
            enabled.insert(event.rawValue)
        }

        let known = knownOrder.filter { enabled.contains($0) }
        let knownSet = Set(knownOrder)
        var seen = Set<String>()
        let unknown = current.filter { name in
            guard !knownSet.contains(name), enabled.contains(name) else { return false }
            return seen.insert(name).inserted
        }

        var sinks = config.sinks
        sinks[sink] = .init(events: known + unknown)
        return NotificationRouter.Config(sinks: sinks)
    }

    /// Row order for the matrix: the production-registered sinks first
    /// (in registration order), then any extra sinks present in the
    /// config file (alphabetical) — a hand-added entry the bootstrap
    /// doesn't register is still shown rather than silently hidden.
    public static func displaySinks(
        config: NotificationRouter.Config,
        knownSinks: [String]
    ) -> [String] {
        let extras = config.sinks.keys
            .filter { !knownSinks.contains($0) }
            .sorted()
        return knownSinks + extras
    }
}
