import Testing
import Foundation
import SQLite3
@testable import Core

/// V.18a-2 store + prune tests for `RuntimeTelemetryStore`.
///
/// Covers the four acceptance bullets from
/// `spec/autonomous/backlog/phase-v18a-2-store-and-prune.md`:
///   1. `recordBytes` increments `bytes_used` atomically (covered as a
///      side-effect of the write-storm test — every insert path call
///      bumps both `<table>_bytes` and `bytes_used` in one UPDATE).
///   2. Per-table cap with oldest-evict; cross-checked via fixture
///      write-storm.
///   3. `pruneDatasetToTarget` (the CLI primitive) trims to target and
///      is idempotent — second call with same target is a no-op.
///   4. Two new tests; this suite ships both.
///
/// The 500 MB default cap is too large for unit tests, so each test
/// passes a small `capBytes` parameter that exercises the same code
/// path against a deterministic write-storm.
@Suite("RuntimeTelemetryPrune (V.18a-2)")
struct RuntimeTelemetryPruneTests {

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-v18a-2-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "telemetry-prune-\(UUID().uuidString).db"
    }

    /// Build a span whose serialized byte size is approximately `bytes`.
    /// Pads `attributes_json` to make the row size predictable.
    private static func makeSpan(index: Int, padding: Int) -> RuntimeTelemetryStore.SpanRow {
        let pad = String(repeating: "x", count: max(0, padding))
        return RuntimeTelemetryStore.SpanRow(
            traceId: "trace-\(index)",
            spanId: "span-\(index)",
            parentSpanId: nil,
            name: "op-\(index)",
            startUnixNs: Int64(index),
            endUnixNs: Int64(index + 1),
            attributesJson: "{\"i\":\(index),\"p\":\"\(pad)\"}",
            statusCode: 0,
            sessionId: nil,
            toolCallId: nil,
            validationRunId: nil
        )
    }

    // MARK: - Acceptance bullet 2: per-table 500 MB cap + oldest-evict

    /// Write a storm of spans into one dataset under a synthetic 64 KB
    /// table cap. After each insert, the store must evict the oldest
    /// rows so `span_bytes` settles at or below 64 KB. Post-state:
    ///   - span_bytes <= cap
    ///   - bytes_used == span_bytes + log_bytes (denormalisation
    ///     invariant)
    ///   - the OLDEST spans (lowest start_unix_ns) are the ones missing
    ///   - span_count matches the actual row count on disk
    @Test("write-storm at per-table cap evicts oldest spans and keeps counters in sync")
    func writeStormEvictsOldest() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        let store = session.runtimeTelemetryStore!
        let datasetId = store.createDataset(projectId: "test-project", workstreamId: nil)
        #expect(datasetId > 0)

        // Cap = 64 KB. Each span is roughly ~700 bytes (with 600B
        // padding + overhead) — about 90 spans fit before eviction. We
        // write 500 spans to force ~6x churn.
        let cap = 64 * 1024
        let totalWrites = 500

        for i in 0..<totalWrites {
            let span = Self.makeSpan(index: i, padding: 600)
            store.insertSpan(datasetId: datasetId, span: span, capBytes: cap)
        }

        let spanBytes = store.tableBytes(datasetId: datasetId, table: .span)
        #expect(spanBytes <= cap, "span_bytes (\(spanBytes)) must be <= cap (\(cap))")

        // Denormalisation invariant: bytes_used == span_bytes + log_bytes
        let total = store.bytesUsed(datasetId: datasetId)
        let logBytes = store.tableBytes(datasetId: datasetId, table: .log)
        #expect(total == spanBytes + logBytes, "bytes_used (\(total)) must equal span_bytes (\(spanBytes)) + log_bytes (\(logBytes))")

        // Confirm the oldest spans are the ones gone. The remaining
        // rows must all have start_unix_ns >= the smallest survivor;
        // every survivor index must be > some threshold X where the
        // dropped indices are [0, X].
        let (survivorMinIndex, survivorCount) = Self.querySpanRange(path: path, datasetId: datasetId)
        // We expect at least one span to have been evicted.
        #expect(survivorMinIndex > 0, "expected oldest spans evicted; survivor min index = \(survivorMinIndex)")
        #expect(survivorCount > 0 && survivorCount < totalWrites, "expected partial eviction; survivor count = \(survivorCount) / \(totalWrites)")

        // span_count column matches the on-disk row count.
        let rowCount = store.rowCount(datasetId: datasetId, table: .span)
        #expect(rowCount == survivorCount, "span_count column (\(rowCount)) must match on-disk row count (\(survivorCount))")
    }

    // MARK: - Acceptance bullet 3: CLI prune idempotence

    /// Drive `pruneDatasetToTarget` (the CLI's primitive) twice with
    /// the same target. The first call deletes rows down to the target;
    /// the second call must be a no-op (0 deletions, byte counter
    /// unchanged). This pins the CLI's documented idempotence guarantee.
    @Test("pruneDatasetToTarget is idempotent — second call deletes 0 rows and leaves byte count unchanged")
    func cliPruneIsIdempotent() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        let store = session.runtimeTelemetryStore!
        let datasetId = store.createDataset(projectId: "idem-test", workstreamId: "ws-1")
        #expect(datasetId > 0)

        // Fill the dataset above the prune target. Cap is set high so
        // the inserts don't auto-evict mid-storm — we want the prune
        // CLI to do the deletion. Each span is ~700 bytes; insert 200
        // spans => ~140 KB; prune target = 32 KB.
        let oversizeCap = 10 * 1024 * 1024  // 10 MB — well above the test storm
        for i in 0..<200 {
            let span = Self.makeSpan(index: i, padding: 600)
            store.insertSpan(datasetId: datasetId, span: span, capBytes: oversizeCap)
        }

        let bytesBeforePrune = store.bytesUsed(datasetId: datasetId)
        #expect(bytesBeforePrune > 0)

        let target = 32 * 1024
        #expect(bytesBeforePrune > target, "fixture must be over target for the prune to do work")

        let firstRun = store.pruneDatasetToTarget(datasetId: datasetId, targetBytes: target)
        let bytesAfterFirstRun = store.bytesUsed(datasetId: datasetId)
        #expect(firstRun.spansDeleted > 0, "first prune call should delete spans")
        #expect(bytesAfterFirstRun <= target, "bytes_used (\(bytesAfterFirstRun)) must be <= target (\(target)) after first prune")

        // Second call: same target. Expected: 0 deletions, identical
        // byte counter. This is the CLI's idempotence guarantee.
        let secondRun = store.pruneDatasetToTarget(datasetId: datasetId, targetBytes: target)
        let bytesAfterSecondRun = store.bytesUsed(datasetId: datasetId)
        #expect(secondRun.spansDeleted == 0, "second prune call must delete 0 spans; got \(secondRun.spansDeleted)")
        #expect(secondRun.logsDeleted == 0, "second prune call must delete 0 logs; got \(secondRun.logsDeleted)")
        #expect(bytesAfterSecondRun == bytesAfterFirstRun, "bytes_used must be unchanged after second idempotent prune; got \(bytesAfterSecondRun) vs \(bytesAfterFirstRun)")

        // Denormalisation invariant still holds.
        let spanBytes = store.tableBytes(datasetId: datasetId, table: .span)
        let logBytes = store.tableBytes(datasetId: datasetId, table: .log)
        #expect(bytesAfterSecondRun == spanBytes + logBytes, "bytes_used must equal span_bytes + log_bytes after prune")
    }

    // MARK: - SQLite peek helpers

    /// Read (min(start_unix_ns), count(*)) for the given dataset's
    /// span rows directly from SQLite. The store's `oldestRowsLocked`
    /// is private; this peeks at the same data via a read-only connection
    /// so the test verifies the actual on-disk state rather than the
    /// store's accounting.
    private static func querySpanRange(path: String, datasetId: Int64) -> (minIndex: Int64, count: Int) {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db = db else { return (0, 0) }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT COALESCE(MIN(start_unix_ns), 0), COUNT(*) FROM runtime_telemetry_span WHERE dataset_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, datasetId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return (sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int64(stmt, 1)))
        }
        return (0, 0)
    }
}
