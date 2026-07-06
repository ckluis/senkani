import Testing
import Foundation
@testable import Core

/// U.9c-3 — Validation-consumer advisory-claim semantics under `dualWrite`
/// ON, with BOTH the bus leg (`ValidationStreamConsumer` /
/// `EventStreamDispatcher`) and the still-running in-process leg
/// (HookRouter's `appendAndMarkValidationIfSurfaced`, modelled here) live.
///
/// ## What this pins (parity-window contract)
///
/// During the dual-write parity window both legs observe the same canonical
/// `validation_results` row. The exactly-once arbiter is the guarded UPDATE
/// shared by both legs:
///
///   - Bus leg: `claimValidationDelivery(resultId:)` —
///     `WHERE outcome='advisory' AND exit_code!=0 AND delivered=0 AND
///     surfaced_at IS NULL`; returns whether THIS call flipped the row.
///   - In-process leg: gates on `pendingValidationAdvisories(sessionId:)`,
///     whose WHERE clause is byte-identical (`surfaced_at IS NULL AND
///     delivered=0 AND outcome='advisory' AND exit_code!=0`), then
///     `markValidationAdvisoriesSurfaced` + records `auto_validate.delivered`.
///
/// Because both legs funnel their 0→1 flip through the SAME guard, one
/// canonical row yields exactly one delivery effect regardless of ordering —
/// the loser is a clean no-op. These fixtures prove that in both orderings,
/// under crash-between-claim-and-commitOffset, and under interleaved
/// multi-row handoff (no-drop).
///
/// ## FLAKE-DISCIPLINE (parent acceptance, R7/R8)
///
/// Deterministic, fully synchronous: no `Task.detached(.utility)`, no second
/// cooperative-pool hop, no wall-clock loop-timing assertion. Every leg
/// operation serializes on `SessionDatabase`'s own serial queue, so the
/// interleavings below are expressed as ORDERED calls (a serial queue makes a
/// later `queue.sync` claim observe an earlier `queue.async` mark), not real
/// thread races. The bus spine is driven via the synchronous
/// `drainOnce`/`drainToHead`/`process` seams.
@Suite("U.9c-3 — validation consumer dual-leg advisory-claim exactly-once", .serialized)
struct ValidationConsumerDualLegClaimTests {

    private static let root = "/tmp/u9c3-dualleg"
    private static let validationConsumer = EventStreamDispatcher.ConsumerId.validation

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u9c3-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    /// Sum of `auto_validate.delivered` counters across roots.
    private static func deliveredCount(_ db: SessionDatabase) -> Int {
        db.eventCounts(prefix: ValidationStreamConsumer.deliveredEventType)
            .reduce(0) { $0 + $1.count }
    }

    /// Sum of the four `session_work_bus.parity_*` counters. These belong to
    /// the WORKER-enqueue dual-write leg (`AutoValidateDualWrite` onto
    /// `SessionWorkQueueStore`), NOT the delivery/claim leg under test — the
    /// stream-consumer path must mint ZERO of them.
    private static func parityCount(_ db: SessionDatabase) -> Int {
        db.eventCounts(prefix: "session_work_bus.parity_")
            .reduce(0) { $0 + $1.count }
    }

    /// Insert `n` advisory rows for `sid` and mirror each onto
    /// `session_event_stream` (what the u9b outbox emits under dualWrite ON).
    /// Optionally seed one clean row + one unrelated `token_events` event the
    /// consumer must skip. Returns the sorted advisory row ids.
    @discardableResult
    private static func seedAdvisories(
        _ db: SessionDatabase, sid: String, n: Int,
        clean: Bool = true, unrelated: Bool = true
    ) -> [Int64] {
        for i in 0..<n {
            db.insertValidationResult(
                sessionId: sid, filePath: "/tmp/adv\(i).swift", validatorName: "swiftc",
                category: "type", exitCode: 1, rawOutput: "err \(i)",
                advisory: "'x\(i)' is undefined", durationMs: 10
            )
        }
        if clean {
            db.insertValidationResult(
                sessionId: sid, filePath: "/tmp/clean.swift", validatorName: "swiftc",
                category: "type", exitCode: 0, rawOutput: nil,
                advisory: "", durationMs: 12
            )
        }
        db.flushWrites()
        let rows = db.validationResults(sessionId: sid)
        let advisoryIds = rows.filter { $0.outcome == "advisory" }.map(\.id).sorted()
        // Producer-side mirror: one stream event per canonical row (advisory
        // + clean), in id order.
        for row in rows.sorted(by: { $0.id < $1.id }) {
            _ = db.sessionEventStreamStore.appendEvent(
                sourceTable: "validation_results", sourceId: row.id,
                kind: "validation_results", projectRoot: root
            )
        }
        if unrelated {
            _ = db.sessionEventStreamStore.appendEvent(
                sourceTable: "token_events", sourceId: 999,
                kind: "token_events", projectRoot: root
            )
        }
        db.flushWrites()
        return advisoryIds
    }

