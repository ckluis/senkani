import Foundation

/// V.18a-6 — shared dispatcher for the three read-only query surfaces:
/// `senkani_telemetry_list`, `senkani_telemetry_query`,
/// `senkani_telemetry_get_trace`. Both the MCP tool layer and the CLI
/// `senkani telemetry` subcommand call into here so output bytes are
/// identical (matches the V.18a-4 dispatcher precedent for
/// `validate_browser`).
///
/// Output routing satisfies V.18a-6 acceptance bullet 4:
///   - Every text field that could carry a leaked secret (span `name`,
///     `attributes_json`, `parent_span_id`, `session_id`, `tool_call_id`,
///     `validation_run_id`) is run through `SecretDetector.scan` before
///     emission. The redacted text replaces the original.
///   - Trace_id / span_id stay verbatim — they're random hex ids, not
///     user-supplied data, and the byte budget needs them to be stable.
///   - Numeric columns pass through (no leak surface).
///
/// Byte/row budgets satisfy V.18a-6 acceptance bullets 2 + 5:
///   - `querySpans` returns at most `limit` rows AND at most
///     `maxResponseBytes` of serialised payload. The function tallies
///     accumulated JSON size while iterating; when adding the next
///     row would exceed either cap, it returns a `nextCursor` keyed
///     on the last admitted row id.
///   - The cursor is the row's `id`. Next-page query passes
///     `cursorAfterId: <returned>` to resume.
///   - `getTrace` caps at `maxSpans` (default 10K) but does NOT page —
///     a trace is one unit; if it exceeds the cap, the dispatcher
///     truncates with an explicit `truncated: true` field and the
///     caller is expected to re-query with a tighter filter rather
///     than paginate inside one trace.
public enum TelemetryQueryDispatcher {

    /// V.18a-6 — `senkani_telemetry_query` default limit. Lower than
    /// the store's 1000 ceiling so a stray caller without a `limit:`
    /// parameter still gets a bounded response. The MCP/CLI layer
    /// clamps caller-supplied values into [1, 1000].
    public static let defaultRowLimit = 100

    /// V.18a-6 — per-page byte budget (1 MB) per the V.18 parent's
    /// scope decision. Tallied as the serialised UTF-8 length of the
    /// JSON-encoded span objects (excluding the outer envelope).
    public static let defaultMaxResponseBytes = 1_024 * 1_024

    /// V.18a-6 — `senkani_telemetry_get_trace` span cap (10K) per the
    /// parent's scope: "fetch single trace's full span tree (max 10K
    /// spans)."
    public static let defaultTraceMaxSpans = 10_000

    // MARK: - list

    /// JSON envelope for `senkani_telemetry_list`. Encoded with
    /// `[.sortedKeys, .withoutEscapingSlashes]` so MCP + CLI bytes
    /// match.
    public struct ListResponse: Codable, Sendable, Equatable {
        public let datasets: [DatasetEntry]
        public struct DatasetEntry: Codable, Sendable, Equatable {
            public let id: Int64
            public let project_id: String
            public let workstream_id: String?
            public let created_at: Int64
            public let bytes_used: Int
            public let span_count: Int
            public let log_count: Int
        }
    }

    /// Dispatch `senkani_telemetry_list`. `projectId` nil → every row.
    public static func list(store: RuntimeTelemetryStore, projectId: String?) -> ListResponse {
        let rows = store.listDatasets(projectId: projectId)
        let entries = rows.map { row in
            ListResponse.DatasetEntry(
                id: row.id,
                project_id: row.projectId,
                workstream_id: row.workstreamId,
                created_at: row.createdAt,
                bytes_used: row.bytesUsed,
                span_count: row.spanCount,
                log_count: row.logCount
            )
        }
        return ListResponse(datasets: entries)
    }

    // MARK: - query

    /// JSON envelope for `senkani_telemetry_query`. `next_cursor`
    /// non-nil means the result was truncated by row or byte budget;
    /// the caller re-queries with the same filter plus
    /// `cursor: <next_cursor>` to fetch the next page. Cursor is the
    /// last admitted row's `id`.
    public struct QueryResponse: Codable, Sendable, Equatable {
        public let spans: [SpanEntry]
        public let next_cursor: Int64?
        public let truncated_by: TruncationReason?
        public struct SpanEntry: Codable, Sendable, Equatable {
            public let id: Int64
            public let dataset_id: Int64
            public let trace_id: String
            public let span_id: String
            public let parent_span_id: String?
            public let name: String
            public let start_unix_ns: Int64
            public let end_unix_ns: Int64
            public let attributes_json: String?
            public let status_code: Int?
            public let session_id: String?
            public let tool_call_id: String?
            public let validation_run_id: String?
        }
        public enum TruncationReason: String, Codable, Sendable, Equatable {
            case rowLimit = "row_limit"
            case byteBudget = "byte_budget"
        }
    }

