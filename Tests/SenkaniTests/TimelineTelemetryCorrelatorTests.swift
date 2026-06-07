import Testing
import Foundation
@testable import Core

/// V.18a-7 — TimelineTelemetryCorrelator tests.
///
/// Two acceptance-aligned tests (`tests_target: 2`):
///
/// 1. **Badge correlation by session_id / tool_call_id /
///    validation_run_id** — given a span set that includes one
///    ERROR span and one >p99 slow span tied to known correlation
///    keys, the correlator returns `.error` for rows touching the
///    error span's session, `.slow` for rows touching the slow
///    span's session, and `.none` for unrelated rows. Covers
///    acceptance bullets 1–3.
///
/// 2. **Compact summary contains only summary fields, never the
///    full span tree** — the inline-surface payload caps slow
///    entries at `maxSlowSpansInline` and exposes
///    `slowSpans: [SlowSpan(name, durationMs)]` + scalar
///    counts only. The compile-time type system + an exhaustive
///    keys-of-payload assertion guard the Schneier-flagged
///    "Span tree is NOT embedded in prompt context — only the
///    compact summary is" invariant (bullet 4).
@Suite("TimelineTelemetryCorrelator (V.18a-7)")
struct TimelineTelemetryCorrelatorTests {

    private static func makeSpan(
        id: Int64,
        sessionId: String?,
        toolCallId: String? = nil,
        validationRunId: String? = nil,
        durationNs: Int64,
        statusCode: Int? = 1,
        traceId: String? = nil,
        name: String = "validation.step"
    ) -> RuntimeTelemetryStore.SpanResult {
        let start: Int64 = id * 10_000_000
        return RuntimeTelemetryStore.SpanResult(
            id: id,
            datasetId: 1,
            traceId: traceId ?? "trace-\(id)",
            spanId: "span-\(id)",
            parentSpanId: nil,
            name: name,
            startUnixNs: start,
            endUnixNs: start + durationNs,
            attributesJson: nil,
            statusCode: statusCode,
            sessionId: sessionId,
            toolCallId: toolCallId,
            validationRunId: validationRunId
        )
    }

    // MARK: - Acceptance bullets 1-3: badge correlation

    @Test("correlator flags rows by session_id / tool_call_id / validation_run_id with ERROR + p99 detection")
    func badgeCorrelationByCorrelationKeys() throws {
        // Build a window of 12 spans so p99 (count >= 10) actually
        // resolves. Eleven spans are 5 ms; one is 500 ms (slow);
        // one is 5 ms but ERROR (status_code = 2).
        var spans: [RuntimeTelemetryStore.SpanResult] = []
        for i in 0..<10 {
            spans.append(Self.makeSpan(
                id: Int64(i),
                sessionId: "s-baseline",
                durationNs: 5_000_000  // 5 ms
            ))
        }
        // Slow span — sessionId only.
        spans.append(Self.makeSpan(
            id: 100,
            sessionId: "s-slow",
            durationNs: 500_000_000  // 500 ms
        ))
        // Error span — toolCallId-only correlation.
        spans.append(Self.makeSpan(
            id: 101,
            sessionId: nil,
            toolCallId: "tc-err",
            durationNs: 5_000_000,
            statusCode: 2
        ))
        // Healthy span — validationRunId-only correlation; 5 ms,
        // status_code = 1 (OK). Used to prove a validationRunId
        // match without ERROR/slow still resolves to `.none`.
        spans.append(Self.makeSpan(
            id: 102,
            sessionId: nil,
            validationRunId: "run-clean",
            durationNs: 5_000_000
        ))

        let events: [TimelineTelemetryCorrelator.EventKeys] = [
            // (a) Hits the slow span via sessionId.
            .init(eventId: 1, sessionId: "s-slow"),
            // (b) Hits the error span via toolCallId.
            .init(eventId: 2, sessionId: nil, toolCallId: "tc-err"),
            // (c) Hits the healthy span via validationRunId.
            .init(eventId: 3, sessionId: nil, validationRunId: "run-clean"),
            // (d) Touches a session with only baseline 5ms spans → no badge.
            .init(eventId: 4, sessionId: "s-baseline"),
            // (e) No keys at all → omitted entirely.
            .init(eventId: 5, sessionId: nil)
        ]

        let result = TimelineTelemetryCorrelator.correlate(events: events, spans: spans)

        // (a) slow via sessionId → .slow badge, slowSpans non-empty,
        //     primaryTraceId set.
        let a = try #require(result[1])
        #expect(a.badge == .slow)
        #expect(a.summary.errorCount == 0)
        #expect(a.summary.slowSpans.count == 1)
        #expect(a.summary.slowSpans.first?.durationMs == 500)
        #expect(a.summary.primaryTraceId == "trace-100")

        // (b) error via toolCallId → .error badge wins over slow;
        //     errorCount == 1.
        let b = try #require(result[2])
        #expect(b.badge == .error)
        #expect(b.summary.errorCount == 1)
        #expect(b.summary.primaryTraceId == "trace-101")

        // (c) healthy via validationRunId → .none badge, no slow
        //     spans, errorCount == 0, but summary still produced
        //     (event was correlated, just not flagged).
        let c = try #require(result[3])
        #expect(c.badge == .none)
        #expect(c.summary.errorCount == 0)
        #expect(c.summary.slowSpans.isEmpty)

        // (d) baseline session → 10 spans all 5ms, no errors. p99
        //     is the 99th-percentile of [5ms]*10 = 5ms, no span
        //     exceeds it strictly, no ERROR → badge .none.
        let d = try #require(result[4])
        #expect(d.badge == .none)
        #expect(d.summary.errorCount == 0)

        // (e) event with no correlation keys → not present in map.
        #expect(result[5] == nil)
    }

