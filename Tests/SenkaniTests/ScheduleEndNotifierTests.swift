import Testing
import Foundation
@testable import Core

/// Coverage for `t6-schedule-end-cli-to-app-bridge-2026-05-21` — the
/// headless carve of the ratified D7 architecture (operator decision
/// 2026-06-08, Torvalds/Carmack; Kleppmann constraint).
///
/// Exercises:
///   (a) `ScheduleEndNotifier.deliverIfNew` — delivers ONCE per sessionId
///       and DEDUPS a second call with the same sessionId (the Kleppmann
///       invariant: a live push + a future reconcile replay never
///       double-deliver the same schedule_end).
///   (b) The durable ledger survives a fresh primitive instance — the
///       delivered-set is persisted on disk keyed by sessionId.
///   (c) `HookRouter.handle` routes a `schedule_end` event JSON to the
///       delivery seam; a duplicate event dedups; AND a normal tool event
///       is COMPLETELY UNAFFECTED by the new early branch.
///   (d) The CLI producer emit is best-effort: with no socket present it
///       returns `.socketUnreachable` without throwing — fire-and-forget.
///
/// All cases run hermetically against a temp ledger / temp socket path so
/// they never touch the real `~/.senkani/` files or the global
/// notification router.

private func makeTempLedgerPath() -> String {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("senkani-schedend-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return base + "/schedule-end-delivered.json"
}

// MARK: - (a) + (b) Idempotent primitive + durable ledger

@Suite("ScheduleEndNotifier — idempotent delivery primitive", .serialized)
struct ScheduleEndNotifierPrimitiveTests {

    @Test("deliverIfNew delivers once and dedups a same-sessionId replay (Kleppmann)")
    func deliverOnceThenDedup() {
        NotificationDelivery.resetForTesting()
        let spy = MockNotificationSink()
        let router = NotificationRouter(entries: [
            .init(name: "spy", sink: spy, events: Set(NotificationRouter.EventKind.allCases))
        ])
        NotificationDelivery.install(router)
        defer { NotificationDelivery.resetForTesting() }

        let ledger = makeTempLedgerPath()
        let sid = "schedule:nightly:20260609000000-abc123"

        let first = ScheduleEndNotifier.deliverIfNew(
            scheduleId: "nightly", summary: "success", sessionId: sid, ledgerPath: ledger
        )
        #expect(first == true, "first delivery for a fresh sessionId must fire")
        #expect(spy.delivered.count == 1, "exactly one banner fired")
        #expect(spy.delivered.first == .scheduleEnd(scheduleId: "nightly", summary: "success"))

        // Same sessionId again — the Kleppmann dedup invariant: no re-fire.
        let second = ScheduleEndNotifier.deliverIfNew(
            scheduleId: "nightly", summary: "success", sessionId: sid, ledgerPath: ledger
        )
        #expect(second == false, "a same-sessionId replay must dedup (no second delivery)")
        #expect(spy.delivered.count == 1, "no second banner fired on the deduped replay")
    }

    @Test("a DIFFERENT sessionId is a fresh delivery")
    func differentSessionDelivers() {
        NotificationDelivery.resetForTesting()
        let spy = MockNotificationSink()
        let router = NotificationRouter(entries: [
            .init(name: "spy", sink: spy, events: Set(NotificationRouter.EventKind.allCases))
        ])
        NotificationDelivery.install(router)
        defer { NotificationDelivery.resetForTesting() }

        let ledger = makeTempLedgerPath()
        _ = ScheduleEndNotifier.deliverIfNew(
            scheduleId: "nightly", summary: "success",
            sessionId: "schedule:nightly:run-1", ledgerPath: ledger
        )
        let second = ScheduleEndNotifier.deliverIfNew(
            scheduleId: "nightly", summary: "failed: exit 1",
            sessionId: "schedule:nightly:run-2", ledgerPath: ledger
        )
        #expect(second == true, "a new run (distinct sessionId) delivers")
        #expect(spy.delivered.count == 2)
    }

    @Test("the durable ledger survives a fresh primitive instance (persisted by sessionId)")
    func ledgerPersistsAcrossInstances() {
        // No router installed — we only care about the ledger persistence,
        // not the notification fan-out, here.
        NotificationDelivery.resetForTesting()
        let ledger = makeTempLedgerPath()
        let sid = "schedule:weekly:20260609120000-zzz999"

        // First instance delivers + records.
        let first = ScheduleEndNotifier.deliverIfNew(
            scheduleId: "weekly", summary: "success", sessionId: sid, ledgerPath: ledger
        )
        #expect(first == true)

        // The file exists on disk and contains the sessionId.
        #expect(FileManager.default.fileExists(atPath: ledger))

        // A brand-new ledger object pointed at the same file sees it delivered.
        let freshLedger = ScheduleEndLedger(path: ledger)
        #expect(freshLedger.isDelivered(sessionId: sid),
                "the delivered sessionId must survive a fresh ledger instance")

        // And deliverIfNew (a fresh primitive call) dedups against the
        // persisted ledger — proving persistence, not just in-memory state.
        let replay = ScheduleEndNotifier.deliverIfNew(
            scheduleId: "weekly", summary: "success", sessionId: sid, ledgerPath: ledger
        )
        #expect(replay == false, "a persisted sessionId dedups across instances")
    }

    @Test("injected clock stamps the ledger deliveredAt")
    func injectedClockStamps() {
        NotificationDelivery.resetForTesting()
        let ledger = makeTempLedgerPath()
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        _ = ScheduleEndNotifier.deliverIfNew(
            scheduleId: "s", summary: "ok", sessionId: "sid-clock",
            ledgerPath: ledger, now: { fixed }
        )
        // Read the raw JSON and confirm the deliveredAt is the injected stamp.
        let dict = try? SettingsIO.readJSONOrEmpty(at: ledger)
        let delivered = dict?["delivered"] as? [String: Any]
        let stamp = delivered?["sid-clock"] as? String
        let expected = ISO8601DateFormatter().string(from: fixed)
        #expect(stamp == expected, "deliveredAt must reflect the injected clock")
    }
}

