import Foundation

/// V.18a-7 — correlates `token_events` timeline rows to
/// `runtime_telemetry_span` rows so the Agent Timeline pane can
/// badge rows whose underlying spans went ERROR or ran past p99.
///
/// The correlator is pure-Swift and takes a span-fetcher closure
/// so it tests without a live SQLite store. The Timeline pane
/// passes a closure that wraps `RuntimeTelemetryStore.querySpans`.
///
/// Schneier acceptance (V.18a-7 bullet 4): the compact summary
/// surfaced inline contains ONLY aggregate counts + a capped
/// slow-span name+duration list. The full span tree (parent/child
/// edges, attributes_json, status messages) is NEVER materialised
/// here — the side pane fetches it on demand via
/// `TelemetryQueryDispatcher.getTrace` only when the operator
/// explicitly clicks through.
public enum TimelineTelemetryCorrelator {

    /// Per-row badge metadata. `none` means no correlated spans
    /// hit ERROR or p99; the row renders without a badge.
    public enum BadgeTier: Sendable, Equatable {
        case none
        /// At least one span with `status_code = ERROR` matched.
        case error
        /// No ERROR span but at least one span with
        /// `duration > p99` of the surrounding window.
        case slow
    }

    /// Compact, summary-only payload for the inline expansion.
    /// **Contains no span objects.** The side pane fetches the
    /// full tree on demand via `getTrace`.
    public struct CompactSummary: Sendable, Equatable {
        /// Span name + duration in milliseconds. Capped at 5
        /// entries; the side pane carries the rest.
        public let slowSpans: [SlowSpan]
        /// Count of spans whose status_code = ERROR.
        public let errorCount: Int
        /// Sum of every correlated span's duration, in ms.
        public let totalDurationMs: Int
        /// First trace_id in the correlation set. The side pane
        /// uses this to call `getTrace`. Nil when no spans matched.
        public let primaryTraceId: String?

        public struct SlowSpan: Sendable, Equatable {
            public let name: String
            public let durationMs: Int
            public init(name: String, durationMs: Int) {
                self.name = name
                self.durationMs = durationMs
            }
        }

        public init(slowSpans: [SlowSpan], errorCount: Int, totalDurationMs: Int, primaryTraceId: String?) {
            self.slowSpans = slowSpans
            self.errorCount = errorCount
            self.totalDurationMs = totalDurationMs
            self.primaryTraceId = primaryTraceId
        }
    }

    /// Combined per-row output: badge tier + compact summary.
    public struct RowCorrelation: Sendable, Equatable {
        public let badge: BadgeTier
        public let summary: CompactSummary
        public init(badge: BadgeTier, summary: CompactSummary) {
            self.badge = badge
            self.summary = summary
        }
    }

    /// Inputs the correlator needs per event. The Timeline pane
    /// derives these from `TimelineEvent.sessionId` today;
    /// future schema work (v0.4.x) may add `toolCallId` /
    /// `validationRunId` to `token_events`, in which case those
    /// keys flow through unchanged.
    public struct EventKeys: Sendable, Equatable {
        public let eventId: Int64
        public let sessionId: String?
        public let toolCallId: String?
        public let validationRunId: String?
        public init(eventId: Int64, sessionId: String?, toolCallId: String? = nil, validationRunId: String? = nil) {
            self.eventId = eventId
            self.sessionId = sessionId
            self.toolCallId = toolCallId
            self.validationRunId = validationRunId
        }
        var hasAnyKey: Bool {
            return sessionId != nil || toolCallId != nil || validationRunId != nil
        }
    }

    /// Maximum number of slow-span entries surfaced in the
    /// inline compact summary. The side pane carries the rest.
    public static let maxSlowSpansInline = 5

