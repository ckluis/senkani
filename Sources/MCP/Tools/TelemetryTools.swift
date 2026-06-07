import Foundation
import MCP
import Core

/// V.18a-6 — three read-only MCP tools wrapping
/// `TelemetryQueryDispatcher`. Shapes mirror the dispatcher's Response
/// structs verbatim. Output bytes match the `senkani telemetry` CLI
/// subcommands (byte-stable JSON via `[.sortedKeys,
/// .withoutEscapingSlashes]`).
public enum TelemetryListTool {
    static func handle(arguments args: [String: Value]?, session _: MCPSession) async -> CallTool.Result {
        let projectId = args?["project_id"]?.stringValue
        let store = SessionDatabase.shared.runtimeTelemetryStore!
        let response = TelemetryQueryDispatcher.list(store: store, projectId: projectId)
        let bytes = (try? TelemetryQueryDispatcher.encodeJSON(response)) ?? Data()
        let body = String(data: bytes, encoding: .utf8) ?? "{}"
        return .init(content: [.text(text: body, annotations: nil, _meta: nil)])
    }
}

public enum TelemetryQueryTool {
    static func handle(arguments args: [String: Value]?, session _: MCPSession) async -> CallTool.Result {
        var filter = RuntimeTelemetryStore.QueryFilter()
        if let v = args?["dataset_id"]?.intValue { filter.datasetId = Int64(v) }
        if let v = args?["trace_id"]?.stringValue { filter.traceId = v }
        if let v = args?["session_id"]?.stringValue { filter.sessionId = v }
        if let v = args?["tool_call_id"]?.stringValue { filter.toolCallId = v }
        if let v = args?["validation_run_id"]?.stringValue { filter.validationRunId = v }
        if let v = args?["start_unix_ns_at_or_after"]?.intValue { filter.startUnixNsAtOrAfter = Int64(v) }
        if let v = args?["end_unix_ns_at_or_before"]?.intValue { filter.endUnixNsAtOrBefore = Int64(v) }
        let limit = args?["limit"]?.intValue ?? TelemetryQueryDispatcher.defaultRowLimit
        let cursor: Int64? = (args?["cursor"]?.intValue).map(Int64.init)

        let store = SessionDatabase.shared.runtimeTelemetryStore!
        do {
            let response = try TelemetryQueryDispatcher.query(
                store: store, filter: filter, limit: limit, cursorAfterId: cursor
            )
            let bytes = (try? TelemetryQueryDispatcher.encodeJSON(response)) ?? Data()
            let body = String(data: bytes, encoding: .utf8) ?? "{}"
            return .init(content: [.text(text: body, annotations: nil, _meta: nil)])
        } catch TelemetryQueryDispatcher.DispatchError.emptyFilter {
            return .init(content: [.text(
                text: "error: senkani_telemetry_query requires at least one filter (trace_id / session_id / tool_call_id / validation_run_id / dataset_id / start_unix_ns_at_or_after / end_unix_ns_at_or_before)",
                annotations: nil, _meta: nil)],
                isError: true)
        } catch {
            return .init(content: [.text(text: "error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}

public enum TelemetryGetTraceTool {
    static func handle(arguments args: [String: Value]?, session _: MCPSession) async -> CallTool.Result {
        guard let traceId = args?["trace_id"]?.stringValue, !traceId.isEmpty else {
            return .init(content: [.text(text: "error: senkani_telemetry_get_trace requires trace_id",
                                          annotations: nil, _meta: nil)], isError: true)
        }
        let maxSpans = args?["max_spans"]?.intValue ?? TelemetryQueryDispatcher.defaultTraceMaxSpans

        let store = SessionDatabase.shared.runtimeTelemetryStore!
        let response = TelemetryQueryDispatcher.getTrace(store: store, traceId: traceId, maxSpans: maxSpans)
        let bytes = (try? TelemetryQueryDispatcher.encodeJSON(response)) ?? Data()
        let body = String(data: bytes, encoding: .utf8) ?? "{}"
        return .init(content: [.text(text: body, annotations: nil, _meta: nil)])
    }
}