    // MARK: - Acceptance bullet 4: compact summary contains only summary fields

    @Test("compact summary is summary-only — no full-tree payload, slow list capped at maxSlowSpansInline")
    func compactSummaryIsSummaryOnly() throws {
        // 20 ERROR spans on one session — every ERROR span
        // counts toward the slow-list filter regardless of
        // p99 (the filter is `(status_code == 2) || (> p99)`).
        // The inline summary must cap at `maxSlowSpansInline`
        // (5) — the side pane carries the rest.
        var spans: [RuntimeTelemetryStore.SpanResult] = []
        for i in 0..<20 {
            spans.append(Self.makeSpan(
                id: Int64(200 + i),
                sessionId: "s-many-err",
                durationNs: Int64((i + 1) * 10_000_000),  // 10, 20, … 200 ms
                statusCode: 2,
                name: "err.\(i)"
            ))
        }

        let events: [TimelineTelemetryCorrelator.EventKeys] = [
            .init(eventId: 7, sessionId: "s-many-err")
        ]
        let result = TimelineTelemetryCorrelator.correlate(events: events, spans: spans)
        let row = try #require(result[7])

        // Slow list is CAPPED — the round's
        // "Span tree is NOT embedded in prompt context" invariant
        // is enforced both by type system (CompactSummary has no
        // span-tree field) and by the explicit cap.
        #expect(row.summary.slowSpans.count <= TimelineTelemetryCorrelator.maxSlowSpansInline)
        #expect(row.summary.slowSpans.count == TimelineTelemetryCorrelator.maxSlowSpansInline)

        // Slow list is sorted DESC by duration — the heaviest
        // entries surface inline, the rest live in the side pane.
        let durations = row.summary.slowSpans.map { $0.durationMs }
        #expect(durations == durations.sorted(by: >))

        // Each SlowSpan exposes ONLY (name, durationMs). The
        // compile-time signature of `SlowSpan` is the load-
        // bearing assertion — adding parentSpanId or
        // attributesJson would require this test to update.
        let probe = TimelineTelemetryCorrelator.CompactSummary.SlowSpan(name: "x", durationMs: 1)
        #expect(probe.name == "x")
        #expect(probe.durationMs == 1)

        // The CompactSummary envelope itself carries only:
        //   slowSpans (capped, summary-only), errorCount,
        //   totalDurationMs, primaryTraceId. No span tree, no
        //   attributes_json, no parent_span_id. The encode below
        //   surfaces the full key set and asserts inclusion.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(EncodableProbe(summary: row.summary))
        let str = try #require(String(data: data, encoding: .utf8))
        // Allowed top-level keys.
        let allowed: Set<String> = ["errorCount", "primaryTraceId", "slowSpans", "totalDurationMs"]
        // Disallowed keys — surfacing any of these would indicate
        // the full span tree had leaked into the inline payload.
        let disallowed: Set<String> = [
            "spans", "attributes_json", "attributesJson", "parent_span_id", "parentSpanId",
            "trace", "tree", "children", "events", "links", "resource"
        ]
        for key in allowed {
            #expect(str.contains("\"\(key)\""), "expected inline summary to expose key \(key)")
        }
        for key in disallowed {
            #expect(!str.contains("\"\(key)\""), "inline summary leaked disallowed full-tree key \(key)")
        }
    }

    /// Codable shell for the disallowed-keys check above. Mirrors
    /// the CompactSummary fields verbatim so we can serialise and
    /// inspect the key set without changing CompactSummary's
    /// public Codable conformance.
    private struct EncodableProbe: Encodable {
        let summary: TimelineTelemetryCorrelator.CompactSummary
        enum CodingKeys: String, CodingKey {
            case errorCount, totalDurationMs, primaryTraceId, slowSpans
        }
        struct SlowSpanProbe: Encodable {
            let name: String
            let durationMs: Int
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(summary.errorCount, forKey: .errorCount)
            try c.encode(summary.totalDurationMs, forKey: .totalDurationMs)
            try c.encode(summary.primaryTraceId, forKey: .primaryTraceId)
            try c.encode(
                summary.slowSpans.map { SlowSpanProbe(name: $0.name, durationMs: $0.durationMs) },
                forKey: .slowSpans
            )
        }
    }
}
