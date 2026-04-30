import Foundation

/// Phase T.6b — `StdoutSink`.
///
/// Writes one canonical JSON line per `NotifyEvent` to a `FileHandle`
/// (defaults to `FileHandle.standardOutput`). Useful for headless / CI
/// runs where AppKit is unavailable, and for any operator who pipes
/// senkani logs into a structured-log collector.
///
/// Wire shape (stable contract — downstream parsers depend on it):
///
/// ```json
/// {"kind":"notify_done","tool":"Edit","summary":"patched 1 file","ts":"2026-04-30T15:21:09Z"}
/// {"kind":"notify_failure","tool":"Bash","reason":"operator denied","ts":"..."}
/// {"kind":"schedule_end","schedule_id":"nightly-brief","summary":"done","ts":"..."}
/// ```
///
/// All payload values are scalar strings + an ISO-8601 timestamp; no
/// nested objects, no arrays. That keeps grep/jq pipelines trivial.
///
/// Concurrency: each `notify(_:)` call serialises the write under an
/// `NSLock` so concurrent fan-outs never interleave partial lines on
/// the same FileHandle. The lock is per-sink — separate sinks (e.g. a
/// stdout adapter and a stderr adapter) don't contend.
public final class StdoutSink: NotificationSink, @unchecked Sendable {

    /// Emits the rendered line. Production passes
    /// `FileHandle.standardOutput.write(_:)`; tests pass a closure that
    /// captures into a buffer. Any throw propagates to the fan-out
    /// layer, which swallows it (per the T.6a contract).
    public typealias Writer = @Sendable (Data) throws -> Void

    private let writer: Writer
    private let lock = NSLock()

    /// Inject a writer. The default writes to `FileHandle.standardOutput`.
    public init(writer: @escaping Writer = StdoutSink.defaultWriter) {
        self.writer = writer
    }

    public static let defaultWriter: Writer = { data in
        FileHandle.standardOutput.write(data)
    }

    public func notify(_ event: NotifyEvent) throws {
        let line = try Self.render(event)
        lock.lock()
        defer { lock.unlock() }
        try writer(line)
    }

    /// Render `event` as a single JSON line ending in "\n". Public so
    /// tests can assert on the wire shape without going through a sink.
    public static func render(_ event: NotifyEvent, now: Date = Date()) throws -> Data {
        var payload: [String: String] = [
            "ts": iso8601.string(from: now),
        ]
        switch event {
        case .notifyDone(let tool, let summary):
            payload["kind"] = "notify_done"
            payload["tool"] = tool
            payload["summary"] = summary
        case .notifyFailure(let tool, let reason):
            payload["kind"] = "notify_failure"
            payload["tool"] = tool
            payload["reason"] = reason
        case .scheduleEnd(let scheduleId, let summary):
            payload["kind"] = "schedule_end"
            payload["schedule_id"] = scheduleId
            payload["summary"] = summary
        }

        // Sorted keys give callers a stable byte order — easier to
        // diff in fixtures and easier on operators eyeballing logs.
        let json = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        var line = json
        line.append(0x0A) // "\n"
        return line
    }

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
