import Testing
import Foundation
@testable import Core

/// U.9b-3 — the `EventStreamDispatcher` consumer-pull-loop spine. The final
/// carve-child of `phase-u9b-session-work-bus-migration` (leg u9b-3).
///
/// FLAKE-DISCIPLINE (Carmack R7/R8, parent acceptance line 66): these tests
/// are STRUCTURALLY free of the `Task.detached(.utility)` cooperative-pool-
/// starvation pattern that caused the original U.9b 5s flake. They drive the
/// SYNCHRONOUS pull → process → commit contract directly via
/// `drainOnce`/`drainToHead` — there is NO wall-clock loop-timing assertion
/// anywhere ("the loop fired within N ms" is never tested). The default-OFF
/// idle invariant is pinned by injecting the flag closure and asserting the
/// dispatcher performs ZERO pulls/commits — again with no timing dependence.
@Suite("U.9b-3 — EventStreamDispatcher consumer pull loops", .serialized)
struct EventStreamDispatcherTests {

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u9b3-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    /// Append `n` events and flush so the synchronous reads see them.
    private static func appendEvents(_ db: SessionDatabase, _ n: Int, kind: String = "test") {
        for i in 0..<n {
            _ = db.sessionEventStreamStore.appendEvent(
                sourceTable: "token_events", sourceId: Int64(i), kind: kind
            )
        }
        db.flushWrites()
    }

    // MARK: - Test 1: offset advances correctly across a consumer "restart"

    @Test("offset persists across dispatcher restart: no replay of committed events, no skip of uncommitted")
    func offsetAdvancesAcrossRestart() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        Self.appendEvents(db, 5)

        // First dispatcher instance ("process A"): drain everything.
        var seenA: [Int64] = []
        let dispatcherA = EventStreamDispatcher(
            store: db.sessionEventStreamStore,
            dualWriteEnabled: { true }
        )
        dispatcherA.register(consumerId: EventStreamDispatcher.ConsumerId.validation) { batch in
            seenA.append(contentsOf: batch.map(\.id))
        }
        let processedA = dispatcherA.drainToHead(consumerId: EventStreamDispatcher.ConsumerId.validation)
        db.flushWrites()
        #expect(processedA == 5, "first drain must process all 5 events")
        #expect(seenA == [1, 2, 3, 4, 5], "events delivered in id order, exactly once")
        #expect(db.sessionEventStreamStore.lag(consumerId: "validation") == 0, "consumer is caught up")

        // Append 3 MORE events while "process A" is gone.
        Self.appendEvents(db, 3, kind: "post-restart")

