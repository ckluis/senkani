import Testing
import Foundation
@testable import Core

/// V.18a-6 query-tool tests.
///
/// Covers the two acceptance bullets the round explicitly tests
/// (`tests_target: 2`):
///   1. `senkani_telemetry_query` enforces the row limit + cursor
///      resumes correctly across pages (acceptance bullet 2 + 5).
///   2. Oversize response truncated with cursor + SecretDetector
///      redaction in the output (acceptance bullets 4 + 5).
@Suite("TelemetryQueryTools (V.18a-6)")
struct TelemetryQueryToolsTests {

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-v18a-6-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "telemetry-query-\(UUID().uuidString).db"
    }

    private static func makeSpan(i: Int, sessionId: String, datasetSafe: Bool = true) -> RuntimeTelemetryStore.SpanRow {
        // datasetSafe=true → name + attributes contain no secret patterns
        // so SecretDetector pass-through is detectable byte-for-byte.
        let name = datasetSafe ? "validation.step.\(i)" : "leak.\(i)"
        let attrs = datasetSafe
            ? "{\"axis\":\"perf\",\"i\":\(i)}"
            : "{\"key\":\"sk-ant-api01-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"i\":\(i)}"
        return RuntimeTelemetryStore.SpanRow(
            traceId: "trace-\(i)",
            spanId: "span-\(i)",
            parentSpanId: nil,
            name: name,
            startUnixNs: Int64(i * 1000),
            endUnixNs: Int64(i * 1000 + 100),
            attributesJson: attrs,
            statusCode: 1,
            sessionId: sessionId,
            toolCallId: "tc-\(i)",
            validationRunId: "run-\(i)"
        )
    }

    // MARK: - Acceptance 2 + 5: row limit + cursor pagination

    @Test("query enforces limit + cursor resumes the next page deterministically")
    func queryLimitAndCursor() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        let store = session.runtimeTelemetryStore!
        let datasetId = store.createDataset(projectId: "p", workstreamId: nil)
        // Write 7 spans tagged with the same session_id.
        for i in 0..<7 {
            store.insertSpan(datasetId: datasetId, span: Self.makeSpan(i: i, sessionId: "s-page"))
        }

        // Page 1: limit=3 → 3 rows + cursor present + truncated_by:row_limit.
        var filter = RuntimeTelemetryStore.QueryFilter()
        filter.sessionId = "s-page"

        let page1 = try TelemetryQueryDispatcher.query(
            store: store, filter: filter, limit: 3, cursorAfterId: nil
        )
        #expect(page1.spans.count == 3)
        #expect(page1.next_cursor != nil)
        #expect(page1.truncated_by == .rowLimit)
        let cursor1 = try #require(page1.next_cursor)

        // Page 2: same filter, cursor = cursor1, limit=3 → 3 more.
        let page2 = try TelemetryQueryDispatcher.query(
            store: store, filter: filter, limit: 3, cursorAfterId: cursor1
        )
        #expect(page2.spans.count == 3)
        #expect(page2.next_cursor != nil)
        #expect(page2.truncated_by == .rowLimit)
        let cursor2 = try #require(page2.next_cursor)

        // Page 3: final row, cursor = cursor2 → 1 row + no cursor + no truncation.
        let page3 = try TelemetryQueryDispatcher.query(
            store: store, filter: filter, limit: 3, cursorAfterId: cursor2
        )
        #expect(page3.spans.count == 1)
        #expect(page3.next_cursor == nil)
        #expect(page3.truncated_by == nil)

        // Cursor monotonicity: page1.last.id < cursor1 == cursor1; page2.first.id > cursor1.
        let p1LastId = try #require(page1.spans.last?.id)
        #expect(p1LastId == cursor1)
        let p2FirstId = try #require(page2.spans.first?.id)
        #expect(p2FirstId > cursor1)

        // Empty filter is refused.
        let emptyFilter = RuntimeTelemetryStore.QueryFilter()
        do {
            _ = try TelemetryQueryDispatcher.query(store: store, filter: emptyFilter)
            Issue.record("emptyFilter should throw .emptyFilter")
        } catch TelemetryQueryDispatcher.DispatchError.emptyFilter {
            // expected
        }
    }

    // MARK: - Acceptance 4 + 5: byte budget + SecretDetector redaction

    @Test("oversize response truncated with byte budget + SecretDetector redacts secret-bearing attribute payloads")
    func byteBudgetAndSecretRedaction() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        let store = session.runtimeTelemetryStore!
        let datasetId = store.createDataset(projectId: "p", workstreamId: nil)

        // Write 5 spans with payloads that smuggle an Anthropic API key
        // in the attributes JSON. Each row's serialised JSON is around
        // ~250 bytes (the key alone is 108 chars).
        for i in 0..<5 {
            store.insertSpan(datasetId: datasetId, span: Self.makeSpan(i: i, sessionId: "s-leak", datasetSafe: false))
        }

        var filter = RuntimeTelemetryStore.QueryFilter()
        filter.sessionId = "s-leak"

        // Tight byte budget — should admit 2 rows then truncate.
        let response = try TelemetryQueryDispatcher.query(
            store: store, filter: filter, limit: 100, cursorAfterId: nil, maxResponseBytes: 500
        )
        #expect(response.spans.count >= 1)
        #expect(response.spans.count < 5)
        #expect(response.next_cursor != nil)
        #expect(response.truncated_by == .byteBudget)

        // SecretDetector contract: every emitted span's attributes_json
        // must NOT contain the raw key, and MUST contain the redaction
        // marker for Anthropic keys.
        for entry in response.spans {
            let attrs = try #require(entry.attributes_json)
            #expect(!attrs.contains("sk-ant-api01-AAAAA"))
            #expect(attrs.contains("[REDACTED:ANTHROPIC_API_KEY]"))
        }

        // Next page resumes from cursor and continues redacting.
        let next = try TelemetryQueryDispatcher.query(
            store: store, filter: filter, limit: 100,
            cursorAfterId: response.next_cursor, maxResponseBytes: 500
        )
        #expect(next.spans.count >= 1)
        let firstNext = try #require(next.spans.first)
        #expect(firstNext.id > response.next_cursor!)
        let attrsNext = try #require(firstNext.attributes_json)
        #expect(!attrsNext.contains("sk-ant-api01-AAAAA"))
        #expect(attrsNext.contains("[REDACTED:ANTHROPIC_API_KEY]"))
    }
}
