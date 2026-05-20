import Foundation
import SQLite3

extension SessionDatabase {
    /// U.9a — transactional-outbox helper. Caller wraps their canonical-
    /// row insert + a stream append + an optional queue enqueue inside
    /// one serial-queue.sync block via `withOutboxTransaction`. SQLite
    /// auto-commit semantics + the serial dispatch queue mean no other
    /// write can interleave; throwing from the body rolls back the
    /// whole composition by NOT applying the SQL changes (the body
    /// returns before any INSERT executes, OR an explicit BEGIN/ROLLBACK
    /// pair wraps multi-statement writes).
    ///
    /// Honker's "transaction boundary is the product": the queue
    /// enqueue + the stream append are bound to the canonical row's
    /// transaction. If the canonical insert fails, the stream/queue
    /// rows aren't written; if the body throws, the explicit ROLLBACK
    /// reverses any prior INSERTs in the same body.
    ///
    /// The closure runs ON the dispatch queue — DO NOT re-enter
    /// `queue.sync` from inside it. Use the bound `OutboxTransaction`
    /// helpers instead.
    public func withOutboxTransaction<T>(_ body: (OutboxTransaction) throws -> T) throws -> T {
        return try queue.sync {
            guard let db = self.db else {
                throw OutboxError.databaseUnavailable
            }
            // BEGIN IMMEDIATE so SQLite acquires the write lock up front
            // rather than mid-transaction (avoids deadlocks under WAL).
            var beginErr: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, &beginErr) != SQLITE_OK {
                let msg = beginErr.map { String(cString: $0) } ?? "unknown"
                if let beginErr { sqlite3_free(beginErr) }
                throw OutboxError.beginFailed(msg)
            }
            let tx = OutboxTransaction(db: db, parent: self)
            do {
                let result = try body(tx)
                var commitErr: UnsafeMutablePointer<CChar>?
                if sqlite3_exec(db, "COMMIT;", nil, nil, &commitErr) != SQLITE_OK {
                    let msg = commitErr.map { String(cString: $0) } ?? "unknown"
                    if let commitErr { sqlite3_free(commitErr) }
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    throw OutboxError.commitFailed(msg)
                }
                return result
            } catch {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    public enum OutboxError: Error, Equatable {
        case databaseUnavailable
        case beginFailed(String)
        case commitFailed(String)
        case bodyFailed(String)
    }
}

/// Handle passed to the `withOutboxTransaction` closure. Provides
/// queue-friendly stream + queue writers that share the bound
/// transaction. The handle is NOT `Sendable` — must stay on the
/// dispatch queue. `db` is an unsafe pointer the body uses for its
/// canonical-row INSERTs.
public final class OutboxTransaction {
    /// The raw SQLite handle bound to the active transaction. Caller
    /// uses this to write canonical rows (token_events,
    /// agent_trace_event, validation_results, etc.) inside the same
    /// transaction. Already on `parent.queue` — no re-entry needed.
    public let db: OpaquePointer
    private unowned let parent: SessionDatabase

    init(db: OpaquePointer, parent: SessionDatabase) {
        self.db = db
        self.parent = parent
    }

    /// Append an event to `session_event_stream` inside the bound
    /// transaction. Returns the new event id, or -1 on failure
    /// (caller throws to roll back).
    @discardableResult
    public func appendEvent(
        sourceTable: String,
        sourceId: Int64,
        kind: String,
        projectRoot: String? = nil,
        at: Date = Date()
    ) -> Int64 {
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

    /// Enqueue work into `session_work_queue` inside the bound
    /// transaction. Returns the new rowid, or -1 on failure.
    @discardableResult
    public func enqueueWork(
        kind: String,
        payload: String = "",
        nextWakeupAt: Date? = nil,
        projectRoot: String? = nil,
        at: Date = Date()
    ) -> Int64 {
        let now = at.timeIntervalSince1970
        let wakeup = nextWakeupAt.map { $0.timeIntervalSince1970 } ?? 0.0
        let sql = """
            INSERT INTO session_work_queue
                (kind, payload, state, retry_count, next_wakeup_at,
                 created_at, updated_at, project_root)
            VALUES (?, ?, 'pending', 0, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (kind as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (payload as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 3, wakeup)
        sqlite3_bind_double(stmt, 4, now)
        sqlite3_bind_double(stmt, 5, now)
        if let pr = projectRoot {
            sqlite3_bind_text(stmt, 6, (pr as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }
}
