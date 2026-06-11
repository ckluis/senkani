import Foundation
import SQLite3

/// Phase U.9a — durable per-session work queue. One row per pending unit
/// of work; rows transition through `pending → processing → succeeded |
/// dead_letter` with operator-replayable transitions. Lease/heartbeat
/// model lets a worker claim a row, prove it's still alive, and ack on
/// success or retry on failure. Honker's load-bearing property — the
/// queue write is part of the caller's serial-queue transaction so
/// rollback leaves NEITHER the canonical row NOR the queue entry behind.
///
/// Concurrency: shared `parent.queue` serial dispatch queue (I1-I9 in
/// `Sources/Core/Stores/INVARIANTS.md`); no second SQLite handle. Tests
/// flush via `parent.flushWrites()` when needed.
public final class SessionWorkQueueStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// One claimed row returned by `lease(...)`. Identifies the queue
    /// row + payload so workers can dispatch on `kind`. Lease ownership
    /// is checked on `heartbeat` / `ack` / `retry` so a worker can't
    /// touch another worker's row.
    public struct Lease: Sendable, Equatable {
        public let id: Int64
        public let kind: String
        public let payload: String
        public let owner: String
        public let leaseExpiresAt: Date
        public let retryCount: Int
        public let projectRoot: String?
    }

    /// Diagnostics rollup consumed by `senkani doctor` + dashboard tiles.
    public struct Diagnostics: Sendable, Equatable {
        public let pending: Int
        public let processing: Int
        public let succeeded: Int
        public let deadLetter: Int
        public let activeLeases: Int
        public let retriedTotal: Int
        public let oldestPendingAt: Date?
        public let nextWakeupAt: Date?
        public let byKind: [String: Int]
    }

    /// Append-only enqueue. Returns the new rowid, or -1 on failure.
    /// `payload` is opaque to the queue (caller-encoded JSON or
    /// otherwise). `nextWakeupAt` defaults to "available now" (0).
    /// `at` is the row's `created_at`/`updated_at` timestamp —
    /// injectable so parity-timing tests are fixture-driven (U.9b-3b
    /// leg 4), defaulting to the wall clock for production callers.
    @discardableResult
    public func enqueue(
        kind: String,
        payload: String = "",
        nextWakeupAt: Date? = nil,
        projectRoot: String? = nil,
        at: Date = Date()
    ) -> Int64 {
        let now = at.timeIntervalSince1970
        let wakeup = nextWakeupAt.map { $0.timeIntervalSince1970 } ?? 0.0
        return parent.queue.sync {
            guard let db = parent.db else { return -1 }
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
            Self.bindOptionalText(stmt, 6, projectRoot)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
            parent.recordEvent(type: "session_work_queue.enqueued")
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Claim up to `limit` pending rows whose kind matches `kinds` and
    /// whose `next_wakeup_at` is in the past. Sets `state=processing` +
    /// `lease_owner` + `lease_expires_at`. Returns the claimed
    /// `[Lease]`. Empty array if no eligible rows.
    public func lease(
        kinds: [String]? = nil,
        owner: String,
        leaseTtl: TimeInterval = 60,
        limit: Int = 16,
        now: Date = Date()
    ) -> [Lease] {
        let nowEpoch = now.timeIntervalSince1970
        let expiresEpoch = nowEpoch + leaseTtl
        return parent.queue.sync { () -> [Lease] in
            guard let db = parent.db else { return [] }
            // SELECT eligible rows
            var selectSQL = """
                SELECT id, kind, payload, retry_count, project_root
                FROM session_work_queue
                WHERE state = 'pending' AND next_wakeup_at <= ?
            """
            if let kinds, !kinds.isEmpty {
                let placeholders = kinds.map { _ in "?" }.joined(separator: ",")
                selectSQL += " AND kind IN (\(placeholders))"
            }
            selectSQL += " ORDER BY id ASC LIMIT ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var idx: Int32 = 1
            sqlite3_bind_double(stmt, idx, nowEpoch); idx += 1
            for k in (kinds ?? []) {
                sqlite3_bind_text(stmt, idx, (k as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR); idx += 1
            }
            sqlite3_bind_int(stmt, idx, Int32(limit))

            var claimed: [(id: Int64, kind: String, payload: String, retryCount: Int, projectRoot: String?)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let kind = String(cString: sqlite3_column_text(stmt, 1))
                let payload = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? "" : String(cString: sqlite3_column_text(stmt, 2))
                let retryCount = Int(sqlite3_column_int64(stmt, 3))
                let projectRoot: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 4))
                claimed.append((id, kind, payload, retryCount, projectRoot))
            }

            // UPDATE each claimed row to processing
            let updateSQL = """
                UPDATE session_work_queue
                   SET state = 'processing',
                       lease_owner = ?,
                       lease_expires_at = ?,
                       heartbeat_at = ?,
                       updated_at = ?
                 WHERE id = ? AND state = 'pending';
            """
            var leases: [Lease] = []
            for c in claimed {
                var uStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, updateSQL, -1, &uStmt, nil) == SQLITE_OK else { continue }
                defer { sqlite3_finalize(uStmt) }
                sqlite3_bind_text(uStmt, 1, (owner as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_double(uStmt, 2, expiresEpoch)
                sqlite3_bind_double(uStmt, 3, nowEpoch)
                sqlite3_bind_double(uStmt, 4, nowEpoch)
                sqlite3_bind_int64(uStmt, 5, c.id)
                if sqlite3_step(uStmt) == SQLITE_DONE && sqlite3_changes(db) > 0 {
                    leases.append(Lease(
                        id: c.id, kind: c.kind, payload: c.payload,
                        owner: owner,
                        leaseExpiresAt: Date(timeIntervalSince1970: expiresEpoch),
                        retryCount: c.retryCount,
                        projectRoot: c.projectRoot
                    ))
                    parent.recordEvent(type: "session_work_queue.leased")
                }
            }
            return leases
        }
    }

    /// Extend the lease's TTL. Owner must match the stored
    /// `lease_owner`; mismatch returns false and is a no-op.
    @discardableResult
    public func heartbeat(id: Int64, owner: String, leaseTtl: TimeInterval = 60, now: Date = Date()) -> Bool {
        let nowEpoch = now.timeIntervalSince1970
        let expiresEpoch = nowEpoch + leaseTtl
        return parent.queue.sync {
            guard let db = parent.db else { return false }
            let sql = """
                UPDATE session_work_queue
                   SET lease_expires_at = ?,
                       heartbeat_at = ?,
                       updated_at = ?
                 WHERE id = ? AND lease_owner = ? AND state = 'processing';
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, expiresEpoch)
            sqlite3_bind_double(stmt, 2, nowEpoch)
            sqlite3_bind_double(stmt, 3, nowEpoch)
            sqlite3_bind_int64(stmt, 4, id)
            sqlite3_bind_text(stmt, 5, (owner as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
        }
    }

    /// Mark the row succeeded. Owner check applies.
    @discardableResult
    public func ack(id: Int64, owner: String, resultSummary: String? = nil, now: Date = Date()) -> Bool {
        return updateTerminal(id: id, owner: owner, newState: "succeeded", summary: resultSummary, eventType: "session_work_queue.acked", now: now)
    }

    /// Move the row back to pending with retry_count += 1 and an
    /// optional next-wakeup delay. Owner check applies.
    @discardableResult
    public func retry(id: Int64, owner: String, reason: String? = nil, nextWakeupAt: Date? = nil, now: Date = Date()) -> Bool {
        let nowEpoch = now.timeIntervalSince1970
        let wakeup = nextWakeupAt.map { $0.timeIntervalSince1970 } ?? nowEpoch
        return parent.queue.sync {
            guard let db = parent.db else { return false }
            let sql = """
                UPDATE session_work_queue
                   SET state = 'pending',
                       retry_count = retry_count + 1,
                       retry_reason = ?,
                       lease_owner = NULL,
                       lease_expires_at = NULL,
                       heartbeat_at = NULL,
                       next_wakeup_at = ?,
                       updated_at = ?
                 WHERE id = ? AND lease_owner = ? AND state = 'processing';
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            Self.bindOptionalText(stmt, 1, reason)
            sqlite3_bind_double(stmt, 2, wakeup)
            sqlite3_bind_double(stmt, 3, nowEpoch)
            sqlite3_bind_int64(stmt, 4, id)
            sqlite3_bind_text(stmt, 5, (owner as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            let ok = sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
            if ok { parent.recordEvent(type: "session_work_queue.retried") }
            return ok
        }
    }

    /// Mark the row dead-lettered. Owner check applies.
    @discardableResult
    public func deadLetter(id: Int64, owner: String, reason: String, now: Date = Date()) -> Bool {
        return updateTerminal(id: id, owner: owner, newState: "dead_letter", summary: reason, eventType: "session_work_queue.dead_lettered", now: now)
    }

    /// Operator-driven replay: move a dead-letter row back to pending
    /// with retry_count reset. Skips ownership check (no live lease).
    @discardableResult
    public func replay(id: Int64, now: Date = Date()) -> Bool {
        let nowEpoch = now.timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return false }
            let sql = """
                UPDATE session_work_queue
                   SET state = 'pending',
                       retry_count = 0,
                       retry_reason = NULL,
                       lease_owner = NULL,
                       lease_expires_at = NULL,
                       heartbeat_at = NULL,
                       next_wakeup_at = 0,
                       updated_at = ?
                 WHERE id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, nowEpoch)
            sqlite3_bind_int64(stmt, 2, id)
            return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
        }
    }

    /// Sweep expired leases: rows whose `lease_expires_at <= now` and
    /// `state = 'processing'` flip back to `pending`. Returns the count
    /// of rows re-pended. Caller schedules this periodically.
    @discardableResult
    public func reapExpiredLeases(now: Date = Date()) -> Int {
        let nowEpoch = now.timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            let sql = """
                UPDATE session_work_queue
                   SET state = 'pending',
                       retry_reason = 'lease_expired',
                       lease_owner = NULL,
                       lease_expires_at = NULL,
                       heartbeat_at = NULL,
                       updated_at = ?
                 WHERE state = 'processing' AND lease_expires_at <= ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, nowEpoch)
            sqlite3_bind_double(stmt, 2, nowEpoch)
            sqlite3_step(stmt)
            let n = Int(sqlite3_changes(db))
            if n > 0 { parent.recordEvent(type: "session_work_queue.lease_expired") }
            return n
        }
    }

    /// Diagnostics snapshot. `senkani doctor` reads this; tests assert
    /// against it after exercising lifecycle transitions.
    public func diagnostics(projectRoot: String? = nil, now: Date = Date()) -> Diagnostics {
        return parent.queue.sync { () -> Diagnostics in
            guard let db = parent.db else {
                return Diagnostics(pending: 0, processing: 0, succeeded: 0, deadLetter: 0,
                                   activeLeases: 0, retriedTotal: 0,
                                   oldestPendingAt: nil, nextWakeupAt: nil, byKind: [:])
            }
            // State counts
            let stateSQL = projectRoot == nil
                ? "SELECT state, COUNT(*) FROM session_work_queue GROUP BY state;"
                : "SELECT state, COUNT(*) FROM session_work_queue WHERE project_root = ? GROUP BY state;"
            var counts: [String: Int] = [:]
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, stateSQL, -1, &stmt, nil) == SQLITE_OK {
                if let pr = projectRoot { sqlite3_bind_text(stmt, 1, (pr as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    counts[String(cString: sqlite3_column_text(stmt, 0))] = Int(sqlite3_column_int64(stmt, 1))
                }
            }
            sqlite3_finalize(stmt)

            // Active leases (state=processing AND lease_expires_at > now)
            var activeLeases = 0
            let activeSQL = "SELECT COUNT(*) FROM session_work_queue WHERE state = 'processing' AND lease_expires_at > ?;"
            var aStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, activeSQL, -1, &aStmt, nil) == SQLITE_OK {
                sqlite3_bind_double(aStmt, 1, now.timeIntervalSince1970)
                if sqlite3_step(aStmt) == SQLITE_ROW {
                    activeLeases = Int(sqlite3_column_int64(aStmt, 0))
                }
            }
            sqlite3_finalize(aStmt)

            // Retried total (SUM(retry_count))
            var retriedTotal = 0
            let retrySQL = "SELECT COALESCE(SUM(retry_count), 0) FROM session_work_queue;"
            var rStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, retrySQL, -1, &rStmt, nil) == SQLITE_OK {
                if sqlite3_step(rStmt) == SQLITE_ROW {
                    retriedTotal = Int(sqlite3_column_int64(rStmt, 0))
                }
            }
            sqlite3_finalize(rStmt)

            // Oldest pending + next wakeup
            var oldestPendingAt: Date? = nil
            var nextWakeupAt: Date? = nil
            let oldSQL = "SELECT MIN(created_at), MIN(next_wakeup_at) FROM session_work_queue WHERE state = 'pending';"
            var oStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, oldSQL, -1, &oStmt, nil) == SQLITE_OK {
                if sqlite3_step(oStmt) == SQLITE_ROW {
                    if sqlite3_column_type(oStmt, 0) != SQLITE_NULL {
                        oldestPendingAt = Date(timeIntervalSince1970: sqlite3_column_double(oStmt, 0))
                    }
                    if sqlite3_column_type(oStmt, 1) != SQLITE_NULL {
                        nextWakeupAt = Date(timeIntervalSince1970: sqlite3_column_double(oStmt, 1))
                    }
                }
            }
            sqlite3_finalize(oStmt)

            // By-kind rollup of pending+processing rows
            var byKind: [String: Int] = [:]
            let kindSQL = "SELECT kind, COUNT(*) FROM session_work_queue WHERE state IN ('pending', 'processing') GROUP BY kind;"
            var kStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, kindSQL, -1, &kStmt, nil) == SQLITE_OK {
                while sqlite3_step(kStmt) == SQLITE_ROW {
                    byKind[String(cString: sqlite3_column_text(kStmt, 0))] = Int(sqlite3_column_int64(kStmt, 1))
                }
            }
            sqlite3_finalize(kStmt)

            return Diagnostics(
                pending: counts["pending"] ?? 0,
                processing: counts["processing"] ?? 0,
                succeeded: counts["succeeded"] ?? 0,
                deadLetter: counts["dead_letter"] ?? 0,
                activeLeases: activeLeases,
                retriedTotal: retriedTotal,
                oldestPendingAt: oldestPendingAt,
                nextWakeupAt: nextWakeupAt,
                byKind: byKind
            )
        }
    }

    // MARK: - U.9b-3b leg 4: parity pairing/timing

    /// Per-item pairing/timing snapshot backing the `senkani doctor`
    /// latency sub-rows (U.9b-3b leg 4 — deferred by the u9b-3 spine).
    ///
    /// No new storage: the dual-write bus enqueue
    /// (`AutoValidateDualWrite.run` / `PaneRefreshDualWrite.run`) happens
    /// synchronously at the instant the in-process leg completes, so each
    /// `session_work_queue` row already IS the pair record:
    ///   - `created_at`  = in-process leg completion (the enqueue instant)
    ///   - `updated_at`  = bus leg completion for `state='succeeded'` rows
    ///                     (the terminal ack is the last `updated_at` writer)
    ///
    /// Pairing semantics:
    ///   - matched   = succeeded row ⇒ delta = `updated_at - created_at`
    ///                 (how far the bus path trailed the in-process path)
    ///   - unmatched = pending/processing row ⇒ the in-process leg
    ///                 delivered but the bus leg hasn't completed yet; the
    ///                 oldest one's age is the "bus path is behind" signal
    ///   - `dead_letter` rows are terminal divergence (will never match) —
    ///     surfaced by the queue line's dead_letter count, NOT counted here
    public struct ParityTiming: Sendable, Equatable {
        /// One `updated_at - created_at` delta per matched (succeeded) pair.
        public let matchedDeltas: [TimeInterval]
        /// Rows whose bus leg hasn't completed (pending + processing).
        public let unmatchedCount: Int
        /// `now - MIN(created_at)` over unmatched rows; nil when none.
        public let oldestUnmatchedAge: TimeInterval?

        public init(
            matchedDeltas: [TimeInterval],
            unmatchedCount: Int,
            oldestUnmatchedAge: TimeInterval?
        ) {
            self.matchedDeltas = matchedDeltas
            self.unmatchedCount = unmatchedCount
            self.oldestUnmatchedAge = oldestUnmatchedAge
        }

        /// Nearest-rank percentile over `matchedDeltas` (p in (0, 100]).
        /// Pure — fixture-testable without a database.
        public func percentile(_ p: Double) -> TimeInterval? {
            guard !matchedDeltas.isEmpty, p > 0, p <= 100 else { return nil }
            let sorted = matchedDeltas.sorted()
            let rank = max(1, Int((p / 100 * Double(sorted.count)).rounded(.up)))
            return sorted[min(rank, sorted.count) - 1]
        }
    }

    /// Read the parity pairing/timing snapshot for the dual-write kinds.
    /// `matchedLimit` bounds the percentile window to the most recent
    /// succeeded rows (nothing prunes succeeded rows, so an unbounded
    /// parity window must not grow the doctor's read). `now` is
    /// injectable so age computation is fixture-driven in tests.
    public func parityTiming(
        kinds: [String],
        matchedLimit: Int = 1000,
        now: Date = Date()
    ) -> ParityTiming {
        guard !kinds.isEmpty else {
            return ParityTiming(matchedDeltas: [], unmatchedCount: 0, oldestUnmatchedAge: nil)
        }
        let placeholders = kinds.map { _ in "?" }.joined(separator: ",")
        return parent.queue.sync { () -> ParityTiming in
            guard let db = parent.db else {
                return ParityTiming(matchedDeltas: [], unmatchedCount: 0, oldestUnmatchedAge: nil)
            }
            // Matched pairs — most recent `matchedLimit` succeeded rows.
            var deltas: [TimeInterval] = []
            let mSQL = """
                SELECT updated_at - created_at FROM session_work_queue
                WHERE state = 'succeeded' AND kind IN (\(placeholders))
                ORDER BY id DESC LIMIT ?;
            """
            var mStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, mSQL, -1, &mStmt, nil) == SQLITE_OK {
                var idx: Int32 = 1
                for k in kinds {
                    sqlite3_bind_text(mStmt, idx, (k as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR); idx += 1
                }
                sqlite3_bind_int(mStmt, idx, Int32(matchedLimit))
                while sqlite3_step(mStmt) == SQLITE_ROW {
                    deltas.append(sqlite3_column_double(mStmt, 0))
                }
            }
            sqlite3_finalize(mStmt)

            // Unmatched pairs — bus leg not yet complete.
            var unmatchedCount = 0
            var oldestAge: TimeInterval? = nil
            let uSQL = """
                SELECT COUNT(*), MIN(created_at) FROM session_work_queue
                WHERE state IN ('pending', 'processing') AND kind IN (\(placeholders));
            """
            var uStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, uSQL, -1, &uStmt, nil) == SQLITE_OK {
                var idx: Int32 = 1
                for k in kinds {
                    sqlite3_bind_text(uStmt, idx, (k as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR); idx += 1
                }
                if sqlite3_step(uStmt) == SQLITE_ROW {
                    unmatchedCount = Int(sqlite3_column_int64(uStmt, 0))
                    if unmatchedCount > 0, sqlite3_column_type(uStmt, 1) != SQLITE_NULL {
                        oldestAge = now.timeIntervalSince1970 - sqlite3_column_double(uStmt, 1)
                    }
                }
            }
            sqlite3_finalize(uStmt)

            return ParityTiming(
                matchedDeltas: deltas,
                unmatchedCount: unmatchedCount,
                oldestUnmatchedAge: oldestAge
            )
        }
    }

    // MARK: - Helpers

    private func updateTerminal(id: Int64, owner: String, newState: String, summary: String?, eventType: String, now: Date) -> Bool {
        let nowEpoch = now.timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return false }
            let sql = """
                UPDATE session_work_queue
                   SET state = ?,
                       result_summary = ?,
                       updated_at = ?
                 WHERE id = ? AND lease_owner = ? AND state = 'processing';
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (newState as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            Self.bindOptionalText(stmt, 2, summary)
            sqlite3_bind_double(stmt, 3, nowEpoch)
            sqlite3_bind_int64(stmt, 4, id)
            sqlite3_bind_text(stmt, 5, (owner as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            let ok = sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
            if ok { parent.recordEvent(type: eventType) }
            return ok
        }
    }

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, (val as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