    /// Faithful model of the in-process delivery leg
    /// (`HookRouter.appendAndMarkValidationIfSurfaced`): it surfaces ONLY
    /// rows still returned by `pendingValidationAdvisories` (identical guard
    /// to the bus claim), marks them, and records ONE
    /// `auto_validate.delivered` per surfacing call. Returns the ids it
    /// actually surfaced (empty when nothing is pending — the bus already
    /// claimed everything). `ids` optionally restricts surfacing to a subset
    /// (models a hook that only surfaces the advisories for the tool it is
    /// gating).
    @discardableResult
    private static func inProcessDeliver(
        _ db: SessionDatabase, sid: String, restrictTo ids: Set<Int64>? = nil
    ) -> [Int64] {
        var pending = db.pendingValidationAdvisories(sessionId: sid).map(\.id)
        if let ids { pending = pending.filter { ids.contains($0) } }
        guard !pending.isEmpty else { return [] }
        db.markValidationAdvisoriesSurfaced(ids: pending)
        db.recordEvent(type: "auto_validate.delivered", projectRoot: root)
        db.flushWrites()
        return pending.sorted()
    }

    // MARK: - Test 1: exactly-once, in-process leg wins first

    @Test("dual-leg exactly-once — in-process surfaces first; bus claim is a clean no-op")
    func exactlyOnceInProcessWinsFirst() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let sid = "u9c3-inproc-first"
        let adv = Self.seedAdvisories(db, sid: sid, n: 1)
        #expect(adv.count == 1)

