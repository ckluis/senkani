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

    /// Outcome of `ackWorkOnCommit` (U.9c-2). `committed` carries the
    /// work body's return value; `leaseLost` means the worker no longer
    /// held the lease at ack time (expired + reclaimed, owner mismatch,
    /// or the row is already terminal) — the transaction was rolled
    /// back, so NEITHER the work's effect NOR the ack persisted.
    public enum AckCommitResult<T> {
        case committed(T)
        case leaseLost
    }

    /// Ack-on-commit: run the worker's unit of work and the queue ack in
    /// ONE transaction (U.9c-2). The `work` closure writes its canonical
    /// effect through the bound `OutboxTransaction` (same `db` handle,
    /// same `BEGIN IMMEDIATE … COMMIT`), then this method transitions the
    /// leased row `processing → succeeded` in that same transaction.
    ///
    /// **Delivery contract — at-least-once.** The effect and the ack
    /// commit atomically or not at all:
    ///
    /// - `work` throws  → `ROLLBACK`; the error propagates; the row stays
    ///   `processing` and is re-leasable after its lease expires. No
    ///   effect, no ack. (Crash between BEGIN and COMMIT is equivalent —
    ///   SQLite discards the uncommitted transaction on reopen.)
    /// - lease no longer held at ack time (the ack UPDATE matches 0 rows:
    ///   expired + reclaimed by another worker, wrong owner, or already
    ///   terminal) → `ROLLBACK` and return `.leaseLost`. The effect is
    ///   deliberately rolled back too: the row now belongs to whoever
    ///   reclaimed it, so persisting this worker's effect would be a
    ///   double-delivery. The reclaiming worker re-runs the effect —
    ///   at-least-once. Effects MUST therefore be idempotent.
    /// - success → `COMMIT`; return `.committed(result)`. Crash after
    ///   COMMIT leaves the effect done and the row `succeeded` — never
    ///   redelivered.
    ///
    /// There is no at-most-once path: a crash in the redelivery window
    /// re-runs an idempotent effect. A second ack of an already-succeeded
    /// row is the `.leaseLost` no-op above — detectable, never a
    /// double-ack or state corruption.
    ///
    /// The closure runs ON the serial dispatch queue — DO NOT re-enter
    /// `queue.sync` from inside it; use the bound `OutboxTransaction`
    /// helpers.
    public func ackWorkOnCommit<T>(
        id: Int64,
        owner: String,
        resultSummary: String? = nil,
        now: Date = Date(),
        work: (OutboxTransaction) throws -> T
    ) throws -> AckCommitResult<T> {
        return try queue.sync {
            guard let db = self.db else { throw OutboxError.databaseUnavailable }
            var beginErr: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, &beginErr) != SQLITE_OK {
                let msg = beginErr.map { String(cString: $0) } ?? "unknown"
                if let beginErr { sqlite3_free(beginErr) }
                throw OutboxError.beginFailed(msg)
            }
            let tx = OutboxTransaction(db: db, parent: self)
            do {
                let result = try work(tx)
                // Ack inside the SAME transaction as the work's effect.
                let changed = tx.ackWork(id: id, owner: owner, resultSummary: resultSummary, at: now)
                if changed == 0 {
                    // Lease no longer held — roll the effect back too so a
                    // row another worker may have reclaimed is never
                    // double-delivered with a persisted effect.
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return AckCommitResult<T>.leaseLost
                }
                var commitErr: UnsafeMutablePointer<CChar>?
                if sqlite3_exec(db, "COMMIT;", nil, nil, &commitErr) != SQLITE_OK {
                    let msg = commitErr.map { String(cString: $0) } ?? "unknown"
                    if let commitErr { sqlite3_free(commitErr) }
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    throw OutboxError.commitFailed(msg)
                }
                self.recordEvent(type: "session_work_queue.acked")
                return AckCommitResult<T>.committed(result)
            } catch {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
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
        sqlite3_bind_text(stmt, 1, (sourceTable as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int64(stmt, 2, sourceId)
        sqlite3_bind_text(stmt, 3, (kind as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        if let pr = projectRoot {
            sqlite3_bind_text(stmt, 4, (pr as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
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
        sqlite3_bind_text(stmt, 1, (kind as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, (payload as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_double(stmt, 3, wakeup)
        sqlite3_bind_double(stmt, 4, now)
        sqlite3_bind_double(stmt, 5, now)
        if let pr = projectRoot {
            sqlite3_bind_text(stmt, 6, (pr as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    /// Ack the queue row `id` inside the bound transaction (U.9c-2):
    /// transition `processing → succeeded` iff `owner` still holds the
    /// lease. Returns the number of rows changed — `0` means the lease
    /// is no longer held (expired + reclaimed, wrong owner, or already
    /// terminal), and the caller rolls the whole transaction back so no
    /// canonical effect persists without an exclusive ack. The owner +
    /// `state = 'processing'` guard is what makes a second ack a
    /// detectable no-op rather than a double-ack.
    @discardableResult
    public func ackWork(id: Int64, owner: String, resultSummary: String? = nil, at: Date = Date()) -> Int {
        let sql = """
            UPDATE session_work_queue
               SET state = 'succeeded',
                   result_summary = ?,
                   updated_at = ?
             WHERE id = ? AND lease_owner = ? AND state = 'processing';
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if let s = resultSummary {
            sqlite3_bind_text(stmt, 1, (s as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_double(stmt, 2, at.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, id)
        sqlite3_bind_text(stmt, 4, (owner as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }
}