    /// Errors raised at the dispatcher boundary. Caller-supplied
    /// invalid inputs throw; runtime SQLite failures degrade to an
    /// empty result rather than throw (matches the rest of the
    /// store).
    public enum DispatchError: Error, Equatable {
        case emptyFilter
    }

    /// Dispatch `senkani_telemetry_query`. Clamps `limit` into
    /// `[1, 1000]`; rejects an empty filter with `.emptyFilter`
    /// (Schneier: refuse blind scans).
    public static func query(
        store: RuntimeTelemetryStore,
        filter: RuntimeTelemetryStore.QueryFilter,
        limit: Int = defaultRowLimit,
        cursorAfterId: Int64? = nil,
        maxResponseBytes: Int = defaultMaxResponseBytes
    ) throws -> QueryResponse {
        guard filter.hasAnyFilter else { throw DispatchError.emptyFilter }
        let clamped = max(1, min(1000, limit))
        // Fetch up to clamped + 1 so we can detect that more rows
        // exist beyond the row limit and emit a cursor without a
        // second probe query.
        let probeLimit = clamped + 1
        let raw = store.querySpans(filter: filter, limit: probeLimit, cursorAfterId: cursorAfterId)

        var admitted: [QueryResponse.SpanEntry] = []
        var accumulatedBytes = 0
        var byteBudgetHit = false
        for (i, span) in raw.enumerated() {
            if i >= clamped { break }            // row limit reached
            let entry = redactedEntry(from: span)
            let serialised = (try? encodeSortedJson(entry)) ?? Data()
            if accumulatedBytes + serialised.count > maxResponseBytes && !admitted.isEmpty {
                byteBudgetHit = true
                break
            }
            admitted.append(entry)
            accumulatedBytes += serialised.count
        }
        let truncated: QueryResponse.TruncationReason?
        let nextCursor: Int64?
        if byteBudgetHit {
            truncated = .byteBudget
            nextCursor = admitted.last.map(\.id)
        } else if raw.count > clamped {
            truncated = .rowLimit
            nextCursor = admitted.last.map(\.id)
        } else {
            truncated = nil
            nextCursor = nil
        }
        return QueryResponse(spans: admitted, next_cursor: nextCursor, truncated_by: truncated)
    }

    // MARK: - get_trace

    /// JSON envelope for `senkani_telemetry_get_trace`. `truncated`
    /// true means the trace exceeded `maxSpans`; the caller should
    /// re-query with a tighter `start_unix_ns` window rather than
    /// paginating inside one trace.
    public struct TraceResponse: Codable, Sendable, Equatable {
        public let trace_id: String
        public let spans: [QueryResponse.SpanEntry]
        public let truncated: Bool
    }

    /// Dispatch `senkani_telemetry_get_trace`. Caller supplies a
    /// `trace_id`; cap is `maxSpans` (default 10K).
    public static func getTrace(
        store: RuntimeTelemetryStore,
        traceId: String,
        maxSpans: Int = defaultTraceMaxSpans
    ) -> TraceResponse {
        // Fetch up to maxSpans + 1 to detect the truncation case
        // without a second probe.
        let probe = store.spansForTrace(traceId: traceId, maxSpans: maxSpans + 1)
        let truncated = probe.count > maxSpans
        let admitted = (truncated ? Array(probe.prefix(maxSpans)) : probe)
            .map(redactedEntry(from:))
        return TraceResponse(trace_id: traceId, spans: admitted, truncated: truncated)
    }

    // MARK: - Encoding helpers

    /// Encode a Codable value as byte-stable JSON. Used by MCP + CLI
    /// to emit identical bytes for the same input. Throws on
    /// encoding failure.
    public static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Local alias kept for clarity at the budget-checking site.
    private static func encodeSortedJson<T: Encodable>(_ value: T) throws -> Data {
        try encodeJSON(value)
    }

    /// Route every secret-bearing text field through `SecretDetector`.
    /// Numeric + random-id columns (trace_id / span_id) pass through
    /// verbatim — `SecretDetector` regex doesn't fire on hex but
    /// scanning them costs and adds no value.
    private static func redactedEntry(from span: RuntimeTelemetryStore.SpanResult) -> QueryResponse.SpanEntry {
        return QueryResponse.SpanEntry(
            id: span.id,
            dataset_id: span.datasetId,
            trace_id: span.traceId,
            span_id: span.spanId,
            parent_span_id: span.parentSpanId.map { SecretDetector.scan($0).redacted },
            name: SecretDetector.scan(span.name).redacted,
            start_unix_ns: span.startUnixNs,
            end_unix_ns: span.endUnixNs,
            attributes_json: span.attributesJson.map { SecretDetector.scan($0).redacted },
            status_code: span.statusCode,
            session_id: span.sessionId.map { SecretDetector.scan($0).redacted },
            tool_call_id: span.toolCallId.map { SecretDetector.scan($0).redacted },
            validation_run_id: span.validationRunId.map { SecretDetector.scan($0).redacted }
        )
    }
}
