import Foundation

/// P2-9: Typed-field structured log value.
///
/// The `log` API accepts a dictionary of these so callers don't pass
/// stringly-typed numbers. Five cases:
/// - `.string(_)` — arbitrary user-influenced text; secret-scanned at emit.
/// - `.int`/`.double`/`.bool` — numeric / boolean primitives, no scanning.
/// - `.path(_)` — filesystem path; `/Users/<name>` stripped at emit
///   (Cavoukian C2). Use this for any field that holds a user's project
///   root, home-directory descendant, or otherwise identifying path.
///
/// All `.string(_)` values are passed through `SecretDetector.scan` at
/// emit time (Cavoukian C5). Even if a caller accidentally places an API
/// key in a log field, it's redacted at the sink.
public enum LogValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case path(String)

    /// JSON literal — quoted + escaped for strings, bare for numerics.
    var jsonLiteral: String {
        switch self {
        case .string(let s): return "\"\(Logger.jsonEscape(Logger.sanitizeUserString(s)))\""
        case .int(let i):    return "\(i)"
        case .double(let d): return "\(d)"
        case .bool(let b):   return b ? "true" : "false"
        case .path(let p):   return "\"\(Logger.jsonEscape(ProjectSecurity.redactPath(p)))\""
        }
    }

    /// Plain `key=value` literal for human-readable mode.
    var textLiteral: String {
        switch self {
        case .string(let s): return Logger.sanitizeUserString(s)
        case .int(let i):    return "\(i)"
        case .double(let d): return "\(d)"
        case .bool(let b):   return b ? "true" : "false"
        case .path(let p):   return ProjectSecurity.redactPath(p)
        }
    }
}

/// P2-9: Structured logger for senkani server events.
///
/// Default mode matches the existing `[event] key=value` style — eyeball-
/// friendly, grep-friendly, backward-compatible with current stderr readers.
/// Setting `SENKANI_LOG_JSON=1` (or `"true"`) emits one JSON object per line
/// for structured ingestion.
///
/// Minimum useful fields (documented for callers, not enforced):
///   - `session_id`: String — caller's MCP session UUID when available.
///   - `tool`: String — MCP tool name for tool-lifecycle events.
///   - `duration_ms`: Int — wall-clock latency.
///   - `outcome`: String — "success" | "error" | "blocked" | "skipped".
/// For ratios, emit both numerator and denominator (e.g. `cache_hits`
/// AND `cache_total`) — ratios computed downstream stay truthful (Gelman).
///
/// Thread-safety: a single `write(2)` up to PIPE_BUF (512 bytes) is atomic
/// on macOS, so short concurrent log lines don't interleave bytes. No lock
/// required here. Cached `isJSON` flag uses nonisolated(unsafe) + NSLock
/// because it's set once and read from many threads.
public enum Logger {

    nonisolated(unsafe) private static var _isJSON: Bool?
    nonisolated(unsafe) private static let isJSONLock = NSLock()

    /// Test-only observation hook. When set, every `log(...)` call also
    /// invokes the sink with the raw event + fields BEFORE writing to
    /// stderr. Production callers never set this; tests register a sink
    /// to assert routing without dup2-ing fd 2. The stderr write still
    /// happens — the sink is a tee, not a replacement.
    nonisolated(unsafe) private static var _testSink: (@Sendable (String, [String: LogValue]) -> Void)?
    nonisolated(unsafe) private static let testSinkLock = NSLock()

    /// Test-only: install (or clear with `nil`) an observation sink.
    /// Call from `defer { Logger._setTestSink(nil) }` to avoid leaking
    /// state between tests.
    public static func _setTestSink(_ sink: (@Sendable (String, [String: LogValue]) -> Void)?) {
        testSinkLock.lock(); defer { testSinkLock.unlock() }
        _testSink = sink
    }

    /// Cached result of `SENKANI_LOG_JSON` env lookup. Env is read once on
    /// first access then memoized for the process lifetime.
    internal static var isJSON: Bool {
        isJSONLock.lock(); defer { isJSONLock.unlock() }
        if let cached = _isJSON { return cached }
        let raw = ProcessInfo.processInfo.environment["SENKANI_LOG_JSON"]?.lowercased() ?? ""
        let v = (raw == "1" || raw == "true" || raw == "on" || raw == "yes")
        _isJSON = v
        return v
    }

    /// Reset the cached `isJSON` flag — test-only helper.
    internal static func _resetCacheForTesting() {
        isJSONLock.lock(); defer { isJSONLock.unlock() }
        _isJSON = nil
    }

    /// Emit an event. Pass fields via `[String: LogValue]` so types are preserved
    /// in JSON mode. The written line always ends with `\n`.
    public static func log(_ event: String, fields: [String: LogValue] = [:]) {
        testSinkLock.lock()
        let sink = _testSink
        testSinkLock.unlock()
        sink?(event, fields)
        let line = format(event: event, fields: fields) + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Build a log line in the currently-configured format. Pass `asJSON` to
    /// override the env-derived default — tests rely on this to check both
    /// formats without mutating process env.
    internal static func format(
        event: String,
        fields: [String: LogValue],
        asJSON: Bool? = nil
    ) -> String {
        let json = asJSON ?? isJSON
        if json {
            // Stable ordering: ts, event, then fields alphabetized by key so
            // a log stream has deterministic column order.
            var parts: [String] = []
            parts.append("\"ts\":\(Date().timeIntervalSince1970)")
            parts.append("\"event\":\"\(jsonEscape(event))\"")
            for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
                parts.append("\"\(jsonEscape(k))\":\(v.jsonLiteral)")
            }
            return "{" + parts.joined(separator: ",") + "}"
        } else {
            // Human-readable. Key=value pairs alphabetized for determinism.
            var parts = ["[\(event)]"]
            for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
                parts.append("\(k)=\(v.textLiteral)")
            }
            return parts.joined(separator: " ")
        }
    }

    /// Cavoukian C5: every user-influenced string field passes through
    /// `SecretDetector.scan` at emit time so planted API keys / bearer
    /// tokens / AWS creds get `[REDACTED:…]`'d in logs the same way
    /// they are in MCP outputs. Cost: 13 regex `firstMatch` probes per
    /// string field; negligible vs. the `write(2)` that follows.
    internal static func sanitizeUserString(_ s: String) -> String {
        SecretDetector.scan(s).redacted
    }

    /// JSON string escape. Only the characters JSON requires — `\`, `"`, the
    /// ASCII control whitespace. Unicode passes through.
    internal static func jsonEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:   out.append(ch)
            }
        }
        return out
    }
}
