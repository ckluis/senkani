import Testing
import Foundation
@testable import Core

/// Coverage for `t6-schedule-end-cli-to-app-bridge-2026-05-21` — LEG A, the
/// headless reconcile-on-launch drain (`ScheduleEndReconciler`). Replays
/// undelivered `schedule_end` `token_events` rows through the idempotent
/// `ScheduleEndNotifier.deliverIfNew` primitive, guarded by a high-water
/// cursor (scan window) + the sessionId ledger (the exactly-once boundary).
///
/// Hermetic: each case builds a temp `SessionDatabase(path:)` under a
/// per-test UUID temp dir (migrations run → the `session_event_stream_offsets`
/// table the cursor reuses is present) and a temp ledger path. Rows are
/// seeded through the PRODUCTION row shape via
/// `ScheduleTelemetry.withTestDatabase(db) { ScheduleTelemetry.recordEnd(...) }`.
///
/// Most cases inject a RECORDING `deliver` closure (parallel-safe — no real
/// NotificationDelivery fan-out). The ONE end-to-end case (case 4) drives the
/// real `deliverIfNew` → `NotificationDelivery` path and so carries
/// `.serialized` + `.notificationDeliveryGate` with a MockNotificationSink /
/// NotificationRouter install (mirrors `ScheduleEndNotifierTests`).

// MARK: - Hermetic helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("senkani-reconcile-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("session.sqlite").path
    return (SessionDatabase(path: path), path)
}

private func makeTempLedgerPath() -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("senkani-reconcile-ledger-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("schedule-end-delivered.json").path
}

/// Seed a production-real `schedule_end` row (and only that — `recordEnd`
/// writes exactly one row). `exitCode == 0` ⇒ "success"; else "failed: exit N".
private func seedEnd(
    _ db: SessionDatabase, taskName: String, runId: String, exitCode: Int32 = 0,
    projectRoot: String = "/tmp/proj"
) {
    ScheduleTelemetry.withTestDatabase(db) {
        ScheduleTelemetry.recordEnd(
            projectRoot: projectRoot, taskName: taskName, runId: runId, exitCode: exitCode
        )
    }
}

/// A recording deliver closure that mimics the ledger's deliver-once / dedup
/// semantics by sessionId, WITHOUT touching the global NotificationDelivery.
/// Parallel-safe.
private final class RecordingDeliver: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(scheduleId: String, summary: String, sessionId: String)] = []
    private var seen: Set<String> = []
    /// When false, every call reports "new" (delivered) regardless of dedup —
    /// used to prove the cursor alone advances. Default true = ledger-like.
    private let dedup: Bool

    init(dedup: Bool = true) { self.dedup = dedup }

    var deliver: (String, String, String, String?) -> Bool {
        { [weak self] scheduleId, summary, sessionId, _ in
            guard let self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            self.calls.append((scheduleId, summary, sessionId))
            guard self.dedup else { return true }
            if self.seen.contains(sessionId) { return false }
            self.seen.insert(sessionId)
            return true
        }
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
}

// MARK: - Cases 1,2,3,5,6,7,8,9 — recording-deliver (parallel-safe)

@Suite("ScheduleEndReconciler — drain logic (recording deliver)")
struct ScheduleEndReconcilerLogicTests {

    // (1) fresh cursor replays all 3
    @Test("fresh cursor replays all seeded schedule_end rows")
    func freshCursorReplaysAll() {
        let (db, _) = makeTempDB()
        seedEnd(db, taskName: "a", runId: "r1")
        seedEnd(db, taskName: "b", runId: "r2", exitCode: 2)
        seedEnd(db, taskName: "c", runId: "r3")

        let rec = RecordingDeliver()
        let result = ScheduleEndReconciler.reconcileToHead(db: db, deliver: rec.deliver)

        #expect(result.scanned == 3, "all 3 schedule_end rows pulled from a fresh (0) cursor")
        #expect(result.delivered == 3, "all 3 fired a fresh banner")
        #expect(result.skipped == 0)
        #expect(rec.callCount == 3)
        #expect(result.newCursor > 0, "cursor advanced to the last row id")
    }