// MARK: - (c) HookRouter consumer branch + tool-event non-regression

@Suite("ScheduleEndNotifier — HookRouter consumer branch", .serialized)
struct ScheduleEndHookRouterTests {

    /// A capture box for the schedule_end delivery seam: records each
    /// (scheduleId, summary, sessionId) and dedups by sessionId so the
    /// test can pin the deliver-once / dedup-on-replay behavior through the
    /// REAL `HookRouter.handle` path without touching the global router or
    /// the real ledger.
    final class DeliverSpy: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(String, String, String)] = []
        private var seen: Set<String> = []
        func deliver(_ scheduleId: String, _ summary: String, _ sessionId: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            calls.append((scheduleId, summary, sessionId))
            if seen.contains(sessionId) { return false }
            seen.insert(sessionId)
            return true
        }
    }

    private func scheduleEndEvent(scheduleId: String, summary: String, sessionId: String) -> Data {
        let event: [String: Any] = [
            "hook_event_name": "schedule_end",
            "schedule_id": scheduleId,
            "summary": summary,
            "session_id": sessionId,
        ]
        return try! JSONSerialization.data(withJSONObject: event)
    }

    @Test("a schedule_end event routes to the delivery seam and dedups a replay")
    func scheduleEndRoutesAndDedups() {
        HookSeamLock.withLock {
            let spy = DeliverSpy()
            let prior = HookRouter.scheduleEndDeliver
            HookRouter.scheduleEndDeliver = { spy.deliver($0, $1, $2) }
            defer { HookRouter.scheduleEndDeliver = prior }

            let sid = "schedule:nightly:run-xyz"
            let resp1 = HookRouter.handle(
                eventJSON: scheduleEndEvent(scheduleId: "nightly", summary: "success", sessionId: sid)
            )
            // Always passthrough — fire-and-forget, no meaningful response.
            #expect(String(data: resp1, encoding: .utf8) == "{}")
            #expect(spy.calls.count == 1)
            #expect(spy.calls[0].0 == "nightly")
            #expect(spy.calls[0].1 == "success")
            #expect(spy.calls[0].2 == sid)

            // A duplicate schedule_end event (same sessionId) — the seam is
            // still invoked but the dedup returns false; the test verifies
            // the seam saw the replay and HookRouter still passes through.
            let resp2 = HookRouter.handle(
                eventJSON: scheduleEndEvent(scheduleId: "nightly", summary: "success", sessionId: sid)
            )
            #expect(String(data: resp2, encoding: .utf8) == "{}")
            #expect(spy.calls.count == 2, "the seam saw the replay")
        }
    }

    @Test("a schedule_end with no session_id is dropped (nothing to dedup on)")
    func scheduleEndWithoutSessionDropped() {
        HookSeamLock.withLock {
            let spy = DeliverSpy()
            let prior = HookRouter.scheduleEndDeliver
            HookRouter.scheduleEndDeliver = { spy.deliver($0, $1, $2) }
            defer { HookRouter.scheduleEndDeliver = prior }

            let event: [String: Any] = [
                "hook_event_name": "schedule_end",
                "schedule_id": "nightly",
                "summary": "success",
            ]
            let resp = HookRouter.handle(eventJSON: try! JSONSerialization.data(withJSONObject: event))
            #expect(String(data: resp, encoding: .utf8) == "{}")
            #expect(spy.calls.isEmpty, "a session-id-less schedule_end must not fire the undedupable seam")
        }
    }

    @Test("a normal tool event is COMPLETELY UNAFFECTED by the schedule_end branch")
    func normalToolEventUnaffected() {
        HookSeamLock.withLock {
            let spy = DeliverSpy()
            let prior = HookRouter.scheduleEndDeliver
            HookRouter.scheduleEndDeliver = { spy.deliver($0, $1, $2) }
            defer { HookRouter.scheduleEndDeliver = prior }

            // A "Write" tool event passes through unchanged (Write is not in
            // the Read/Bash/Grep intercept list) — the canonical
            // passthrough proof. The schedule_end seam must NOT have fired.
            let writeEvent: [String: Any] = [
                "tool_name": "Write",
                "hook_event_name": "PreToolUse",
            ]
            let writeResp = HookRouter.handle(
                eventJSON: try! JSONSerialization.data(withJSONObject: writeEvent)
            )
            #expect(String(data: writeResp, encoding: .utf8) == "{}",
                    "Write still passes through exactly '{}' — branch did not alter tool routing")

            // A "Read" tool event still gets the senkani_read redirect deny —
            // the existing gate behavior is byte-stable.
            let readEvent: [String: Any] = [
                "tool_name": "Read",
                "hook_event_name": "PreToolUse",
                "tool_input": ["file_path": "/tmp/x.swift"],
            ]
            let readResp = HookRouter.handle(
                eventJSON: try! JSONSerialization.data(withJSONObject: readEvent)
            )
            let json = try? JSONSerialization.jsonObject(with: readResp) as? [String: Any]
            let hookOutput = json?["hookSpecificOutput"] as? [String: Any]
            #expect(hookOutput?["permissionDecision"] as? String == "deny",
                    "Read still gets the redirect deny — existing gate behavior unchanged")
            let reason = hookOutput?["permissionDecisionReason"] as? String ?? ""
            #expect(reason.contains("mcp__senkani__read"))

            // The schedule_end delivery seam was never invoked by either
            // tool event — the new branch is a clean early-return for
            // schedule_end only.
            #expect(spy.calls.isEmpty, "no tool event may invoke the schedule_end seam")
        }
    }
}

