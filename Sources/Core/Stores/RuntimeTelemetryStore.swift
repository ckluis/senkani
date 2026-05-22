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