    // (2) cursor advances + re-run no-op, then a 4th row delivers only 1
    @Test("cursor advances; an immediate re-run is a no-op; a new 4th row delivers exactly 1")
    func cursorAdvancesThenIncremental() {
        let (db, _) = makeTempDB()
        seedEnd(db, taskName: "a", runId: "r1")
        seedEnd(db, taskName: "b", runId: "r2")
        seedEnd(db, taskName: "c", runId: "r3")

        let rec = RecordingDeliver()
        let first = ScheduleEndReconciler.reconcileToHead(db: db, deliver: rec.deliver)
        #expect(first.delivered == 3)

        // Re-run with NOTHING new: the cursor sits past all 3 → zero scan.
        let second = ScheduleEndReconciler.reconcileToHead(db: db, deliver: rec.deliver)
        #expect(second.scanned == 0, "re-run past the cursor scans nothing")
        #expect(second.delivered == 0)
        #expect(rec.callCount == 3, "no extra deliver call on the no-op re-run")

        // A 4th row appears; only it is replayed.
        seedEnd(db, taskName: "d", runId: "r4")
        let third = ScheduleEndReconciler.reconcileToHead(db: db, deliver: rec.deliver)
        #expect(third.scanned == 1, "only the new row is in the scan window")
        #expect(third.delivered == 1)
        #expect(rec.callCount == 4)
    }

    // (3) ledger wins when cursor resets (re-pull all, deliverIfNew false → 0 new)
    @Test("ledger wins when the cursor is reset: re-pull all but deliver 0 new")
    func ledgerWinsOnCursorReset() {
        let (db, _) = makeTempDB()
        seedEnd(db, taskName: "a", runId: "r1")
        seedEnd(db, taskName: "b", runId: "r2")

        // A single recording deliver that dedups by sessionId across BOTH
        // runs — i.e. it plays the role of the durable ledger surviving a
        // cursor reset (Guard 2 wins even though Guard 1 was lost).
        let rec = RecordingDeliver()

        let first = ScheduleEndReconciler.reconcileOnce(db: db, deliver: rec.deliver)
        #expect(first.delivered == 2)

        // Simulate a LOST/RESET cursor by re-pulling from afterId 0 directly
        // (the cursor is monotonic via commitOffset's MAX, so a real reset is
        // a fresh-DB / wiped-row event; the scan window it produces is exactly
        // `afterId: 0`). Guard 2 — the dedup deliver standing in for the
        // durable sessionId ledger — wins even though Guard 1 was lost.
        let rePulled = db.scheduleEndEventsSince(afterId: 0, limit: 200)
        #expect(rePulled.count == 2, "from cursor 0 the full history re-pulls")
        var newDeliveries = 0
        for row in rePulled {
            if rec.deliver(row.scheduleId, row.summary, row.sessionId, nil) { newDeliveries += 1 }
        }
        #expect(newDeliveries == 0, "the ledger (dedup deliver) wins: 0 new on a full re-pull")
    }

    // (5) partial drain/crash mid-replay (limit:1 ×2, per-batch advance)
    @Test("partial drain: limit 1 advances per batch; two passes drain both rows once each")
    func partialDrainLimitOne() {
        let (db, _) = makeTempDB()
        seedEnd(db, taskName: "a", runId: "r1")
        seedEnd(db, taskName: "b", runId: "r2")

        let rec = RecordingDeliver()

        // First pass with limit 1: scans + delivers exactly the first row,
        // advances the cursor past it (per-batch advance crash-safety).
        let p1 = ScheduleEndReconciler.reconcileOnce(db: db, deliver: rec.deliver, limit: 1)
        #expect(p1.scanned == 1)
        #expect(p1.delivered == 1)
        let cursorAfter1 = db.scheduleEndReconcileCursor()
        #expect(cursorAfter1 == p1.newCursor, "cursor persisted to the batch high-water")

        // Second pass: the cursor moved, so it scans + delivers the SECOND row
        // only — neither row double-delivers.
        let p2 = ScheduleEndReconciler.reconcileOnce(db: db, deliver: rec.deliver, limit: 1)
        #expect(p2.scanned == 1)
        #expect(p2.delivered == 1)
        #expect(rec.callCount == 2, "each row delivered exactly once across the two partial passes")

        // A third pass is now at head.
        let p3 = ScheduleEndReconciler.reconcileOnce(db: db, deliver: rec.deliver, limit: 1)
        #expect(p3.scanned == 0)
    }