        // Second dispatcher instance ("process B") — fresh object, same
        // persisted offset row. It must NOT replay 1..5 and must NOT skip
        // 6..8.
        var seenB: [Int64] = []
        let dispatcherB = EventStreamDispatcher(
            store: db.sessionEventStreamStore,
            dualWriteEnabled: { true }
        )
        dispatcherB.register(consumerId: EventStreamDispatcher.ConsumerId.validation) { batch in
            seenB.append(contentsOf: batch.map(\.id))
        }
        let processedB = dispatcherB.drainToHead(consumerId: EventStreamDispatcher.ConsumerId.validation)
        #expect(processedB == 3, "restart must process only the 3 NEW events (no replay)")
        #expect(seenB == [6, 7, 8], "the 3 uncommitted events are delivered, the 5 committed are not replayed")
        #expect(db.sessionEventStreamStore.lag(consumerId: "validation") == 0)
    }

    // MARK: - Test 2: backpressure — pull limit respected; loop makes progress

    @Test("backpressure: a single drain never exceeds pullLimit; drainToHead makes progress across multiple drains")
    func backpressureLimitRespected() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // 25 events, pull limit 10 ⇒ batches of 10, 10, 5.
        Self.appendEvents(db, 25)

        var batchSizes: [Int] = []
        let dispatcher = EventStreamDispatcher(
            store: db.sessionEventStreamStore,
            pullLimit: 10,
            dualWriteEnabled: { true }
        )
        dispatcher.register(consumerId: EventStreamDispatcher.ConsumerId.agentTimeline) { batch in
            batchSizes.append(batch.count)
        }

        // First drainOnce: exactly 10 (the limit), never more.
        let first = dispatcher.drainOnce(consumerId: EventStreamDispatcher.ConsumerId.agentTimeline)
        db.flushWrites()
        #expect(first == 10, "a single drain must respect the pull limit (10)")
        #expect(batchSizes == [10], "the batch handed to the handler never exceeds the limit")

        // drainToHead clears the rest, still in limit-bounded batches.
        let rest = dispatcher.drainToHead(consumerId: EventStreamDispatcher.ConsumerId.agentTimeline)
        #expect(rest == 15, "the remaining 15 are processed across further bounded drains")
        #expect(batchSizes == [10, 10, 5], "every batch is <= the pull limit; the loop makes progress")
        #expect(batchSizes.allSatisfy { $0 <= 10 }, "no batch ever exceeds the pull limit")
        #expect(db.sessionEventStreamStore.lag(consumerId: "agent_timeline") == 0)
    }

    // MARK: - Test 3: flag-flip — idle when OFF; toggling loses no events, double-delivers none

    @Test("flag-flip: dispatcher idle when dualWrite OFF (zero pulls/commits); enabling then disabling loses no events and double-delivers none")
    func flagFlipNoLossNoDup() async {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        Self.appendEvents(db, 4)

        // FLAG OFF: start() must keep the dispatcher idle — zero pulls,
        // zero commits, offset untouched. (Allspaw default-safe.)
        var flag = false
        var delivered: [Int64] = []
        let dispatcher = EventStreamDispatcher(
            store: db.sessionEventStreamStore,
            dualWriteEnabled: { flag }
        )
        dispatcher.register(consumerId: EventStreamDispatcher.ConsumerId.validation) { batch in
            delivered.append(contentsOf: batch.map(\.id))
        }

        dispatcher.start(clock: ContinuousClock())
        #expect(dispatcher.isRunning == false, "flag OFF ⇒ start() spawns no loops (idle)")
        #expect(delivered.isEmpty, "flag OFF ⇒ zero events delivered")
        #expect(db.sessionEventStreamStore.lag(consumerId: "validation") == 4,
                "flag OFF ⇒ offset untouched; all 4 events still pending")

        // Operator flips the flag ON. We drive the contract via the
        // synchronous seam (NOT by asserting on loop wall-clock timing).
        flag = true
        let processed = dispatcher.drainToHead(consumerId: EventStreamDispatcher.ConsumerId.validation)
        db.flushWrites()
        #expect(processed == 4, "flag ON ⇒ the 4 events are delivered exactly once")
        #expect(delivered == [1, 2, 3, 4], "no event lost, none double-delivered")
        #expect(db.sessionEventStreamStore.lag(consumerId: "validation") == 0)

        // Operator flips the flag back OFF — stop() unwinds cleanly; a
        // re-start with the flag OFF stays idle and re-delivers NOTHING
        // (offset already advanced ⇒ no double-delivery).
        flag = false
        dispatcher.stop()
        dispatcher.start(clock: ContinuousClock())
        #expect(dispatcher.isRunning == false)
        #expect(delivered == [1, 2, 3, 4], "toggling OFF again double-delivers nothing")

        // And a final flag-ON drain on a now-caught-up consumer is a no-op
        // (the offset gate prevents replay).
        flag = true
        let replay = dispatcher.drainToHead(consumerId: EventStreamDispatcher.ConsumerId.validation)
        #expect(replay == 0, "caught-up consumer re-drains nothing — no double-delivery")
        #expect(delivered == [1, 2, 3, 4])
    }

    // MARK: - Test 4: notifications consumer is a pure lag-recording stub

    @Test("notifications consumer is a no-op-recording stub: advances offset + records lag, zero side effects")
    func notificationsConsumerIsPureStub() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        Self.appendEvents(db, 6)

        // Use the `standard` factory — notifications must be wired as the
        // explicit no-op stub (T.6c owns the real body).
        guard let dispatcher = EventStreamDispatcher.standard(
            db: db, dualWriteEnabled: { true }
        ) else {
            Issue.record("standard() must build with a live event-stream store")
            return
        }
        #expect(dispatcher.registeredConsumerIds() == EventStreamDispatcher.ConsumerId.all,
                "the four standard consumers register in order")

        // Snapshot side-effect surfaces the stub must NOT touch: no event
        // counters, no work-queue rows.
        let countersBefore = db.eventCounts().count
        let queueBefore = db.sessionWorkQueueStore.diagnostics().pending

        let processed = dispatcher.drainToHead(consumerId: EventStreamDispatcher.ConsumerId.notifications)
        db.flushWrites()

        // Offset advanced (lag → 0) and the batch was consumed...
        #expect(processed == 6, "notifications stub still advances its offset past the batch")
        #expect(dispatcher.lag(consumerId: EventStreamDispatcher.ConsumerId.notifications) == 0,
                "notifications stub records lag (drains to head)")

        // ...but produced ZERO side effects (no counters minted, no queue rows).
        db.flushWrites()
        #expect(db.eventCounts().count == countersBefore,
                "notifications stub must emit no event counters (pure no-op body)")
        #expect(db.sessionWorkQueueStore.diagnostics().pending == queueBefore,
                "notifications stub must enqueue no work-queue rows")
    }
}