// MARK: - (d) Producer emit is best-effort

@Suite("ScheduleEndNotifier — producer emit (best-effort)", .serialized)
struct ScheduleEndEmitTests {

    @Test("emit with no socket present is a silent no-op (does not throw, returns socketUnreachable)")
    func emitNoSocketIsNoOp() {
        // A path under a temp dir where no socket exists.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-no-sock-\(UUID().uuidString)/hook.sock")
            .path
        let outcome = ScheduleEndNotifier.emitScheduleEnd(
            scheduleId: "nightly",
            summary: "success",
            sessionId: "schedule:nightly:run-1",
            socketPath: missing
        )
        #expect(outcome == .socketUnreachable,
                "App not running ⇒ silent no-op; the DB row is canonical truth")
    }

    @Test("the emit payload carries the exact wire shape the consumer reads")
    func emitPayloadShape() {
        let sid = ScheduleTelemetry.sessionId(taskName: "nightly", runId: "20260609000000-abc123")
        let data = ScheduleEndNotifier.makeEmitPayload(
            scheduleId: "nightly", summary: "failed: exit 1", sessionId: sid
        )
        let obj = try? JSONSerialization.jsonObject(with: data!) as? [String: Any]
        #expect(obj?["hook_event_name"] as? String == "schedule_end")
        #expect(obj?["schedule_id"] as? String == "nightly")
        #expect(obj?["summary"] as? String == "failed: exit 1")
        #expect(obj?["session_id"] as? String == sid,
                "session_id must match ScheduleTelemetry's derivation for reconcile dedup")
    }

    @Test("a payload built by the producer round-trips through the HookRouter consumer")
    func emitPayloadRoutesThroughConsumer() {
        HookSeamLock.withLock {
            // Capture what the consumer extracts from the producer's payload.
            var captured: (String, String, String)?
            let prior = HookRouter.scheduleEndDeliver
            HookRouter.scheduleEndDeliver = { s, summary, sid in
                captured = (s, summary, sid)
                return true
            }
            defer { HookRouter.scheduleEndDeliver = prior }

            let sid = ScheduleTelemetry.sessionId(taskName: "weekly", runId: "run-9")
            let payload = ScheduleEndNotifier.makeEmitPayload(
                scheduleId: "weekly", summary: "success", sessionId: sid
            )!
            _ = HookRouter.handle(eventJSON: payload)

            #expect(captured?.0 == "weekly")
            #expect(captured?.1 == "success")
            #expect(captured?.2 == sid,
                    "the producer's payload and the consumer's extraction agree end-to-end")
        }
    }
}
