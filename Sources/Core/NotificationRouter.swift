import Foundation

/// Phase T.6b — `NotificationRouter`.
///
/// Picks which named sinks should receive which `NotifyEvent` variant.
/// Backs the "Settings → Notifications" matrix described in T.6b's
/// scope; round-1 ships the JSON-only path (matrix UI is t6b').
///
/// JSON shape (`~/.senkani/notifications.json` or per-project):
///
/// ```json
/// {
///   "sinks": {
///     "stdout":      { "events": ["notify_done", "notify_failure", "schedule_end"] },
///     "macos_local": { "events": ["notify_failure", "schedule_end"] }
///   }
/// }
/// ```
///
/// Defaults (no config file): every named sink subscribes to every
/// event variant. Operators opt OUT, not IN — round 1 errs on the
/// noisy side because under-notification hides failures.
///
/// ## Gate boundary — CLEAN SEPARATION (ratified 2026-06-08, item
/// `t6-notification-confirmation-gate-deeper-respect`; panel D11:
/// Norman / Allspaw / Lauret / Torvalds, unanimous)
///
/// **`ConfirmationGate` is intentionally NOT consulted by this router.**
/// The per-sink event-class `events` subscription is the ONE AND ONLY
/// notification gate. The router decides "does this sink want this event
/// class?" — nothing more. There is deliberately no hidden coupling
/// where a `ConfirmationGate` per-tool deny rule also suppresses a
/// banner (Torvalds: one gate, no surprise cross-wiring; Lauret: one
/// consistent contract per concern). The exec/write gate lives in
/// `ConfirmationGate`/`HookRouter`; the notification gate lives here.
///
/// **The one non-negotiable exception is failure-surfacing, not
/// suppression.** A `ConfirmationGate` `.deny` is the *dangerous*
/// case to hide (Norman/Allspaw: a silent denial is the trap — the
/// operator must always learn that an action was blocked). So a deny
/// emits a NON-SUPPRESSIBLE `notifyFailure` via
/// `deliverUnconditional(_:)` (below), which bypasses the per-sink
/// subscription filter. This is not the router consulting the gate; it
/// is the gate's *producer* refusing to let a deny go silent. The
/// router never reads gate state — it only offers an unconditional fan
/// the producer chooses to use for the deny class.
public struct NotificationRouter: Sendable {

    /// Wire-shape keys for `NotifyEvent` variants. Matches the
    /// `kind` field that `StdoutSink.render` emits.
    public enum EventKind: String, Sendable, CaseIterable {
        case notifyDone = "notify_done"
        case notifyFailure = "notify_failure"
        case scheduleEnd = "schedule_end"

        public static func of(_ event: NotifyEvent) -> EventKind {
            switch event {
            case .notifyDone: return .notifyDone
            case .notifyFailure: return .notifyFailure
            case .scheduleEnd: return .scheduleEnd
            }
        }
    }

    /// One named sink + the events it subscribes to. The router
    /// owns the (name, sink) pairing so config lookups by name
    /// stay stable across reloads.
    public struct Entry: Sendable {
        public let name: String
        public let sink: NotificationSink
        public let events: Set<EventKind>

        public init(name: String, sink: NotificationSink, events: Set<EventKind>) {
            self.name = name
            self.sink = sink
            self.events = events
        }
    }

    private let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Sinks that should receive `event`, in registration order.
    /// Honours the per-sink `events` subscription — the ONLY
    /// notification gate (see the type doc-comment's gate boundary).
    public func sinks(for event: NotifyEvent) -> [NotificationSink] {
        let kind = EventKind.of(event)
        return entries.filter { $0.events.contains(kind) }.map(\.sink)
    }

    /// EVERY registered sink, in registration order, ignoring the
    /// per-sink subscription. Backs `deliverUnconditional(_:)` — the
    /// non-suppressible deny-surfacing path. Not for general use: the
    /// per-sink subscription is the gate for every event class EXCEPT
    /// the explicit failure-surfacing exception documented on the type.
    public func allSinks() -> [NotificationSink] {
        entries.map(\.sink)
    }