        // In-process leg delivers first.
        let surfaced = Self.inProcessDeliver(db, sid: sid)
        #expect(surfaced == adv, "in-process surfaces the one pending advisory")
        #expect(Self.deliveredCount(db) == 1)
        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty)

        // Bus leg drains the same events: claim LOSES on the already-surfaced
        // advisory, drives nothing; offset still advances past every event.
        guard let dispatcher = EventStreamDispatcher.standard(db: db, dualWriteEnabled: { true }) else {
            Issue.record("standard() must build with a live event-stream store"); return
        }
        let processed = dispatcher.drainToHead(consumerId: Self.validationConsumer)
        db.flushWrites()
        #expect(processed == 3, "bus advances past advisory + clean + unrelated event")
        #expect(dispatcher.lag(consumerId: Self.validationConsumer) == 0, "offset not stranded")
        #expect(Self.deliveredCount(db) == 1, "bus claim lost — exactly one delivery effect total")
        #expect(Self.parityCount(db) == 0, "delivery leg mints no session_work_bus.parity_* counters")
    }

    // MARK: - Test 2: exactly-once, bus leg wins first

    @Test("dual-leg exactly-once — bus claims first; in-process re-read finds nothing pending (clean no-op)")
    func exactlyOnceBusWinsFirst() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let sid = "u9c3-bus-first"
        let adv = Self.seedAdvisories(db, sid: sid, n: 1)
        #expect(adv.count == 1)

        // Bus leg drains + claims first.
        guard let dispatcher = EventStreamDispatcher.standard(db: db, dualWriteEnabled: { true }) else {
            Issue.record("standard() must build with a live event-stream store"); return
        }
        let processed = dispatcher.drainToHead(consumerId: Self.validationConsumer)
        db.flushWrites()
        #expect(processed == 3)
        #expect(Self.deliveredCount(db) == 1, "bus claim wins exactly once")
        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty, "row claimed — no longer pending")

        // In-process leg runs next: its pending-gate (identical WHERE clause)
        // returns nothing, so it surfaces nothing and records no counter.
        let surfaced = Self.inProcessDeliver(db, sid: sid)
        #expect(surfaced.isEmpty, "bus already claimed — in-process finds nothing pending, no-op")
        #expect(Self.deliveredCount(db) == 1, "in-process no-op — exactly one delivery effect total")
        #expect(Self.parityCount(db) == 0)
    }

    // MARK: - Test 3: crash between claim and commitOffset

    @Test("crash after claim before commitOffset — restart re-delivers nothing (idempotent claim) and does not strand the offset")
    func crashBetweenClaimAndCommitOffset() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let sid = "u9c3-crash"
        let adv = Self.seedAdvisories(db, sid: sid, n: 1)
        #expect(adv.count == 1)

        // Model the crash window: pull the batch and run the handler
        // (`process` CLAIMS + counts) but DO NOT commit the offset —
        // `process` never touches the offset; only the dispatcher's
        // `drainOnce` commits. This is exactly "claimed, then crashed before
        // commitOffset."
        let rawBatch = db.sessionEventStreamStore.pullSince(consumerId: Self.validationConsumer, limit: 100)
        #expect(rawBatch.count == 3, "advisory + clean + unrelated")
        let drivenBeforeCrash = ValidationStreamConsumer.process(db: db, batch: rawBatch)
        db.flushWrites()
        #expect(drivenBeforeCrash == 1, "handler claimed the one advisory")
        #expect(Self.deliveredCount(db) == 1)
        // Offset was NOT committed — the row is delivered but the cursor is
        // still behind (redrive is pending, not stranded).
        #expect(db.sessionEventStreamStore.lag(consumerId: Self.validationConsumer) == 3,
                "offset uncommitted after the crash window — full backlog still ahead of the cursor")

        // Restart: a fresh dispatcher re-pulls the SAME events (offset never
        // advanced). The idempotent claim loses on the already-delivered row,
        // so nothing is re-delivered — and this drain DOES commit the offset,
        // so the cursor is no longer stranded.
        guard let restarted = EventStreamDispatcher.standard(db: db, dualWriteEnabled: { true }) else {
            Issue.record("standard() must build on restart"); return
        }
        let processedOnRestart = restarted.drainToHead(consumerId: Self.validationConsumer)
        db.flushWrites()
        #expect(processedOnRestart == 3, "restart re-pulls the uncommitted batch (offset was stranded until now)")
        #expect(Self.deliveredCount(db) == 1, "idempotent claim: crash-replay drives nothing new")
        #expect(restarted.lag(consumerId: Self.validationConsumer) == 0, "offset advanced — no longer stranded")
        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty)
    }

    // MARK: - Test 4: no drop-on-handoff — interleaved dual-leg claims

    @Test("no drop-on-handoff — interleaved claims (in-process pre-claims a subset, bus drains the rest); every row delivered exactly once, offset skips nothing")
    func noDropOnHandoffInterleaved() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let sid = "u9c3-interleave"
        let adv = Self.seedAdvisories(db, sid: sid, n: 4)
        #expect(adv.count == 4)

        // Interleave: the in-process leg pre-claims the even-indexed
        // advisories (rows 0 and 2); the odd-indexed ones (1 and 3) are still
        // pending when the bus runs.
        let inProcessTargets: Set<Int64> = [adv[0], adv[2]]
        let surfaced = Self.inProcessDeliver(db, sid: sid, restrictTo: inProcessTargets)
        #expect(Set(surfaced) == inProcessTargets, "in-process pre-claims exactly rows 0 and 2")
        #expect(Self.deliveredCount(db) == 1, "in-process records one delivered event for its surfacing call")
        #expect(Set(db.pendingValidationAdvisories(sessionId: sid).map(\.id)) == [adv[1], adv[3]],
                "rows 1 and 3 remain pending for the bus")

        // Bus drains the WHOLE stream (offset at 0): it attempts a claim on
        // every advisory event — the two in-process-claimed rows lose (no
        // double-deliver), the two still-pending rows win (no drop). Offset
        // advances past every event, advisory or not.
        let deliveredBeforeBus = Self.deliveredCount(db)
        guard let dispatcher = EventStreamDispatcher.standard(db: db, dualWriteEnabled: { true }) else {
            Issue.record("standard() must build"); return
        }
        let processed = dispatcher.drainToHead(consumerId: Self.validationConsumer)
        db.flushWrites()
        // 4 advisory + 1 clean + 1 unrelated event.
        #expect(processed == 6, "bus advances past every stream event — no row skipped on handoff")
        #expect(dispatcher.lag(consumerId: Self.validationConsumer) == 0, "offset caught up — nothing stranded")

        let busDrove = Self.deliveredCount(db) - deliveredBeforeBus
        #expect(busDrove == 2, "bus delivers exactly the two rows in-process did NOT claim (no drop, no double)")

        // Every advisory row is delivered exactly once (pending set empty),
        // and no undelivered row was skipped by the offset advance.
        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty,
                "all four rows delivered exactly once across the two legs")
        let delivered = db.validationResults(sessionId: sid, outcome: "advisory")
            .filter { $0.surfacedAt != nil }
        #expect(delivered.count == 4, "every advisory row flipped to delivered/surfaced")

        // A follow-up drain re-delivers nothing (offset gate + idempotent claim).
        let redrive = dispatcher.drainToHead(consumerId: Self.validationConsumer)
        #expect(redrive == 0, "caught-up consumer re-drains nothing")
        #expect(Self.parityCount(db) == 0, "delivery leg minted no parity counters throughout")
    }

    // MARK: - Test 5: default-OFF byte-identical — dual-leg change is inert

    @Test("dualWrite OFF — bus stays idle, only the in-process leg delivers; zero stream claims, zero parity counters, offset untouched")
    func defaultOffDualLegInert() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let sid = "u9c3-off"
        let adv = Self.seedAdvisories(db, sid: sid, n: 1)
        #expect(adv.count == 1)

        // dualWrite OFF: the dispatcher must stay idle (Allspaw fail-safe).
        guard let dispatcher = EventStreamDispatcher.standard(db: db, dualWriteEnabled: { false }) else {
            Issue.record("standard() must build with a live event-stream store"); return
        }
        dispatcher.start(clock: ContinuousClock())
        #expect(dispatcher.isRunning == false, "dualWrite OFF ⇒ dispatcher idle (no bus leg)")
        dispatcher.stop()
        db.flushWrites()

        // Only the in-process leg runs — exactly the pre-bus world.
        let surfaced = Self.inProcessDeliver(db, sid: sid)
        #expect(surfaced == adv, "in-process delivers normally with the bus disabled")
        #expect(Self.deliveredCount(db) == 1, "exactly one delivery effect — the in-process leg's")

        // The bus consumer never ran: its offset is untouched (every stream
        // event still ahead of the cursor), it minted no delivered counter of
        // its own, and no parity counter exists. Byte-identical to OFF.
        #expect(db.sessionEventStreamStore.lag(consumerId: Self.validationConsumer) == 3,
                "dualWrite OFF ⇒ bus offset untouched (advisory + clean + unrelated events still pending)")
        #expect(Self.parityCount(db) == 0, "dualWrite OFF ⇒ zero parity counters")
    }

    // MARK: - Test 6: the stream-consumer leg mints no new counters

    @Test("delivery/claim leg mints no session_work_bus.parity_* counters — those belong to the worker-enqueue leg, not the consumer")
    func streamConsumerLegMintsNoParityCounters() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let sid = "u9c3-noparity"
        Self.seedAdvisories(db, sid: sid, n: 2)

        // Full dual-leg run: in-process surfaces one, bus drains the rest.
        _ = Self.inProcessDeliver(db, sid: sid, restrictTo: nil) // surfaces both pending
        guard let dispatcher = EventStreamDispatcher.standard(db: db, dualWriteEnabled: { true }) else {
            Issue.record("standard() must build"); return
        }
        dispatcher.drainToHead(consumerId: Self.validationConsumer)
        db.flushWrites()

        // The ONLY delivery counter minted is auto_validate.delivered; the
        // four parity counters (parity_match / parity_diverge /
        // parity_bus_only / parity_inprocess_only) are the WORKER-enqueue
        // leg's truth table (AutoValidateDualWrite → SessionWorkQueueStore)
        // and must stay at zero for the delivery/claim path. No new counter
        // is minted for the dual-leg delivery scenario — divergence is
        // observable directly via auto_validate.delivered.
        #expect(db.eventCounts(prefix: AutoValidateDualWrite.parityMatch).isEmpty)
        #expect(db.eventCounts(prefix: AutoValidateDualWrite.parityDiverge).isEmpty)
        #expect(db.eventCounts(prefix: AutoValidateDualWrite.parityBusOnly).isEmpty)
        #expect(db.eventCounts(prefix: AutoValidateDualWrite.parityInProcessOnly).isEmpty)
        #expect(Self.parityCount(db) == 0, "delivery leg introduces no parity counters")
        #expect(Self.deliveredCount(db) >= 1, "at least one delivery effect recorded")
    }

    // MARK: - Test 7: out-of-order stream offsets — claim is keyed on row identity, not order

    @Test("out-of-order offsets — stream events appended in reverse row-id order (unrelated event interleaved); every advisory delivered exactly once, no double, no drop, offset caught up")
    func outOfOrderOffsetsDeliverExactlyOnce() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let sid = "u9c3-ooo"

        // Seed advisory rows WITHOUT the seedAdvisories mirror so we control
        // the stream-event offset order independently of row-id order.
        let n = 4
        for i in 0..<n {
            db.insertValidationResult(
                sessionId: sid, filePath: "/tmp/ooo\(i).swift", validatorName: "swiftc",
                category: "type", exitCode: 1, rawOutput: "err \(i)",
                advisory: "'y\(i)' is undefined", durationMs: 10
            )
        }
        db.flushWrites()
        let adv = db.validationResults(sessionId: sid, outcome: "advisory").map(\.id).sorted()
        #expect(adv.count == n)

        // Append the stream events in REVERSE row-id order, and splice an
        // unrelated event into the middle of the sequence. The consumer's
        // exactly-once guarantee must not depend on stream order matching
        // row-id order — the claim is keyed on `resultId`, not offset.
        let reversed = Array(adv.reversed())
        for (idx, rid) in reversed.enumerated() {
            _ = db.sessionEventStreamStore.appendEvent(
                sourceTable: "validation_results", sourceId: rid,
                kind: "validation_results", projectRoot: Self.root
            )
            if idx == reversed.count / 2 {
                _ = db.sessionEventStreamStore.appendEvent(
                    sourceTable: "token_events", sourceId: 999,
                    kind: "token_events", projectRoot: Self.root
                )
            }
        }
        db.flushWrites()

        // Bus drains the whole out-of-order stream under dualWrite ON.
        guard let dispatcher = EventStreamDispatcher.standard(db: db, dualWriteEnabled: { true }) else {
            Issue.record("standard() must build with a live event-stream store"); return
        }
        let processed = dispatcher.drainToHead(consumerId: Self.validationConsumer)
        db.flushWrites()
        #expect(processed == n + 1, "bus advances past every stream event (4 advisory + 1 unrelated), regardless of order")
        #expect(dispatcher.lag(consumerId: Self.validationConsumer) == 0, "offset caught up — nothing stranded despite reordering")
        #expect(Self.deliveredCount(db) == n, "every advisory delivered exactly once — no double, no drop under reordering")

        let delivered = db.validationResults(sessionId: sid, outcome: "advisory")
            .filter { $0.surfacedAt != nil }
            .map(\.id).sorted()
        #expect(delivered == adv, "all four rows flipped to delivered exactly once, order-independent")
        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty)

        // Redrive is a clean no-op (offset gate + idempotent claim).
        let redrive = dispatcher.drainToHead(consumerId: Self.validationConsumer)
        #expect(redrive == 0, "caught-up consumer re-drains nothing")
        #expect(Self.parityCount(db) == 0, "delivery leg minted no parity counters")
    }
}
