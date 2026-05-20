import Foundation
import SQLite3

/// Phase U.9a — append-only mirror of canonical events for independent-
/// consumer offset tracking. The outbox helper appends a row whenever
/// the caller writes a `token_events`, `agent_trace_event`, or
/// `validation_results` row; consumers pull with their own offset row
/// in `session_event_stream_offsets` and advance independently. The
/// stream's monotonic `id` is the offset cursor.
///
/// Concurrency: shared `parent.queue` serial dispatch queue. Reads
/// (`pullSince`, `lag`) are serial-queue-synchronized. Writes
/// (`appendEvent`, `commitOffset`) are inside the queue boundary.
public final class SessionEventStreamStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// One event on the stream. `sourceTable` identifies which
    /// canonical table the row mirrors; `sourceId` is the rowid in
    /// that table. Consumers can re-fetch the canonical row via this
    /// pair if they need the full payload.
    public struct Event: Sendable, Equatable {
        public let id: Int64
        public let sourceTable: String
        public let sourceId: Int64
        public let kind: String
        public let projectRoot: String?
        public let createdAt: Date
    }

    /// Append one event. Returns the new event id, or -1 on failure.
    /// Caller invokes this from inside the same `parent.queue.sync`
    /// block as the canonical row insert — the outbox helper at
    /// `SessionDatabase.withOutboxTransaction` enforces this.
    @discardableResult
    public func appendEvent(
        sourceTable: String,
        sourceId: Int64,
        kind: String,
        projectRoot: String? = nil,
        at: Date = Date()
    ) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return -1 }
            let sql = """
                INSERT INTO session_event_stream
                    (source_table, source_id, kind, project_root, created_at)
                VALUES (?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sourceTable as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, sourceId)
            sqlite3_bind_text(stmt, 3, (kind as NSString).utf8String, -1, nil)
            if let pr = projectRoot {
                sqlite3_bind_text(stmt, 4, (pr as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_double(stmt, 5, at.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Read up to `limit` events after the consumer's last-processed
    /// offset. Does NOT mutate offset state — caller advances via
    /// `commitOffset(consumerId:upTo:)` after processing the batch.
    public func pullSince(consumerId: String, limit: Int = 100) -> [Event] {
        return parent.queue.sync { () -> [Event] in
            guard let db = parent.db else { return [] }
            // Resolve current offset
            var offset: Int64 = 0
            let oSQL = "SELECT last_processed_event_id FROM session_event_stream_offsets WHERE consumer_id = ?;"
            var oStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, oSQL, -1, &oStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(oStmt, 1, (consumerId as NSString).utf8String, -1, nil)
                if sqlite3_step(oStmt) == SQLITE_ROW {
                    offset = sqlite3_column_int64(oStmt, 0)
                }
            }
            sqlite3_finalize(oStmt)

            let sql = """
                SELECT id, source_table, source_id, kind, project_root, created_at
                FROM session_event_stream
                WHERE id > ?
                ORDER BY id ASC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, offset)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var events: [Event] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let projectRoot: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 4))
                events.append(Event(
                    id: sqlite3_column_int64(stmt, 0),
                    sourceTable: String(cString: sqlite3_column_text(stmt, 1)),
                    sourceId: sqlite3_column_int64(stmt, 2),
                    kind: String(cString: sqlite3_column_text(stmt, 3)),
                    projectRoot: projectRoot,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                ))
            }
            return events
        }
    }

    /// Advance the consumer's offset cursor. Idempotent; safe to call
    /// with a value <= current (no-op via WHERE clause). Auto-inserts
    /// the row if the consumer wasn't pre-seeded.
    @discardableResult
    public func commitOffset(consumerId: String, upTo eventId: Int64, at: Date = Date()) -> Bool {
        let nowEpoch = at.timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return false }
            let sql = """
                INSERT INTO session_event_stream_offsets
                    (consumer_id, last_processed_event_id, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(consumer_id) DO UPDATE SET
                    last_processed_event_id = MAX(last_processed_event_id, excluded.last_processed_event_id),
                    updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (consumerId as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, eventId)
            sqlite3_bind_double(stmt, 3, nowEpoch)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    /// Lag (rows behind the head) for one consumer.
    public func lag(consumerId: String) -> Int {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            let sql = """
                SELECT COUNT(*) FROM session_event_stream
                WHERE id > COALESCE(
                    (SELECT last_processed_event_id FROM session_event_stream_offsets WHERE consumer_id = ?),
                    0
                );
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (consumerId as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// All known consumer ids (seeded + any operator/auto-added rows).
    public func allConsumerIds() -> [String] {
        return parent.queue.sync { () -> [String] in
            guard let db = parent.db else { return [] }
            let sql = "SELECT consumer_id FROM session_event_stream_offsets ORDER BY consumer_id ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return ids
        }
    }
}