    // (6) corrupt/missing cursor fail-safe to 0 (never fail-closed to head)
    @Test("a missing cursor reads 0 (fail-OPEN to a full re-scan, never to head)")
    func missingCursorFailsOpenToZero() {
        let (db, _) = makeTempDB()
        seedEnd(db, taskName: "a", runId: "r1")
        seedEnd(db, taskName: "b", runId: "r2")

        // No reconcile has ever run → no offsets row for the consumer.
        #expect(db.scheduleEndReconcileCursor() == 0,
                "absent cursor reads 0, NOT the table head — a missing cursor re-scans all")

        // And a first reconcile from that absent cursor scans the full history.
        let rec = RecordingDeliver()
        let result = ScheduleEndReconciler.reconcileToHead(db: db, deliver: rec.deliver)
        #expect(result.scanned == 2, "fail-open to 0 means the whole history is scanned")
        #expect(result.delivered == 2)
    }

    // (7) non-schedule_end rows ignored incl. a higher-id non-schedule_end row
    //     not stranding the cursor
    @Test("non-schedule_end rows are ignored and a higher-id non-schedule_end row never strands the cursor")
    func nonScheduleEndRowsIgnored() {
        let (db, _) = makeTempDB()
        // A schedule_end row first...
        seedEnd(db, taskName: "a", runId: "r1")
        // ...then non-schedule_end rows with HIGHER ids: a schedule_start and
        // a schedule_blocked (same source, different feature) + a plain
        // token_events row from a different source.
        ScheduleTelemetry.withTestDatabase(db) {
            ScheduleTelemetry.recordStart(projectRoot: "/tmp/proj", taskName: "a", command: "echo hi", runId: "r9")
            ScheduleTelemetry.recordBlocked(projectRoot: "/tmp/proj", taskName: "a", runId: "r8", reason: "budget")
        }
        db.recordTokenEvent(
            sessionId: "interactive:1", paneId: nil, projectRoot: "/tmp/proj",
            source: "mcp_tool", toolName: "read", model: nil,
            inputTokens: 1, outputTokens: 1, savedTokens: 0, costCents: 0,
            feature: "read", command: "read x", modelTier: nil
        )

        let rec = RecordingDeliver()
        let result = ScheduleEndReconciler.reconcileToHead(db: db, deliver: rec.deliver)

        #expect(result.scanned == 1, "only the single schedule_end row is pulled")
        #expect(result.delivered == 1)
        #expect(rec.calls.first?.scheduleId == "a")

        // The query filters on feature='schedule_end' / source='schedule', so
        // the higher-id start/blocked/interactive rows are simply absent from
        // the scan — they neither deliver NOR advance the cursor past the
        // schedule_end row in a way that would strand a later schedule_end.
        // Prove it: a NEW schedule_end with the highest id still delivers.
        seedEnd(db, taskName: "z", runId: "rz")
        let after = ScheduleEndReconciler.reconcileToHead(db: db, deliver: rec.deliver)
        #expect(after.scanned == 1, "a later schedule_end is still found — the cursor was not stranded")
        #expect(after.delivered == 1)
    }

    // (8) empty-sessionId row skipped, doesn't block advance
    @Test("an empty-sessionId schedule_end row is skipped but does not block the cursor advance")
    func emptySessionIdSkippedNotBlocking() {
        let (db, _) = makeTempDB()
        // Directly write a schedule_end row with an EMPTY session_id (a
        // pathological row recordEnd would never produce, but the drain must
        // be robust to). Then a well-formed schedule_end with a higher id.
        db.recordTokenEvent(
            sessionId: "", paneId: nil, projectRoot: "/tmp/proj",
            source: ScheduleTelemetry.source, toolName: nil, model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: ScheduleTelemetry.featureEnd, command: "ghost: success", modelTier: nil
        )
        seedEnd(db, taskName: "real", runId: "r1")

        let rec = RecordingDeliver()
        let result = ScheduleEndReconciler.reconcileToHead(db: db, deliver: rec.deliver)

        #expect(result.scanned == 2, "both rows pulled")
        #expect(result.skipped == 1, "the empty-sessionId row is skipped")
        #expect(result.delivered == 1, "the well-formed row still delivered")
        #expect(rec.callCount == 1, "deliver was invoked only for the well-formed row")

        // The cursor advanced PAST the empty row (it did not strand): a re-run
        // is a no-op.
        let rerun = ScheduleEndReconciler.reconcileToHead(db: db, deliver: rec.deliver)
        #expect(rerun.scanned == 0, "the empty row did not strand the cursor")
    }

    // (9) summary/scheduleId reconstruction + a malformed-command row still delivers
    @Test("scheduleId/summary reconstruction handles a colon-bearing taskName and a malformed command")
    func reconstructionAndFallback() {
        let (db, _) = makeTempDB()
        // taskName="nightly backup", exit 1 ⇒ command "nightly backup: failed: exit 1".
        seedEnd(db, taskName: "nightly backup", runId: "r1", exitCode: 1)

        // A MALFORMED schedule_end command with NO ": " separator — the
        // fallback must still yield a non-empty scheduleId so the row delivers.
        db.recordTokenEvent(
            sessionId: "schedule:weird:run2", paneId: nil, projectRoot: "/tmp/proj",
            source: ScheduleTelemetry.source, toolName: nil, model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: ScheduleTelemetry.featureEnd, command: "noseparatorhere", modelTier: nil
        )

        let rec = RecordingDeliver()
        let result = ScheduleEndReconciler.reconcileToHead(db: db, deliver: rec.deliver)

        #expect(result.scanned == 2)
        #expect(result.delivered == 2, "both the well-formed and the malformed row deliver")

        let nightly = rec.calls.first { $0.sessionId.contains("nightly backup") }
        #expect(nightly?.scheduleId == "nightly backup",
                "scheduleId is the command prefix before the FIRST ': '")
        #expect(nightly?.summary == "failed: exit 1",
                "summary is everything after '{scheduleId}: ' — including the inner colon")

        let weird = rec.calls.first { $0.sessionId == "schedule:weird:run2" }
        #expect(weird != nil, "the malformed-command row still delivered (fallback)")
        #expect(weird?.scheduleId.isEmpty == false,
                "fallback yields a non-empty scheduleId for a separator-less command")
    }
}