    /// Build correlations for `events` given `spans` already
    /// fetched from `RuntimeTelemetryStore`. Pure: no I/O.
    ///
    /// p99 is computed across the *spans we received*, not the
    /// events — the acceptance phrase "p99 of the surrounding
    /// 100-row window" maps to "p99 of the span durations across
    /// the spans correlated to the visible 100-row timeline
    /// window." Window size N spans, N can be < 100 when traffic
    /// is light; we degrade gracefully (no slow flag when N < 10).
    public static func correlate(
        events: [EventKeys],
        spans: [RuntimeTelemetryStore.SpanResult]
    ) -> [Int64: RowCorrelation] {
        let p99 = p99DurationNs(spans: spans)

        // Pre-index spans by their three candidate join keys.
        // Each span may go into multiple buckets when it carries
        // session_id + tool_call_id + validation_run_id; the
        // dedupe at correlation time uses span.id.
        var bySession: [String: [RuntimeTelemetryStore.SpanResult]] = [:]
        var byToolCall: [String: [RuntimeTelemetryStore.SpanResult]] = [:]
        var byValidationRun: [String: [RuntimeTelemetryStore.SpanResult]] = [:]
        for span in spans {
            if let s = span.sessionId { bySession[s, default: []].append(span) }
            if let t = span.toolCallId { byToolCall[t, default: []].append(span) }
            if let v = span.validationRunId { byValidationRun[v, default: []].append(span) }
        }

        var out: [Int64: RowCorrelation] = [:]
        for ev in events {
            guard ev.hasAnyKey else { continue }
            var matched: [Int64: RuntimeTelemetryStore.SpanResult] = [:]
            if let s = ev.sessionId, let hits = bySession[s] {
                for sp in hits { matched[sp.id] = sp }
            }
            if let t = ev.toolCallId, let hits = byToolCall[t] {
                for sp in hits { matched[sp.id] = sp }
            }
            if let v = ev.validationRunId, let hits = byValidationRun[v] {
                for sp in hits { matched[sp.id] = sp }
            }
            if matched.isEmpty { continue }
            let dedup = Array(matched.values)
            let summary = buildSummary(spans: dedup, p99Ns: p99)
            let badge = badgeTier(spans: dedup, p99Ns: p99)
            out[ev.eventId] = RowCorrelation(badge: badge, summary: summary)
        }
        return out
    }

    /// Compact summary builder. Caps the slow-span list at
    /// `maxSlowSpansInline` and sorts by duration DESC. The
    /// `primaryTraceId` is the first trace_id seen in the matched
    /// span set — the side pane uses it to call `getTrace`.
    static func buildSummary(
        spans: [RuntimeTelemetryStore.SpanResult],
        p99Ns: Int64?
    ) -> CompactSummary {
        let errorCount = spans.reduce(0) { $0 + ((($1.statusCode ?? 0) == 2) ? 1 : 0) }
        let totalDurationMs = Int(spans.reduce(0) { $0 + max(0, $1.endUnixNs - $1.startUnixNs) } / 1_000_000)
        let slowThresholdNs: Int64 = p99Ns ?? Int64.max
        let slow = spans
            .filter { (($0.statusCode ?? 0) == 2) || ($0.endUnixNs - $0.startUnixNs) > slowThresholdNs }
            .sorted { ($0.endUnixNs - $0.startUnixNs) > ($1.endUnixNs - $1.startUnixNs) }
            .prefix(maxSlowSpansInline)
            .map { sp in
                CompactSummary.SlowSpan(
                    name: sp.name,
                    durationMs: Int(max(0, sp.endUnixNs - sp.startUnixNs) / 1_000_000)
                )
            }
        let primaryTraceId = spans.sorted { $0.startUnixNs < $1.startUnixNs }.first?.traceId
        return CompactSummary(
            slowSpans: Array(slow),
            errorCount: errorCount,
            totalDurationMs: totalDurationMs,
            primaryTraceId: primaryTraceId
        )
    }

    /// Map a matched span set to a badge tier. ERROR-status_code
    /// wins over slow; absence of either yields `.none`.
    static func badgeTier(
        spans: [RuntimeTelemetryStore.SpanResult],
        p99Ns: Int64?
    ) -> BadgeTier {
        if spans.contains(where: { ($0.statusCode ?? 0) == 2 }) {
            return .error
        }
        if let p99 = p99Ns,
           spans.contains(where: { ($0.endUnixNs - $0.startUnixNs) > p99 }) {
            return .slow
        }
        return .none
    }

    /// Compute p99 of the span-duration distribution. Returns
    /// nil when the window is too small (< 10 spans) — flagging
    /// 1 of 5 spans as "above p99" is noise, not signal.
    ///
    /// Uses `idx = floor(N * 0.99) - 1` so the threshold is the
    /// boundary *below* which 99% of spans fall. A "strict above"
    /// comparison (`duration > p99`) then surfaces the top-1%
    /// outliers — including the maximum itself, which a naïve
    /// `idx = floor(N * 0.99)` (which lands on the max) would
    /// otherwise hide.
    static func p99DurationNs(spans: [RuntimeTelemetryStore.SpanResult]) -> Int64? {
        guard spans.count >= 10 else { return nil }
        let durations = spans.map { max(0, $0.endUnixNs - $0.startUnixNs) }.sorted()
        let idx = max(0, Int(Double(durations.count) * 0.99) - 1)
        return durations[idx]
    }
}
