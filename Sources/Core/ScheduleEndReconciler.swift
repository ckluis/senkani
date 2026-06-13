import Foundation

/// t6-schedule-end-cli-to-app-bridge — LEG A (headless reconcile-on-launch
/// drain). Core-pure: NO SwiftUI / AppKit / launchd imports. The one-line
/// App-launch wire (`ScheduleEndReconciler.reconcileToHead(db: .shared)`) is
/// LEG B / operator and lives OUTSIDE this type.
///
/// The drain reads `schedule_end` `token_events` rows the live HookRouter
/// push may have missed (App not running at completion time) and replays
/// each through the idempotent `ScheduleEndNotifier.deliverIfNew` primitive.
/// Because the durable DB row is canonical truth (operator decision
/// 2026-06-08, Torvalds/Carmack; Kleppmann constraint), this replay is the
/// fallback queue: nothing is lost when the App was down.
///
/// ## Dedup invariant — TWO guards
///
/// **Guard 1 (the cursor)** is a SCAN-WINDOW optimization only. It is
/// fail-safe to lose or reset: `scheduleEndReconcileCursor()` fail-OPENs to
/// `0` when the row is missing/corrupt (NEVER to head), so a reset cursor
/// re-scans the whole history — it can only cost work, never a
/// double-deliver.
///
/// **Guard 2 (the sessionId ledger via `deliverIfNew`)** is the SAFETY
/// BOUNDARY — exactly-once across the live push and this replay. The live
/// HookRouter push and this replay both key on the IDENTICAL `sessionId`
/// (`ScheduleTelemetry.sessionId(taskName:runId:)`, written verbatim to the
/// `token_events.session_id` column), so whichever runs first records the id
/// in the durable ledger and the other no-ops.
///
/// **The ordering that makes it safe:** the cursor advances to
/// `rows.last.id` only AFTER the whole batch has been delivered. A crash
/// between `deliver` and the cursor advance re-scans those rows on the next
/// run, and Guard 2's ledger dedups them → no double-deliver. (Per-row the
/// ledger is already the boundary; the per-batch advance just means a
/// mid-batch crash re-scans the batch, which is harmless for the same
/// reason.)
public enum ScheduleEndReconciler {

    /// `session_event_stream_offsets.consumer_id` for the reconcile cursor.
    /// Distinct from every dispatcher consumer id — its own scan window over
    /// the `schedule_end` slice of `token_events`.
    public static let cursorId = "schedule_end_reconcile"

    /// Outcome of a reconcile pass. `scanned` is rows pulled; `delivered` is
    /// rows that fired a NEW banner; `skipped` is rows the ledger already had
    /// (or rows with an empty sessionId, which can't be deduped); `newCursor`
    /// is the high-water id after the pass.
    public struct ReconcileResult: Equatable {
        public let scanned: Int
        public let delivered: Int
        public let skipped: Int
        public let newCursor: Int64

        public init(scanned: Int, delivered: Int, skipped: Int, newCursor: Int64) {
            self.scanned = scanned
            self.delivered = delivered
            self.skipped = skipped
            self.newCursor = newCursor
        }
    }

    /// The default delivery seam: the idempotent durable-ledger primitive.
    /// Overridable so most tests inject a RECORDING closure (parallel-safe,
    /// no real NotificationDelivery fan-out); the live wire and the one
    /// end-to-end test use this default.
    public static func defaultDeliver(
        _ scheduleId: String, _ summary: String, _ sessionId: String, _ ledgerPath: String?
    ) -> Bool {
        ScheduleEndNotifier.deliverIfNew(
            scheduleId: scheduleId, summary: summary, sessionId: sessionId, ledgerPath: ledgerPath
        )
    }

    /// One reconcile pass: read cursor → pull `schedule_end` rows after it
    /// (id-ASC) → replay each through `deliver` → AFTER the batch, advance
    /// the cursor to `rows.last.id` (only when the batch was non-empty).
    ///
    /// A row with an empty `sessionId` is SKIPPED (mirrors HookRouter's
    /// session-id-less drop — there is no key to dedup on) but it does NOT
    /// block the cursor: the cursor still advances past it via `rows.last.id`
    /// so a single bad row can't strand the whole window.
    ///
    /// Crash-safety: the cursor advance is the LAST step. A crash between any
    /// `deliver` and the advance re-scans the batch next run; the sessionId
    /// ledger dedups → no double-deliver (see the type doc's Guard 2).
    @discardableResult
    public static func reconcileOnce(
        db: SessionDatabase,
        ledgerPath: String? = nil,
        deliver: (_ scheduleId: String, _ summary: String, _ sessionId: String, _ ledgerPath: String?) -> Bool = defaultDeliver,
        now: () -> Date = { Date() },
        limit: Int = 200
    ) -> ReconcileResult {
        let cursor = db.scheduleEndReconcileCursor()
        let rows = db.scheduleEndEventsSince(afterId: cursor, limit: limit)

        var delivered = 0
        var skipped = 0
        for row in rows {
            // No session_id ⇒ nothing to dedup on; skip (don't fire an
            // undedupable banner) but let the cursor still pass it.
            if row.sessionId.isEmpty {
                skipped += 1
                continue
            }
            let fired = deliver(row.scheduleId, row.summary, row.sessionId, ledgerPath)
            if fired {
                delivered += 1
            } else {
                skipped += 1
            }
        }

        // Advance ONLY on a non-empty batch — an empty pull means we're at
        // head and there is no new high-water id to commit.
        let newCursor: Int64
        if let last = rows.last {
            db.advanceScheduleEndReconcileCursor(to: last.id)
            newCursor = last.id
        } else {
            newCursor = cursor
        }

        return ReconcileResult(
            scanned: rows.count, delivered: delivered, skipped: skipped, newCursor: newCursor
        )
    }

    /// Drain to head: loop `reconcileOnce` until a pass scans 0 rows,
    /// bounded by `maxBatches` so a producer racing the drain can't spin
    /// forever (mirrors `EventStreamDispatcher.drainToHead`). Aggregates the
    /// per-pass results; `newCursor` is the final high-water id.
    @discardableResult
    public static func reconcileToHead(
        db: SessionDatabase,
        ledgerPath: String? = nil,
        deliver: (_ scheduleId: String, _ summary: String, _ sessionId: String, _ ledgerPath: String?) -> Bool = defaultDeliver,
        now: () -> Date = { Date() },
        limit: Int = 200,
        maxBatches: Int = 1000
    ) -> ReconcileResult {
        var totalScanned = 0
        var totalDelivered = 0
        var totalSkipped = 0
        var lastCursor = db.scheduleEndReconcileCursor()
        var batches = 0

        while batches < maxBatches {
            let result = reconcileOnce(
                db: db, ledgerPath: ledgerPath, deliver: deliver, now: now, limit: limit
            )
            lastCursor = result.newCursor
            if result.scanned == 0 { break }
            totalScanned += result.scanned
            totalDelivered += result.delivered
            totalSkipped += result.skipped
            batches += 1
        }

        return ReconcileResult(
            scanned: totalScanned,
            delivered: totalDelivered,
            skipped: totalSkipped,
            newCursor: lastCursor
        )
    }
}
