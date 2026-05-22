import ArgumentParser
import Core
import Foundation

/// V.18a-6 — `senkani telemetry <list|query|get-trace>` CLI surface.
/// Mirrors the three MCP tools; routes through
/// `TelemetryQueryDispatcher` so output bytes match
/// `senkani_telemetry_*` MCP tool output bytes.
///
/// Output format is byte-stable JSON (one record). Human-readable
/// formatting is intentionally NOT shipped this round — the operator-
/// facing surface for runtime telemetry is the Agent Timeline link
/// (V.18a-7). The CLI is a backstop / scripting aid.
struct Telemetry: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "telemetry",
        abstract: "Read-only query surface for runtime_telemetry spans.",
        subcommands: [List.self, Query.self, GetTrace.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List runtime_telemetry datasets, optionally scoped to a project."
        )

        @Option(name: [.customLong("project-id")], help: "Scope to one project. Omit for every dataset.")
        var projectId: String?

        mutating func run() throws {
            let store = SessionDatabase.shared.runtimeTelemetryStore!
            let response = TelemetryQueryDispatcher.list(store: store, projectId: projectId)
            try emit(response)
        }
    }

    struct Query: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "query",
            abstract: "Query runtime_telemetry spans by trace_id / session_id / tool_call_id / validation_run_id / time range. Cursor-paginated."
        )

        @Option(name: [.customLong("dataset-id")], help: "Scope to one dataset.")
        var datasetId: Int64?

        @Option(name: [.customLong("trace-id")], help: "Filter by OTLP trace_id.")
        var traceId: String?

        @Option(name: [.customLong("session-id")], help: "Filter by senkani session id.")
        var sessionId: String?

        @Option(name: [.customLong("tool-call-id")], help: "Filter by tool-call id.")
        var toolCallId: String?

        @Option(name: [.customLong("validation-run-id")], help: "Filter by V.18a-5 validation_run_id.")
        var validationRunId: String?

        @Option(name: [.customLong("start-ns-at-or-after")], help: "Lower bound on span start_unix_ns (inclusive).")
        var startNs: Int64?

        @Option(name: [.customLong("end-ns-at-or-before")], help: "Upper bound on span end_unix_ns (inclusive).")
        var endNs: Int64?

        @Option(name: .long, help: "Max rows per page (default 100, clamped to 1..1000).")
        var limit: Int = TelemetryQueryDispatcher.defaultRowLimit

        @Option(name: .long, help: "Resume after this row id (returned as next_cursor when a page is truncated).")
        var cursor: Int64?

        mutating func run() throws {
            var filter = RuntimeTelemetryStore.QueryFilter()
            filter.datasetId = datasetId
            filter.traceId = traceId
            filter.sessionId = sessionId
            filter.toolCallId = toolCallId
            filter.validationRunId = validationRunId
            filter.startUnixNsAtOrAfter = startNs
            filter.endUnixNsAtOrBefore = endNs

            let store = SessionDatabase.shared.runtimeTelemetryStore!
            do {
                let response = try TelemetryQueryDispatcher.query(
                    store: store, filter: filter, limit: limit, cursorAfterId: cursor
                )
                try emit(response)
            } catch TelemetryQueryDispatcher.DispatchError.emptyFilter {
                FileHandle.standardError.write(Data("error: senkani telemetry query requires at least one filter (--trace-id / --session-id / --tool-call-id / --validation-run-id / --dataset-id / --start-ns-at-or-after / --end-ns-at-or-before)\n".utf8))
                throw ExitCode.failure
            }
        }
    }

    struct GetTrace: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get-trace",
            abstract: "Fetch one trace's full span tree (ordered by start_unix_ns ASC; capped at 10K spans by default)."
        )

        @Option(name: [.customLong("trace-id")], help: "OTLP trace_id (hex string from a prior query / dispatch span emit).")
        var traceId: String

        @Option(name: [.customLong("max-spans")], help: "Cap on returned spans (default 10000).")
        var maxSpans: Int = TelemetryQueryDispatcher.defaultTraceMaxSpans

        mutating func run() throws {
            guard !traceId.isEmpty else {
                FileHandle.standardError.write(Data("error: --trace-id is required\n".utf8))
                throw ExitCode.failure
            }
            let store = SessionDatabase.shared.runtimeTelemetryStore!
            let response = TelemetryQueryDispatcher.getTrace(store: store, traceId: traceId, maxSpans: maxSpans)
            try emit(response)
        }
    }
}

/// Byte-stable JSON emit — matches the MCP tool output exactly.
private func emit<T: Encodable>(_ value: T) throws {
    let data = try TelemetryQueryDispatcher.encodeJSON(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