// MARK: - Case 4 — live-push-then-replay no double-deliver (real notifier + gate)

@Suite("ScheduleEndReconciler — live push then replay (real notifier)", .serialized, .notificationDeliveryGate)
struct ScheduleEndReconcilerLiveTests {

    // (4) live-push-then-replay no double-deliver (real notifier + gate)
    @Test("a live HookRouter push then a reconcile replay never double-delivers (same sessionId ledger)")
    func livePushThenReplayNoDoubleDeliver() {
        NotificationDelivery.resetForTesting()
        let spy = MockNotificationSink()
        let router = NotificationRouter(entries: [
            .init(name: "spy", sink: spy, events: Set(NotificationRouter.EventKind.allCases))
        ])
        NotificationDelivery.install(router)
        defer { NotificationDelivery.resetForTesting() }

        let (db, _) = makeTempDB()
        let ledger = makeTempLedgerPath()

        // One scheduled run: the DB row exists AND the live HookRouter push
        // already delivered it (so the ledger already records its sessionId).
        let taskName = "nightly"
        let runId = "20260613000000-aaa111"
        seedEnd(db, taskName: taskName, runId: runId)
        let sid = ScheduleTelemetry.sessionId(taskName: taskName, runId: runId)

        // Simulate the live push having already fired through the SAME ledger.
        let pushFired = ScheduleEndNotifier.deliverIfNew(
            scheduleId: taskName, summary: "success", sessionId: sid, ledgerPath: ledger
        )
        #expect(pushFired == true, "the live push delivered the first banner")
        #expect(spy.delivered.count == 1)

        // Now the reconcile drain runs against the SAME ledger (the default
        // real deliverIfNew path). It re-pulls the DB row, but Guard 2 (the
        // sessionId ledger) dedups → NO second banner.
        let result = ScheduleEndReconciler.reconcileToHead(db: db, ledgerPath: ledger)
        #expect(result.scanned == 1, "the drain re-pulls the undelivered-looking DB row")
        #expect(result.delivered == 0, "the ledger already had the sessionId — no new delivery")
        #expect(result.skipped == 1)
        #expect(spy.delivered.count == 1, "still exactly ONE banner — no double-deliver across push + replay")
    }
}
