import Foundation
import SQLite3

/// Owns the `runtime_telemetry_dataset` + `runtime_telemetry_span` +
/// `runtime_telemetry_log` tables end-to-end: writes, per-table byte
/// accounting, automatic oldest-evict prune at 500 MB per table per
/// dataset, and the `senkani prune --dataset <id>` CLI primitive.
///
/// Shipped under V.18a-2 (2026-05-22) per the V.18 RuntimeTelemetryDataset
/// decomposition. Schema is owned by migrations v30 (V.18a-1: three
/// tables + six indexes) and v31 (V.18a-2: `span_bytes` + `log_bytes`
/// per-table byte counters on the dataset row).
///
/// Threading: `final class @unchecked Sendable` sharing the parent's
/// dispatch queue, matching `TokenEventStore` / `ValidationStore` /
/// `CommandStore`. The Swift `actor` pattern would conflict with the
/// queue-affinity invariant documented at `SessionDatabase.queue` —
/// every `sqlite3_*` call against the connection MUST run on
/// `parent.queue`.
///
/// Cap policy: 500 MB per table per dataset (`Self.defaultTableCapBytes`).
/// On every insert path, the store updates `<table>_bytes` + `bytes_used`
/// in one UPDATE, then evicts the oldest rows in the affected table until
/// the table-bytes counter is back at or below the cap. The denormalised
/// `bytes_used` total is kept in sync inside the same `parent.queue.sync`
/// block so a reader never sees a torn dataset row.
public final class RuntimeTelemetryStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    /// Per-table cap = 500 MB per dataset. Hardcoded here per the V.18
    /// parent's operator-locked decision (256 MB rejected, 1 GB rejected).
    /// Override per-call via `pruneTableToCap(capBytes:)` for tests.
    public static let defaultTableCapBytes: Int = 500 * 1024 * 1024

    /// Logical table identifier for the per-table API. Maps to the two
    /// bulk tables; the dataset row is metadata.
    public enum TelemetryTable {
        case span
        case log

        var sqlName: String {
            switch self {
            case .span: return "runtime_telemetry_span"
            case .log: return "runtime_telemetry_log"
            }
        }

        /// Column on `runtime_telemetry_dataset` that holds the running
        /// byte count for this table.
        var bytesColumn: String {
            switch self {
            case .span: return "span_bytes"
            case .log: return "log_bytes"
            }
        }

        /// Column on the bulk table that holds the oldest-evict sort key
        /// (`start_unix_ns` for spans, `unix_ns` for logs). Both are
        /// covered by `idx_runtime_telemetry_<table>_dataset_*` indexes
        /// from migration v30.
        var timeColumn: String {
            switch self {
            case .span: return "start_unix_ns"
            case .log: return "unix_ns"
            }
        }

        /// Column on the dataset row that holds the row count for this
        /// table (`span_count` / `log_count`).
        var countColumn: String {
            switch self {
            case .span: return "span_count"
            case .log: return "log_count"
            }
        }
    }

    public init(parent: SessionDatabase) {
        self.parent = parent
    }

    // MARK: - Schema

    /// Migration ownership: v30 (V.18a-1) owns the three tables + six
    /// indexes; v31 (V.18a-2) owns the `span_bytes`/`log_bytes` columns
    /// on `runtime_telemetry_dataset`. No residual DDL — this is a
    /// no-op kept for symmetry with the other Stores.
    public func setupSchema() {
        // Intentionally empty.
    }

    // MARK: - Dataset CRUD

    /// Create a dataset row and return its `id`. Throws nothing; on DB
    /// failure returns 0 (matches the other stores' best-effort write
    /// posture). `workstreamId` is optional per the V.18a-1 schema.
    @discardableResult
    public func createDataset(projectId: String, workstreamId: String? = nil) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return Int64(0) }
            let now = Int64(Date().timeIntervalSince1970)
            let sql = """
                INSERT INTO runtime_telemetry_dataset
                    (project_id, workstream_id, created_at, bytes_used,
                     span_count, log_count, span_bytes, log_bytes)
                VALUES (?, ?, ?, 0, 0, 0, 0, 0);
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return Int64(0)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (projectId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            if let workstreamId {
                sqlite3_bind_text(stmt, 2, (workstreamId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_int64(stmt, 3, now)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return Int64(0) }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Read the per-table byte counter (`span_bytes` or `log_bytes`).
    /// Returns 0 if the dataset row is missing.
    public func tableBytes(datasetId: Int64, table: TelemetryTable) -> Int {
        return parent.queue.sync {
            return readDatasetColumnLocked(datasetId: datasetId, column: table.bytesColumn)
        }
    }

    /// Read the dataset-level `bytes_used` total.
    public func bytesUsed(datasetId: Int64) -> Int {
        return parent.queue.sync {
            return readDatasetColumnLocked(datasetId: datasetId, column: "bytes_used")
        }
    }

    /// Read the per-table row count (`span_count` or `log_count`).
    /// Convenience for tests + future query tools.
    public func rowCount(datasetId: Int64, table: TelemetryTable) -> Int {
        return parent.queue.sync {
            return readDatasetColumnLocked(datasetId: datasetId, column: table.countColumn)
        }
    }

    // MARK: - Writes

    /// Row payload for `runtime_telemetry_span`. `dataset_id` is supplied
    /// separately at the API boundary so callers cannot misroute spans
    /// to the wrong dataset.
    public struct SpanRow {
        public let traceId: String
        public let spanId: String
        public let parentSpanId: String?
        public let name: String
        public let startUnixNs: Int64
        public let endUnixNs: Int64
        public let attributesJson: String?
        public let statusCode: Int?
        public let sessionId: String?
        public let toolCallId: String?
        public let validationRunId: String?

        public init(
            traceId: String,
            spanId: String,
            parentSpanId: String? = nil,
            name: String,
            startUnixNs: Int64,
            endUnixNs: Int64,
            attributesJson: String? = nil,
            statusCode: Int? = nil,
            sessionId: String? = nil,
            toolCallId: String? = nil,
            validationRunId: String? = nil
        ) {
            self.traceId = traceId
            self.spanId = spanId
            self.parentSpanId = parentSpanId
            self.name = name
            self.startUnixNs = startUnixNs
            self.endUnixNs = endUnixNs
            self.attributesJson = attributesJson
            self.statusCode = statusCode
            self.sessionId = sessionId
            self.toolCallId = toolCallId
            self.validationRunId = validationRunId
        }
    }

    /// Row payload for `runtime_telemetry_log`.
    public struct LogRow {
        public let unixNs: Int64
        public let severityText: String?
        public let bodyText: String?
        public let attributesJson: String?
        public let traceId: String?
        public let spanId: String?
        public let sessionId: String?

        public init(
            unixNs: Int64,
            severityText: String? = nil,
            bodyText: String? = nil,
            attributesJson: String? = nil,
            traceId: String? = nil,
            spanId: String? = nil,
            sessionId: String? = nil
        ) {
            self.unixNs = unixNs
            self.severityText = severityText
            self.bodyText = bodyText
            self.attributesJson = attributesJson
            self.traceId = traceId
            self.spanId = spanId
            self.sessionId = sessionId
        }
    }

    /// Insert a span, increment per-table + total byte counters, and
    /// evict the dataset's oldest spans if the per-table cap was crossed.
    /// Returns the new row id (0 on DB failure).
    @discardableResult
    public func insertSpan(datasetId: Int64, span: SpanRow, capBytes: Int = RuntimeTelemetryStore.defaultTableCapBytes) -> Int64 {
        let rowBytes = Self.spanRowBytes(span)
        return parent.queue.sync {
            guard let db = parent.db else { return Int64(0) }
            let sql = """
                INSERT INTO runtime_telemetry_span
                    (dataset_id, trace_id, span_id, parent_span_id, name,
                     start_unix_ns, end_unix_ns, attributes_json,
                     status_code, session_id, tool_call_id, validation_run_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return Int64(0)
            }
            sqlite3_bind_int64(stmt, 1, datasetId)
            sqlite3_bind_text(stmt, 2, (span.traceId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 3, (span.spanId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            Self.bindOptionalText(stmt, 4, span.parentSpanId)
            sqlite3_bind_text(stmt, 5, (span.name as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 6, span.startUnixNs)
            sqlite3_bind_int64(stmt, 7, span.endUnixNs)
            Self.bindOptionalText(stmt, 8, span.attributesJson)
            if let code = span.statusCode {
                sqlite3_bind_int64(stmt, 9, Int64(code))
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            Self.bindOptionalText(stmt, 10, span.sessionId)
            Self.bindOptionalText(stmt, 11, span.toolCallId)
            Self.bindOptionalText(stmt, 12, span.validationRunId)
            let stepRC = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard stepRC == SQLITE_DONE else { return Int64(0) }
            let rowId = sqlite3_last_insert_rowid(db)
            recordBytesLocked(datasetId: datasetId, table: .span, delta: rowBytes, countDelta: 1)
            evictIfOverCapLocked(datasetId: datasetId, table: .span, capBytes: capBytes)
            return rowId
        }
    }

    /// Insert a log row + same accounting as `insertSpan`. Returns the
    /// new row id (0 on DB failure).
    @discardableResult
    public func insertLog(datasetId: Int64, log: LogRow, capBytes: Int = RuntimeTelemetryStore.defaultTableCapBytes) -> Int64 {
        let rowBytes = Self.logRowBytes(log)
        return parent.queue.sync {
            guard let db = parent.db else { return Int64(0) }
            let sql = """
                INSERT INTO runtime_telemetry_log
                    (dataset_id, unix_ns, severity_text, body_text,
                     attributes_json, trace_id, span_id, session_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return Int64(0)
            }
            sqlite3_bind_int64(stmt, 1, datasetId)
            sqlite3_bind_int64(stmt, 2, log.unixNs)
            Self.bindOptionalText(stmt, 3, log.severityText)
            Self.bindOptionalText(stmt, 4, log.bodyText)
            Self.bindOptionalText(stmt, 5, log.attributesJson)
            Self.bindOptionalText(stmt, 6, log.traceId)
            Self.bindOptionalText(stmt, 7, log.spanId)
            Self.bindOptionalText(stmt, 8, log.sessionId)
            let stepRC = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard stepRC == SQLITE_DONE else { return Int64(0) }
            let rowId = sqlite3_last_insert_rowid(db)
            recordBytesLocked(datasetId: datasetId, table: .log, delta: rowBytes, countDelta: 1)
            evictIfOverCapLocked(datasetId: datasetId, table: .log, capBytes: capBytes)
            return rowId
        }
    }

    /// Atomic per-table byte counter increment. Updates `<table>_bytes`,
    /// `bytes_used`, and `<table>_count` in one UPDATE so a reader cannot
    /// observe a torn dataset row. `delta` may be negative (prune path).
    /// Public for callers that want to record bytes for already-inserted
    /// rows (e.g. test fixtures); insert paths call the locked variant.
    public func recordBytes(datasetId: Int64, table: TelemetryTable, delta: Int, countDelta: Int = 1) {
        parent.queue.sync {
            recordBytesLocked(datasetId: datasetId, table: table, delta: delta, countDelta: countDelta)
        }
    }

    // MARK: - Prune

    /// Evict the oldest rows from `table` until `<table>_bytes ≤ capBytes`
    /// for `datasetId`. Returns the number of rows deleted. Idempotent:
    /// re-running with the same cap when already at or below it deletes
    /// 0 rows. The eviction batch size is row-at-a-time because the
    /// indexed scan + per-row UPDATE makes per-row work O(log N); a
    /// batched DELETE would still need a length-sum scan to repair the
    /// counter and gains little on the prune-cold path.
    @discardableResult
    public func pruneTableToCap(datasetId: Int64, table: TelemetryTable, capBytes: Int) -> Int {
        return parent.queue.sync {
            return evictRowsLocked(datasetId: datasetId, table: table, targetBytes: capBytes)
        }
    }

    // MARK: - Read-only query surface (V.18a-6)

    /// One dataset row surfaced by `listDatasets(...)`. Mirrors the
    /// `runtime_telemetry_dataset` columns the query tools care about.
    public struct DatasetRow: Sendable, Equatable {
        public let id: Int64
        public let projectId: String
        public let workstreamId: String?
        public let createdAt: Int64
        public let bytesUsed: Int
        public let spanCount: Int
        public let logCount: Int
        public let spanBytes: Int
        public let logBytes: Int
        public init(id: Int64, projectId: String, workstreamId: String?, createdAt: Int64, bytesUsed: Int, spanCount: Int, logCount: Int, spanBytes: Int, logBytes: Int) {
            self.id = id
            self.projectId = projectId
            self.workstreamId = workstreamId
            self.createdAt = createdAt
            self.bytesUsed = bytesUsed
            self.spanCount = spanCount
            self.logCount = logCount
            self.spanBytes = spanBytes
            self.logBytes = logBytes
        }
    }

    /// V.18a-6 — list datasets, optionally scoped to a project. Empty
    /// `projectId` returns every row. Ordered most-recent first by
    /// `created_at DESC, id DESC` for deterministic CLI output.
    public func listDatasets(projectId: String? = nil) -> [DatasetRow] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql: String
            if projectId != nil {
                sql = """
                    SELECT id, project_id, workstream_id, created_at,
                           bytes_used, span_count, log_count, span_bytes, log_bytes
                      FROM runtime_telemetry_dataset
                     WHERE project_id = ?
                     ORDER BY created_at DESC, id DESC;
                    """
            } else {
                sql = """
                    SELECT id, project_id, workstream_id, created_at,
                           bytes_used, span_count, log_count, span_bytes, log_bytes
                      FROM runtime_telemetry_dataset
                     ORDER BY created_at DESC, id DESC;
                    """
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let projectId {
                sqlite3_bind_text(stmt, 1, (projectId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
            var rows: [DatasetRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let pid = String(cString: sqlite3_column_text(stmt, 1))
                let wid: String? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 2))
                let created = sqlite3_column_int64(stmt, 3)
                rows.append(DatasetRow(
                    id: id, projectId: pid, workstreamId: wid, createdAt: created,
                    bytesUsed: Int(sqlite3_column_int64(stmt, 4)),
                    spanCount: Int(sqlite3_column_int64(stmt, 5)),
                    logCount: Int(sqlite3_column_int64(stmt, 6)),
                    spanBytes: Int(sqlite3_column_int64(stmt, 7)),
                    logBytes: Int(sqlite3_column_int64(stmt, 8))
                ))
            }
            return rows
        }
    }

    /// One span surfaced by the query tools. Carries every column the
    /// MCP/CLI emit needs; the dispatcher routes text fields through
    /// `SecretDetector` before serialising.
    public struct SpanResult: Sendable, Equatable {
        public let id: Int64
        public let datasetId: Int64
        public let traceId: String
        public let spanId: String
        public let parentSpanId: String?
        public let name: String
        public let startUnixNs: Int64
        public let endUnixNs: Int64
        public let attributesJson: String?
        public let statusCode: Int?
        public let sessionId: String?
        public let toolCallId: String?
        public let validationRunId: String?
        public init(id: Int64, datasetId: Int64, traceId: String, spanId: String, parentSpanId: String?, name: String, startUnixNs: Int64, endUnixNs: Int64, attributesJson: String?, statusCode: Int?, sessionId: String?, toolCallId: String?, validationRunId: String?) {
            self.id = id
            self.datasetId = datasetId
            self.traceId = traceId
            self.spanId = spanId
            self.parentSpanId = parentSpanId
            self.name = name
            self.startUnixNs = startUnixNs
            self.endUnixNs = endUnixNs
            self.attributesJson = attributesJson
            self.statusCode = statusCode
            self.sessionId = sessionId
            self.toolCallId = toolCallId
            self.validationRunId = validationRunId
        }
    }

    /// Query filter for `querySpans(...)`. Every field is optional but
    /// at least one MUST be set — the dispatcher refuses unfiltered
    /// queries (would scan the whole table). `datasetId` scopes to one
    /// dataset; the four id-based filters drive index lookups; the
    /// time-range filter walks the `(dataset_id, start_unix_ns DESC)`
    /// index.
    public struct QueryFilter: Sendable, Equatable {
        public var datasetId: Int64?
        public var traceId: String?
        public var sessionId: String?
        public var toolCallId: String?
        public var validationRunId: String?
        public var startUnixNsAtOrAfter: Int64?
        public var endUnixNsAtOrBefore: Int64?
        public init(datasetId: Int64? = nil, traceId: String? = nil, sessionId: String? = nil, toolCallId: String? = nil, validationRunId: String? = nil, startUnixNsAtOrAfter: Int64? = nil, endUnixNsAtOrBefore: Int64? = nil) {
            self.datasetId = datasetId
            self.traceId = traceId
            self.sessionId = sessionId
            self.toolCallId = toolCallId
            self.validationRunId = validationRunId
            self.startUnixNsAtOrAfter = startUnixNsAtOrAfter
            self.endUnixNsAtOrBefore = endUnixNsAtOrBefore
        }
        public var hasAnyFilter: Bool {
            return datasetId != nil || traceId != nil || sessionId != nil ||
                   toolCallId != nil || validationRunId != nil ||
                   startUnixNsAtOrAfter != nil || endUnixNsAtOrBefore != nil
        }
    }

    /// V.18a-6 — query spans with cursor pagination. Returns at most
    /// `limit` rows whose row-id > `cursorAfterId` (nil → first page).
    /// Order is `id ASC` so the cursor is monotonic. Refuses to
    /// run on an empty `filter` (Schneier: no blind table scan).
    public func querySpans(filter: QueryFilter, limit: Int = 1000, cursorAfterId: Int64? = nil) -> [SpanResult] {
        guard filter.hasAnyFilter else { return [] }
        guard limit > 0 else { return [] }
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            var clauses: [String] = []
            if filter.datasetId != nil { clauses.append("dataset_id = ?") }
            if filter.traceId != nil { clauses.append("trace_id = ?") }
            if filter.sessionId != nil { clauses.append("session_id = ?") }
            if filter.toolCallId != nil { clauses.append("tool_call_id = ?") }
            if filter.validationRunId != nil { clauses.append("validation_run_id = ?") }
            if filter.startUnixNsAtOrAfter != nil { clauses.append("start_unix_ns >= ?") }
            if filter.endUnixNsAtOrBefore != nil { clauses.append("end_unix_ns <= ?") }
            if cursorAfterId != nil { clauses.append("id > ?") }
            let whereClause = clauses.joined(separator: " AND ")
            let sql = """
                SELECT id, dataset_id, trace_id, span_id, parent_span_id, name,
                       start_unix_ns, end_unix_ns, attributes_json, status_code,
                       session_id, tool_call_id, validation_run_id
                  FROM runtime_telemetry_span
                 WHERE \(whereClause)
                 ORDER BY id ASC
                 LIMIT ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var idx: Int32 = 1
            if let v = filter.datasetId { sqlite3_bind_int64(stmt, idx, v); idx += 1 }
            if let v = filter.traceId { sqlite3_bind_text(stmt, idx, (v as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR); idx += 1 }
            if let v = filter.sessionId { sqlite3_bind_text(stmt, idx, (v as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR); idx += 1 }
            if let v = filter.toolCallId { sqlite3_bind_text(stmt, idx, (v as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR); idx += 1 }
            if let v = filter.validationRunId { sqlite3_bind_text(stmt, idx, (v as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR); idx += 1 }
            if let v = filter.startUnixNsAtOrAfter { sqlite3_bind_int64(stmt, idx, v); idx += 1 }
            if let v = filter.endUnixNsAtOrBefore { sqlite3_bind_int64(stmt, idx, v); idx += 1 }
            if let v = cursorAfterId { sqlite3_bind_int64(stmt, idx, v); idx += 1 }
            sqlite3_bind_int64(stmt, idx, Int64(limit))
            var out: [SpanResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Self.decodeSpanRow(stmt))
            }
            return out
        }
    }

    /// V.18a-6 — fetch a single trace's full span tree. Capped at
    /// `maxSpans` (default 10K) to bound memory on pathological
    /// traces. Walks `idx_runtime_telemetry_span_trace`.
    public func spansForTrace(traceId: String, maxSpans: Int = 10_000) -> [SpanResult] {
        guard maxSpans > 0 else { return [] }
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, dataset_id, trace_id, span_id, parent_span_id, name,
                       start_unix_ns, end_unix_ns, attributes_json, status_code,
                       session_id, tool_call_id, validation_run_id
                  FROM runtime_telemetry_span
                 WHERE trace_id = ?
                 ORDER BY start_unix_ns ASC, id ASC
                 LIMIT ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (traceId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 2, Int64(maxSpans))
            var out: [SpanResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Self.decodeSpanRow(stmt))
            }
            return out
        }
    }

    /// Decode one row of the canonical SELECT shape used by `querySpans`
    /// and `spansForTrace`. Column indexes mirror the SELECT order.
    private static func decodeSpanRow(_ stmt: OpaquePointer?) -> SpanResult {
        return SpanResult(
            id: sqlite3_column_int64(stmt, 0),
            datasetId: sqlite3_column_int64(stmt, 1),
            traceId: String(cString: sqlite3_column_text(stmt, 2)),
            spanId: String(cString: sqlite3_column_text(stmt, 3)),
            parentSpanId: colText(stmt, 4),
            name: String(cString: sqlite3_column_text(stmt, 5)),
            startUnixNs: sqlite3_column_int64(stmt, 6),
            endUnixNs: sqlite3_column_int64(stmt, 7),
            attributesJson: colText(stmt, 8),
            statusCode: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 9)),
            sessionId: colText(stmt, 10),
            toolCallId: colText(stmt, 11),
            validationRunId: colText(stmt, 12)
        )
    }

    // MARK: - Validation-source queries (V.18a-5)

    /// Summary of the OTLP spans correlated to one `validation_run_id`.
    /// Returned by `traceSummary(validationRunId:)` to populate the
    /// validation-failure attach on the next agent-visible row + the
    /// AgentTimelinePane (V.18a-7) runtime-error badge.
    ///
    /// `topSlowestSpans` is at most 3 entries, ordered by descending
    /// `duration_ns`. `errorCount` counts spans with `status_code > 1`
    /// (OTLP semantic: 0=Unset, 1=Ok, 2=Error). `totalDurationNs` is
    /// `max(end) - min(start)` over the run's spans. `traceId` is the
    /// first matched span's trace_id — the link target for "trace
    /// detail" surfaces.
    public struct ValidationTraceSummary: Sendable, Equatable {
        public struct Span: Sendable, Equatable {
            public let name: String
            public let durationNs: Int64
            public let statusCode: Int?
            public init(name: String, durationNs: Int64, statusCode: Int?) {
                self.name = name
                self.durationNs = durationNs
                self.statusCode = statusCode
            }
        }
        public let validationRunId: String
        public let traceId: String?
        public let topSlowestSpans: [Span]
        public let errorCount: Int
        public let totalDurationNs: Int64
        public let spanCount: Int
        public init(validationRunId: String, traceId: String?, topSlowestSpans: [Span], errorCount: Int, totalDurationNs: Int64, spanCount: Int) {
            self.validationRunId = validationRunId
            self.traceId = traceId
            self.topSlowestSpans = topSlowestSpans
            self.errorCount = errorCount
            self.totalDurationNs = totalDurationNs
            self.spanCount = spanCount
        }
    }

    /// Compute a trace summary across all spans tagged with
    /// `validationRunId`. Returns nil when no spans match (the agent-
    /// visible row attaches nothing in that case — pass-results behavior
    /// per V.18 acceptance bullet 5). Walks `idx_runtime_telemetry_span
    /// _validation_run` for the lookup.
    public func traceSummary(validationRunId: String) -> ValidationTraceSummary? {
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
            let sql = """
                SELECT name, start_unix_ns, end_unix_ns, status_code, trace_id
                  FROM runtime_telemetry_span
                 WHERE validation_run_id = ?
                 ORDER BY (end_unix_ns - start_unix_ns) DESC;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (validationRunId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)

            var top: [ValidationTraceSummary.Span] = []
            var errorCount = 0
            var minStart: Int64 = .max
            var maxEnd: Int64 = .min
            var traceId: String?
            var spanCount = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                spanCount += 1
                let name = String(cString: sqlite3_column_text(stmt, 0))
                let start = sqlite3_column_int64(stmt, 1)
                let end = sqlite3_column_int64(stmt, 2)
                let status: Int? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int64(stmt, 3))
                if traceId == nil, sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                    traceId = String(cString: sqlite3_column_text(stmt, 4))
                }
                if let code = status, code > 1 { errorCount += 1 }
                if start < minStart { minStart = start }
                if end > maxEnd { maxEnd = end }
                if top.count < 3 {
                    top.append(ValidationTraceSummary.Span(name: name, durationNs: end - start, statusCode: status))
                }
            }
            guard spanCount > 0 else { return nil }
            let total = (maxEnd > minStart) ? (maxEnd - minStart) : 0
            return ValidationTraceSummary(
                validationRunId: validationRunId,
                traceId: traceId,
                topSlowestSpans: top,
                errorCount: errorCount,
                totalDurationNs: total,
                spanCount: spanCount
            )
        }
    }

    /// One row of the cross-cutting JOIN between `agent_trace_event`
    /// and `runtime_telemetry_span` on `(session_id, tool_call_id)`.
    /// The V.18 scope-groom Q4 decision (2026-05-07) keyed every
    /// observability story on this JOIN — V.18a-5 makes it land. Used
    /// by the AgentTimelinePane (V.18a-7) to render a runtime-error
    /// badge on rows whose paired runtime spans surfaced ERROR /
    /// duration > p99.
    public struct CrossCuttingTraceRow: Sendable, Equatable {
        public let idempotencyKey: String
        public let sessionId: String
        public let toolCallId: String
        public let spanId: String
        public let spanName: String
        public let traceId: String
        public let durationNs: Int64
        public let statusCode: Int?
        public init(idempotencyKey: String, sessionId: String, toolCallId: String, spanId: String, spanName: String, traceId: String, durationNs: Int64, statusCode: Int?) {
            self.idempotencyKey = idempotencyKey
            self.sessionId = sessionId
            self.toolCallId = toolCallId
            self.spanId = spanId
            self.spanName = spanName
            self.traceId = traceId
            self.durationNs = durationNs
            self.statusCode = statusCode
        }
    }

    /// Cross-cutting JOIN — returns one row per matched
    /// `(agent_trace_event, runtime_telemetry_span)` pair on
    /// `session_id + tool_call_id`. When `sessionId` is non-nil the
    /// query scopes to that session; nil returns the full JOIN (capped
    /// by `limit`). Walks `idx_agent_trace_session_tool` +
    /// `idx_runtime_telemetry_span_session_tool` so it stays cheap on
    /// long sessions.
    public func crossCuttingTraceJoin(sessionId: String? = nil, toolCallId: String? = nil, limit: Int = 1000) -> [CrossCuttingTraceRow] {
        return parent.queue.sync {
            guard let db = parent.db, limit > 0 else { return [] }
            var sql = """
                SELECT a.idempotency_key, a.session_id, a.tool_call_id,
                       s.span_id, s.name, s.trace_id,
                       (s.end_unix_ns - s.start_unix_ns) AS dur, s.status_code
                  FROM agent_trace_event a
                  JOIN runtime_telemetry_span s
                    ON a.session_id = s.session_id
                   AND a.tool_call_id = s.tool_call_id
                 WHERE a.session_id IS NOT NULL
                   AND a.tool_call_id IS NOT NULL
                """
            if sessionId != nil { sql += " AND a.session_id = ?" }
            if toolCallId != nil { sql += " AND a.tool_call_id = ?" }
            sql += " ORDER BY a.started_at DESC LIMIT ?;"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var idx: Int32 = 1
            if let sessionId {
                sqlite3_bind_text(stmt, idx, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                idx += 1
            }
            if let toolCallId {
                sqlite3_bind_text(stmt, idx, (toolCallId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                idx += 1
            }
            sqlite3_bind_int64(stmt, idx, Int64(limit))
            var out: [CrossCuttingTraceRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(stmt, 0))
                let sid = String(cString: sqlite3_column_text(stmt, 1))
                let tcid = String(cString: sqlite3_column_text(stmt, 2))
                let spanId = String(cString: sqlite3_column_text(stmt, 3))
                let name = String(cString: sqlite3_column_text(stmt, 4))
                let traceId = String(cString: sqlite3_column_text(stmt, 5))
                let dur = sqlite3_column_int64(stmt, 6)
                let status: Int? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int64(stmt, 7))
                out.append(CrossCuttingTraceRow(
                    idempotencyKey: key,
                    sessionId: sid,
                    toolCallId: tcid,
                    spanId: spanId,
                    spanName: name,
                    traceId: traceId,
                    durationNs: dur,
                    statusCode: status
                ))
            }
            return out
        }
    }

    /// Drain the dataset's total `bytes_used` to `targetBytes` by evicting
    /// oldest rows from both tables proportionally. Returns the per-table
    /// delete counts. Idempotent: `bytes_used ≤ targetBytes` on entry
    /// returns (0, 0) without writes. Used by `senkani prune --dataset`.
    @discardableResult
    public func pruneDatasetToTarget(datasetId: Int64, targetBytes: Int) -> (spansDeleted: Int, logsDeleted: Int) {
        return parent.queue.sync {
            let currentTotal = readDatasetColumnLocked(datasetId: datasetId, column: "bytes_used")
            guard currentTotal > targetBytes else { return (0, 0) }
            // Split target proportionally to current per-table sizes so we
            // do not flatten one table to zero while leaving the other at
            // its cap. Floor-divide keeps the post-state at-or-below the
            // requested total.
            let spanBytes = readDatasetColumnLocked(datasetId: datasetId, column: TelemetryTable.span.bytesColumn)
            let logBytes = readDatasetColumnLocked(datasetId: datasetId, column: TelemetryTable.log.bytesColumn)
            let spanTarget: Int
            let logTarget: Int
            if currentTotal == 0 {
                spanTarget = 0
                logTarget = 0
            } else {
                spanTarget = (targetBytes * spanBytes) / currentTotal
                logTarget = targetBytes - spanTarget
            }
            let spanDeleted = evictRowsLocked(datasetId: datasetId, table: .span, targetBytes: spanTarget)
            let logDeleted = evictRowsLocked(datasetId: datasetId, table: .log, targetBytes: logTarget)
            return (spanDeleted, logDeleted)
        }
    }

    // MARK: - Locked helpers (parent.queue holders only)

    /// Increment per-table bytes + count + dataset total in one UPDATE.
    /// Caller MUST hold `parent.queue`.
    private func recordBytesLocked(datasetId: Int64, table: TelemetryTable, delta: Int, countDelta: Int) {
        guard let db = parent.db else { return }
        let sql = """
            UPDATE runtime_telemetry_dataset
               SET \(table.bytesColumn) = \(table.bytesColumn) + ?,
                   bytes_used = bytes_used + ?,
                   \(table.countColumn) = \(table.countColumn) + ?
             WHERE id = ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(delta))
        sqlite3_bind_int64(stmt, 2, Int64(delta))
        sqlite3_bind_int64(stmt, 3, Int64(countDelta))
        sqlite3_bind_int64(stmt, 4, datasetId)
        sqlite3_step(stmt)
    }

    /// If `<table>_bytes > capBytes` for `datasetId`, evict oldest rows
    /// until it returns to ≤ cap. Used by `insertSpan`/`insertLog` after
    /// the write commits. Caller MUST hold `parent.queue`.
    private func evictIfOverCapLocked(datasetId: Int64, table: TelemetryTable, capBytes: Int) {
        let current = readDatasetColumnLocked(datasetId: datasetId, column: table.bytesColumn)
        guard current > capBytes else { return }
        _ = evictRowsLocked(datasetId: datasetId, table: table, targetBytes: capBytes)
    }

    /// Evict the oldest rows from `table` for `datasetId` until the
    /// `<table>_bytes` counter is at or below `targetBytes`. Returns
    /// the row count deleted. Caller MUST hold `parent.queue`.
    ///
    /// Strategy: read current counter; if already at/below target,
    /// return 0. Otherwise SELECT the oldest rows' (id, byte_size) pairs
    /// in time order (limit batch), DELETE them, and decrement the
    /// counter atomically per row. The batch loop runs until the
    /// counter is at/below target or the table is empty.
    private func evictRowsLocked(datasetId: Int64, table: TelemetryTable, targetBytes: Int) -> Int {
        guard let db = parent.db else { return 0 }
        let bytesColumn = table.bytesColumn
        let countColumn = table.countColumn
        var current = readDatasetColumnLocked(datasetId: datasetId, column: bytesColumn)
        if current <= targetBytes { return 0 }

        var totalDeleted = 0
        // 256 rows per batch keeps the locked window short while still
        // amortising prepare/finalize overhead. The per-row UPDATE keeps
        // the counter exact (no drift) even if the loop is interrupted
        // mid-batch by a future cancellation hook.
        let batchSize = 256
        while current > targetBytes {
            let candidates = oldestRowsLocked(datasetId: datasetId, table: table, limit: batchSize)
            if candidates.isEmpty { break }
            for (rowId, rowBytes) in candidates {
                if current <= targetBytes { break }
                if !deleteRowLocked(table: table, rowId: rowId) { continue }
                recordBytesLocked(
                    datasetId: datasetId,
                    table: table,
                    delta: -rowBytes,
                    countDelta: -1
                )
                current -= rowBytes
                totalDeleted += 1
            }
            // Always re-read so byte drift (e.g. a manual fixture write)
            // converges and the loop terminates.
            current = readDatasetColumnLocked(datasetId: datasetId, column: bytesColumn)
            // Defensive: if the count column hits zero before the byte
            // counter does (counter drift), reset and exit.
            let remaining = readDatasetColumnLocked(datasetId: datasetId, column: countColumn)
            if remaining == 0 {
                if current != 0 {
                    // Counter drift detected — repair by zeroing the
                    // table's byte column inside the existing total. We
                    // record a negative delta of the drift so bytes_used
                    // stays internally consistent.
                    recordBytesLocked(
                        datasetId: datasetId,
                        table: table,
                        delta: -current,
                        countDelta: 0
                    )
                }
                break
            }
        }
        _ = db
        return totalDeleted
    }

    /// Fetch up to `limit` oldest (id, byte_size) pairs from `table` for
    /// `datasetId`, ordered by the table's `timeColumn` ascending.
    /// Caller MUST hold `parent.queue`. The byte-size formula matches
    /// the insert path's accounting so the post-delete UPDATE keeps the
    /// counter in step.
    private func oldestRowsLocked(datasetId: Int64, table: TelemetryTable, limit: Int) -> [(Int64, Int)] {
        guard let db = parent.db else { return [] }
        let timeColumn = table.timeColumn
        let sql: String
        switch table {
        case .span:
            sql = """
                SELECT id, trace_id, span_id, parent_span_id, name,
                       attributes_json, session_id, tool_call_id,
                       validation_run_id
                  FROM \(table.sqlName)
                 WHERE dataset_id = ?
                 ORDER BY \(timeColumn) ASC, id ASC
                 LIMIT ?;
                """
        case .log:
            sql = """
                SELECT id, severity_text, body_text, attributes_json,
                       trace_id, span_id, session_id
                  FROM \(table.sqlName)
                 WHERE dataset_id = ?
                 ORDER BY \(timeColumn) ASC, id ASC
                 LIMIT ?;
                """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, datasetId)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        var rows: [(Int64, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let bytes: Int
            switch table {
            case .span:
                bytes = Self.spanRowBytesFromColumns(
                    traceId: Self.colText(stmt, 1) ?? "",
                    spanId: Self.colText(stmt, 2) ?? "",
                    parentSpanId: Self.colText(stmt, 3),
                    name: Self.colText(stmt, 4) ?? "",
                    attributesJson: Self.colText(stmt, 5),
                    sessionId: Self.colText(stmt, 6),
                    toolCallId: Self.colText(stmt, 7),
                    validationRunId: Self.colText(stmt, 8)
                )
            case .log:
                bytes = Self.logRowBytesFromColumns(
                    severityText: Self.colText(stmt, 1),
                    bodyText: Self.colText(stmt, 2),
                    attributesJson: Self.colText(stmt, 3),
                    traceId: Self.colText(stmt, 4),
                    spanId: Self.colText(stmt, 5),
                    sessionId: Self.colText(stmt, 6)
                )
            }
            rows.append((rowId, bytes))
        }
        return rows
    }

    /// DELETE a single row by id from `table`. Returns true on success.
    /// Caller MUST hold `parent.queue`.
    private func deleteRowLocked(table: TelemetryTable, rowId: Int64) -> Bool {
        guard let db = parent.db else { return false }
        let sql = "DELETE FROM \(table.sqlName) WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowId)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Read a single integer-valued column from the dataset row. Returns
    /// 0 if missing. Caller MUST hold `parent.queue`. SAFE: `column` is
    /// always one of a fixed enum-derived set ("span_bytes", "log_bytes",
    /// "bytes_used", "span_count", "log_count") — never user input.
    private func readDatasetColumnLocked(datasetId: Int64, column: String) -> Int {
        guard let db = parent.db else { return 0 }
        let sql = "SELECT \(column) FROM runtime_telemetry_dataset WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, datasetId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    // MARK: - Byte size accounting

    /// 40-byte fixed overhead per row covers the INTEGER PRIMARY KEY,
    /// dataset_id, status_code/severity tag, and SQLite's per-row page
    /// metadata. Coarse but deterministic — tests pin the formula so a
    /// future schema add bumps the constant intentionally.
    static let fixedRowOverheadBytes: Int = 40

    static func spanRowBytes(_ span: SpanRow) -> Int {
        return spanRowBytesFromColumns(
            traceId: span.traceId,
            spanId: span.spanId,
            parentSpanId: span.parentSpanId,
            name: span.name,
            attributesJson: span.attributesJson,
            sessionId: span.sessionId,
            toolCallId: span.toolCallId,
            validationRunId: span.validationRunId
        )
    }

    static func spanRowBytesFromColumns(
        traceId: String,
        spanId: String,
        parentSpanId: String?,
        name: String,
        attributesJson: String?,
        sessionId: String?,
        toolCallId: String?,
        validationRunId: String?
    ) -> Int {
        return traceId.utf8.count
            + spanId.utf8.count
            + (parentSpanId?.utf8.count ?? 0)
            + name.utf8.count
            + (attributesJson?.utf8.count ?? 0)
            + (sessionId?.utf8.count ?? 0)
            + (toolCallId?.utf8.count ?? 0)
            + (validationRunId?.utf8.count ?? 0)
            + fixedRowOverheadBytes
    }

    static func logRowBytes(_ log: LogRow) -> Int {
        return logRowBytesFromColumns(
            severityText: log.severityText,
            bodyText: log.bodyText,
            attributesJson: log.attributesJson,
            traceId: log.traceId,
            spanId: log.spanId,
            sessionId: log.sessionId
        )
    }

    static func logRowBytesFromColumns(
        severityText: String?,
        bodyText: String?,
        attributesJson: String?,
        traceId: String?,
        spanId: String?,
        sessionId: String?
    ) -> Int {
        return (severityText?.utf8.count ?? 0)
            + (bodyText?.utf8.count ?? 0)
            + (attributesJson?.utf8.count ?? 0)
            + (traceId?.utf8.count ?? 0)
            + (spanId?.utf8.count ?? 0)
            + (sessionId?.utf8.count ?? 0)
            + fixedRowOverheadBytes
    }

    // MARK: - Bind helpers

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func colText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cstr)
    }
}
