import Testing
import Foundation
@testable import Core

/// V.18a-5 validation-source tests.
///
/// Covers the four acceptance bullets from
/// `spec/autonomous/backlog/phase-v18a-5-validation-source.md`:
///   1. `ValidationStore.insertValidationResult` records `validation_run_id`.
///   2. `BrowserValidationDispatcher.dispatch` emits a span tagged with
///      the run id + session/tool-call tuple.
///   3. Validation-failure → trace-summary attach: top-3 slowest +
///      error count + total duration; pass-results case returns nil.
///   4. Cross-cutting JOIN `agent_trace_event × runtime_telemetry_span`
///      on `(session_id, tool_call_id)` returns the matched pair.
@Suite("RuntimeTelemetryValidationSource (V.18a-5)")
struct RuntimeTelemetryValidationSourceTests {

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-v18a-5-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "validation-source-\(UUID().uuidString).db"
    }

    // MARK: - Acceptance 1: validation_run_id round-trips

    @Test("ValidationStore.insertValidationResult records validation_run_id")
    func validationRunIdRoundTrip() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        let runId = "test-run-\(UUID().uuidString)"
        session.insertValidationResult(
            sessionId: "session-a",
            filePath: "/work/file.swift",
            validatorName: "swift-format",
            category: "format",
            exitCode: 1,
            rawOutput: "trailing whitespace",
            advisory: "Please reformat.",
            durationMs: 42,
            outcome: "advisory",
            reason: nil,
            validationRunId: runId
        )
        session.flushWrites()

        let resultId = try #require(session.mostRecentValidationResultId(sessionId: "session-a"))
        #expect(session.validationRunId(forResultId: resultId) == runId)

        // Backward compat: the old call shape (no validationRunId) still works.
        session.insertValidationResult(
            sessionId: "session-b",
            filePath: "/work/other.swift",
            validatorName: "swift-format",
            category: "format",
            exitCode: 0,
            rawOutput: nil,
            advisory: "",
            durationMs: 9
        )
        session.flushWrites()
        let bId = try #require(session.mostRecentValidationResultId(sessionId: "session-b"))
        #expect(session.validationRunId(forResultId: bId) == nil)
    }

    // MARK: - Acceptance 2: dispatcher emits span tagged with run id

    @Test("BrowserValidationDispatcher.dispatch emits a span tagged with validation_run_id")
    func dispatchEmitsTaggedSpan() throws {
        let request = BrowserValidationDispatcher.Request(
            targetURL: "http://127.0.0.1:8080/",
            axes: [.perf],
            diff: nil,
            allowFailed: false,
            screenshot: false,
            sessionId: "session-c",
            projectRoot: nil,
            dispatch: .subprocess,
            egressProxyURL: nil,
            toolCallId: "call-c-1"
        )
        // Deterministic runner — returns a pass; no subprocess spawn.
        let runner: BrowserValidationDispatcher.Runner = { _, _, _, _ in
            PlaywrightResult(
                resultStatus: "pass",
                axesRun: ["perf"],
                assertionsPassed: 1,
                assertionsFailed: 0
            )
        }
        // Capture the side-effects.
        let captured = TestBox<[BrowserValidationDispatcher.DispatchSpan]>(value: [])
        let resultRows = TestBox<[BrowserValidationDispatcher.BrowserValidationRow]>(value: [])
        let resultSink: BrowserValidationDispatcher.ResultSink = { row in
            resultRows.value.append(row)
        }
        let spanSink: BrowserValidationDispatcher.SpanSink = { span in
            captured.value.append(span)
        }
        _ = try BrowserValidationDispatcher.dispatch(
            request: request,
            runner: runner,
            resultSink: resultSink,
            tokenEventSink: { _ in },
            spanSink: spanSink
        )

        #expect(captured.value.count == 1)
        let span = try #require(captured.value.first)
        #expect(span.sessionId == "session-c")
        #expect(span.toolCallId == "call-c-1")
        #expect(span.name == "validation.dispatch")
        #expect(span.statusCode == 1)               // pass → OTLP Ok
        #expect(span.validationRunId.count >= 32)   // UUID string

        // The dispatched result row carries the same id so the
        // resultSink wiring (production: insertBrowserValidationResult)
        // can persist it as the JOIN key on validation_results.
        #expect(resultRows.value.count == 1)
        #expect(resultRows.value[0].validationRunId == span.validationRunId)
        #expect(resultRows.value[0].toolCallId == "call-c-1")

        // Attributes JSON carries metadata, no payload (Schneier).
        #expect(span.attributesJson.contains("\"axes_run\":[\"perf\"]"))
        #expect(span.attributesJson.contains("\"result_status\":\"pass\""))
        #expect(!span.attributesJson.contains("/127.0.0.1"))  // no target URL leak
    }

    // MARK: - Acceptance 3: failure-summary attach (and pass-results case)

    @Test("traceSummary returns top-3 slowest + error count for a failed run; nil for empty")
    func failureSummaryShape() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        let store = session.runtimeTelemetryStore!
        let datasetId = store.createDataset(projectId: "p", workstreamId: nil)

        let runId = "run-fail"
        // 5 spans: durations 100, 200, 300, 400, 500ns. Span 5 errored.
        for (i, dur) in [100, 200, 300, 400, 500].enumerated() {
            let status: Int? = (i == 4) ? 2 : 1
            store.insertSpan(datasetId: datasetId, span: RuntimeTelemetryStore.SpanRow(
                traceId: "trace-fail",
                spanId: "span-\(i)",
                parentSpanId: nil,
                name: "step-\(i)",
                startUnixNs: Int64(i * 1000),
                endUnixNs: Int64(i * 1000 + dur),
                attributesJson: nil,
                statusCode: status,
                sessionId: "s-fail",
                toolCallId: "tc-fail",
                validationRunId: runId
            ))
        }

        let summary = try #require(store.traceSummary(validationRunId: runId))
        #expect(summary.validationRunId == runId)
        #expect(summary.traceId == "trace-fail")
        #expect(summary.spanCount == 5)
        #expect(summary.errorCount == 1)
        #expect(summary.topSlowestSpans.count == 3)
        #expect(summary.topSlowestSpans.map(\.durationNs) == [500, 400, 300])
        // totalDurationNs = max(end) - min(start) = (4*1000 + 500) - 0 = 4500
        #expect(summary.totalDurationNs == 4500)

        // Pass-results case: no spans tagged with this id → nil summary.
        // V.18 acceptance bullet 5 ("pass results attach nothing").
        #expect(store.traceSummary(validationRunId: "no-such-run") == nil)
    }

    // MARK: - Acceptance 4: cross-cutting JOIN

    @Test("cross-cutting JOIN agent_trace_event × runtime_telemetry_span on (session_id, tool_call_id)")
    func crossCuttingJoinReturnsMatchedRows() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        let store = session.runtimeTelemetryStore!
        let datasetId = store.createDataset(projectId: "p", workstreamId: nil)

        // Write two agent_trace_event rows + spans:
        //  - (s1,t1) is paired → must JOIN
        //  - (s1,t2) has trace but no matching span → no JOIN row
        //  - span with (s9,t9) has no trace row → no JOIN row
        let now = Date()
        session.recordAgentTraceEvent(AgentTraceEvent(
            idempotencyKey: "idem-1",
            project: "p",
            result: .success,
            startedAt: now,
            completedAt: now.addingTimeInterval(0.05),
            sessionId: "s1",
            toolCallId: "t1"
        ))
        session.recordAgentTraceEvent(AgentTraceEvent(
            idempotencyKey: "idem-2",
            project: "p",
            result: .success,
            startedAt: now,
            completedAt: now.addingTimeInterval(0.05),
            sessionId: "s1",
            toolCallId: "t2"
        ))
        // Pre-v32 / non-routed row — session_id NULL — must NOT match.
        session.recordAgentTraceEvent(AgentTraceEvent(
            idempotencyKey: "idem-3",
            project: "p",
            result: .success,
            startedAt: now,
            completedAt: now.addingTimeInterval(0.05)
        ))

        store.insertSpan(datasetId: datasetId, span: RuntimeTelemetryStore.SpanRow(
            traceId: "trace-A",
            spanId: "span-A",
            parentSpanId: nil,
            name: "validation.dispatch",
            startUnixNs: 1000,
            endUnixNs: 1500,
            attributesJson: nil,
            statusCode: 1,
            sessionId: "s1",
            toolCallId: "t1",
            validationRunId: "run-A"
        ))
        store.insertSpan(datasetId: datasetId, span: RuntimeTelemetryStore.SpanRow(
            traceId: "trace-B",
            spanId: "span-B",
            parentSpanId: nil,
            name: "validation.dispatch",
            startUnixNs: 2000,
            endUnixNs: 2500,
            attributesJson: nil,
            statusCode: 1,
            sessionId: "s9",
            toolCallId: "t9",
            validationRunId: "run-B"
        ))
        session.flushWrites()

        // Scoped JOIN: just the (s1,t1) pair.
        let scopedRows = store.crossCuttingTraceJoin(sessionId: "s1", toolCallId: "t1")
        #expect(scopedRows.count == 1)
        let r = try #require(scopedRows.first)
        #expect(r.idempotencyKey == "idem-1")
        #expect(r.sessionId == "s1")
        #expect(r.toolCallId == "t1")
        #expect(r.spanId == "span-A")
        #expect(r.traceId == "trace-A")
        #expect(r.durationNs == 500)
        #expect(r.statusCode == 1)

        // Unscoped JOIN returns only the paired row — the trace-only
        // and span-only rows correctly don't match. (s1,t2) has a
        // trace row but no span; (s9,t9) has a span but no trace.
        let allRows = store.crossCuttingTraceJoin()
        #expect(allRows.count == 1)
        #expect(allRows.first?.idempotencyKey == "idem-1")
    }

    /// Tiny reference-cell wrapper so the closure sinks can mutate state
    /// without escaping-`var` warnings. Sendable because we never share
    /// the box across threads — closures are called synchronously
    /// inside `dispatch`.
    private final class TestBox<T>: @unchecked Sendable {
        var value: T
        init(value: T) { self.value = value }
    }
}
