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
    public func sinks(for event: NotifyEvent) -> [NotificationSink] {
        let kind = EventKind.of(event)
        return entries.filter { $0.events.contains(kind) }.map(\.sink)
    }

    /// Fan `event` out to every subscribed sink. Re-uses
    /// `NotificationFanout.deliver`, so a throwing sink does not
    /// block the rest — same non-blocking contract as T.6a.
    public func deliver(_ event: NotifyEvent) {
        NotificationFanout.deliver(event, to: sinks(for: event))
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
