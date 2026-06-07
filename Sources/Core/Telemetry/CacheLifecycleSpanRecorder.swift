import Foundation

/// V.19a-3 — `cache_lifecycle` telemetry spans on
/// `runtime_telemetry_span`. The recorder wires V.19a-1's
/// `MLXPrefixCache` lifecycle hooks (and any future cache-corruption
/// detector) through V.18a-1's `RuntimeTelemetryStore` so each cache
/// event lands as a distinct span row with `span_kind=cache_lifecycle`
/// and a normalized `event_type` attribute.
///
/// ### Privacy contract (V.18 operator-locked default — 2026-05-07)
///
/// Cache prompt content NEVER appears in `runtime_telemetry_span`
/// body. The recorder's public API has no `body` / `payload` /
/// `prompt` parameter — privacy is enforced by API shape, not
/// convention. Attributes are restricted to metadata: `span_kind`,
/// `event_type`, `cache_origin`. The attribute map is run through
/// `OTLPPrivacyFilter.filter(.metadata)` before persist so the
/// V.18a-4 receive-time guarantee also covers our direct-emit path
/// (defense in depth — if a future maintainer adds a sensitive
/// attribute, the filter catches it at write time).
///
/// ### Cross-cutting JOIN (V.19a-4)
///
/// Spans carry `session_id` + `tool_call_id` so the V.19a-4
/// dashboard tile can JOIN against `token_events.session_id +
/// tool_call_id`. The `trace_id` is derived from the session UUID
/// for OTLP trace continuity; the `span_id` is unique per emit.
///
/// ### Hook execution context
///
/// Per V.19a-1, MLXPrefixCache lifecycle hooks fire OUTSIDE
/// `MLXInferenceLock.shared.run { }` blocks — the hook callback path
/// MUST NOT issue Metal calls. This recorder satisfies that
/// invariant: every operation is pure-Swift + a `RuntimeTelemetryStore`
/// write (which dispatches through SQLite, not Metal). A
/// ThreadSanitizer-style test asserts the recorder can be invoked
/// from inside an `MLXInferenceLock.run` closure without deadlocking
/// or attempting Metal-call re-entry.
public final class CacheLifecycleSpanRecorder: @unchecked Sendable {

    /// Normalized cache-event-type discriminator. Stored as the raw
    /// string in the span's `attributes_json` under the `event_type`
    /// key, and as the suffix of the span `name`
    /// (`cache_lifecycle.<event_type>`).
    ///
    /// Coverage rationale:
    /// - `hit` / `coldMiss` / `evict` map 1:1 to MLXPrefixCache
    ///   `.hit` / `.coldMiss` / `.evict` lifecycle states. `.warm`
    ///   (initial) and `.unload` (terminal) deliberately do NOT
    ///   produce cache_lifecycle spans — they are construct/teardown
    ///   transitions with no operationally-interesting cache
    ///   behavior.
    /// - `corruptionRecovery` is a first-class event type for a
    ///   future cache-corruption detector. The detector is out of
    ///   scope for V.19a-3 but the API accepts the value now so a
    ///   later wiring needs no API change.
    public enum EventType: String, Sendable, CaseIterable, Equatable {
        case hit = "hit"
        case coldMiss = "cold_miss"
        case evict = "evict"
        case corruptionRecovery = "corruption_recovery"
    }

    /// Span name prefix. The full span name is
    /// `<spanNamePrefix>.<event_type>` (e.g. `cache_lifecycle.hit`).
    public static let spanNamePrefix = "cache_lifecycle"

    /// `span_kind` attribute value used in every emitted span's
    /// `attributes_json`.
    public static let spanKindValue = "cache_lifecycle"

    private let store: RuntimeTelemetryStore
    private let datasetId: Int64
    private let clock: @Sendable () -> Date

    public init(
        store: RuntimeTelemetryStore,
        datasetId: Int64,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.datasetId = datasetId
        self.clock = clock
    }

    /// Emit one cache_lifecycle span. Returns the inserted row id
    /// (0 on DB failure — `RuntimeTelemetryStore.insertSpan`
    /// contract). Idempotency: callers are responsible for at-most-
    /// once semantics by gating on the upstream hook fire (V.19a-1's
    /// state-transition contract gives exactly-once-per-transition).
    ///
    /// `cacheOrigin` defaults to `.prefixCache` since V.19a-3 only
    /// wires the MLXPrefixCache hook path; future cache subsystems
    /// pass their own origin.
    ///
    /// `durationMs` defaults to 0 for instantaneous events (hit /
    /// cold_miss). Callers MAY pass a non-zero duration for evict /
    /// corruption_recovery if a measurement is available.
    ///
    /// NOTE: no `body` / `payload` / `prompt` parameter. Privacy
    /// contract enforced by API shape — there is no way to attach
    /// prompt content to a cache_lifecycle span through this
    /// recorder.
    @discardableResult
    public func record(
        eventType: EventType,
        sessionID: UUID,
        toolCallID: String? = nil,
        cacheOrigin: CacheOrigin = .prefixCache,
        durationMs: Int = 0
    ) -> Int64 {
        let now = clock()
        let endNs = Int64(now.timeIntervalSince1970 * 1_000_000_000)
        let durationNs = Int64(durationMs) * 1_000_000
        let startNs = endNs - durationNs

        // Build the attribute map. ONLY metadata keys — no prompt
        // body, no payload, no sensitive content. The API shape
        // (no `body:` parameter) enforces this at compile time;
        // the privacy-filter pass below enforces it at write time.
        let rawAttributes: [String: String] = [
            "span_kind":    Self.spanKindValue,
            "event_type":   eventType.rawValue,
            "cache_origin": cacheOrigin.rawValue,
        ]

        // Run through V.18a-4's privacy filter even though we're a
        // direct emitter (not the OTLP receive path). Defense in
        // depth — if a future maintainer adds a sensitive attribute
        // here, the `.metadata` mode drops it at write time, not
        // just at receive time. Cache_lifecycle attributes contain
        // no sensitive prefixes so the filter passes them through
        // unmodified (acceptance bullet #2).
        let filtered = OTLPPrivacyFilter.filter(
            attributes: rawAttributes,
            mode: .metadata
        )
        let attributesJson = OTLPPrivacyFilter.encodeJSON(filtered)

        // Trace + span identity. Derive trace_id from sessionID for
        // OTLP trace continuity (one trace spans the lifetime of a
        // session's cache); span_id is unique per emit via the
        // start-ns timestamp suffix.
        let traceId = sessionID.uuidString.lowercased()
        let spanId = "\(eventType.rawValue)-\(endNs)"
        let sessionIdString = traceId

        let span = RuntimeTelemetryStore.SpanRow(
            traceId: traceId,
            spanId: spanId,
            name: "\(Self.spanNamePrefix).\(eventType.rawValue)",
            startUnixNs: startNs,
            endUnixNs: endNs,
            attributesJson: attributesJson,
            sessionId: sessionIdString,
            toolCallId: toolCallID
        )

        return store.insertSpan(datasetId: datasetId, span: span)
    }
}