    /// Fan `event` out to every subscribed sink. Re-uses
    /// `NotificationFanout.deliver`, so a throwing sink does not
    /// block the rest — same non-blocking contract as T.6a.
    /// Per-sink subscription is honoured: an unsubscribed sink is
    /// silent for this event class.
    public func deliver(_ event: NotifyEvent) {
        NotificationFanout.deliver(event, to: sinks(for: event))
    }

    /// NON-SUPPRESSIBLE fan-out: deliver `event` to EVERY registered
    /// sink regardless of its per-sink subscription. The deny-surfacing
    /// exception (see the type doc-comment): a `ConfirmationGate` `.deny`
    /// MUST reach the operator even when the sink opted OUT of the
    /// `notifyFailure` class, because a silent denial is the dangerous
    /// case (Norman/Allspaw). Same non-blocking contract — a throwing
    /// sink does not block the rest. This does NOT consult
    /// `ConfirmationGate`; it is the gate's producer refusing to let a
    /// deny go silent. Use ONLY for the deny class.
    public func deliverUnconditional(_ event: NotifyEvent) {
        NotificationFanout.deliver(event, to: allSinks())
    }

    // MARK: - Config loading

    /// Build a router from an array of (name, sink) pairs and a
    /// config dictionary. Sinks named in `sinks` but absent from
    /// the config subscribe to every event (default-on). Names
    /// listed in the config but absent from `sinks` are ignored
    /// (a stale config doesn't break the router).
    public static func make(
        sinks: [(name: String, sink: NotificationSink)],
        config: Config
    ) -> NotificationRouter {
        let entries = sinks.map { (name, sink) -> Entry in
            let events: Set<EventKind>
            if let raw = config.sinks[name]?.events {
                events = Set(raw.compactMap(EventKind.init(rawValue:)))
            } else {
                events = Set(EventKind.allCases) // default-on
            }
            return Entry(name: name, sink: sink, events: events)
        }
        return NotificationRouter(entries: entries)
    }

    /// Disk-shape mirror of the JSON config. Decoding tolerates
    /// missing keys + unknown event names (round-1 forward-compat:
    /// adding a new event variant in t6c shouldn't break a router
    /// loaded from an older config file).
    public struct Config: Codable, Sendable, Equatable {
        public struct SinkSubscription: Codable, Sendable, Equatable {
            public let events: [String]
            public init(events: [String]) {
                self.events = events
            }
        }
        public let sinks: [String: SinkSubscription]
        public init(sinks: [String: SinkSubscription]) {
            self.sinks = sinks
        }

        /// Encode this config to JSON bytes. Uses a deterministic
        /// encoder (`.sortedKeys`) so that
        /// `encode(decode(encode(x))) == encode(x)` is byte-stable —
        /// the eventual Settings matrix pane (parent
        /// `t6-settings-notifications-matrix-ui-2026-05-21`) writes
        /// the operator-edited config back via this path, and a
        /// stable byte layout keeps disk diffs / VCS-tracked configs
        /// noise-free across re-writes. Purely additive — does NOT
        /// change `loadConfig`'s decode behavior.
        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(self)
        }

        /// Write this config's JSON bytes to `path`, atomically.
        /// Mirror of `NotificationRouter.loadConfig(from:)`'s read
        /// path. Throwing (unlike the lenient `loadConfig`, which
        /// swallows I/O errors): a write that fails MUST surface so a
        /// settings pane can show the operator the failure rather
        /// than silently dropping their edit.
        public func save(to path: String) throws {
            try encoded().write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Load a `Config` from a JSON file. Returns `nil` (default-on
    /// for every sink) on missing-file or parse failure — callers
    /// should not block startup on a malformed notifications.json.
    public static func loadConfig(from path: String) -> Config? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return try? JSONDecoder().decode(Config.self, from: data)
    }
}
