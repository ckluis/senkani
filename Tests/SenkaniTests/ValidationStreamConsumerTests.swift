import Testing
import Foundation
@testable import Core

/// U.9b-3b (leg 1/4) — the `validation` consumer's real-work wiring:
/// `ValidationStreamConsumer` drains `validation_results` events from
/// `session_event_stream` and drives the `auto_validate.delivered` path,
/// commitOffset-driven, with an idempotent row-level claim.
///
/// FLAKE-DISCIPLINE (parent acceptance, R7/R8): no `Task.detached(.utility)`,
/// no second cooperative-pool hop, no wall-clock loop-timing assertion —
/// these tests drive the spine's SYNCHRONOUS `drainOnce`/`drainToHead`
/// seams and the handler's `process` function directly.
@Suite("U.9b-3b leg 1 — validation consumer real work", .serialized)
struct ValidationStreamConsumerTests {

    private static let root = "/tmp/u9b3b-leg1"

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u9b3b-leg1-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    /// Sum of `auto_validate.delivered` counters across roots.
    private static func deliveredCount(_ db: SessionDatabase) -> Int {
        db.eventCounts(prefix: ValidationStreamConsumer.deliveredEventType)
            .reduce(0) { $0 + $1.count }
    }

    /// Insert canonical validation rows (2 advisory + 1 clean) for `sid`,
    /// mirror each onto `session_event_stream`, and return
    /// (advisoryIds, cleanId).
    private static func seedRows(
        _ db: SessionDatabase, sid: String
    ) -> (advisory: [Int64], clean: Int64) {
        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/a.swift", validatorName: "swiftc",
            category: "type", exitCode: 1, rawOutput: "err A",
            advisory: "'a' is undefined", durationMs: 10
        )
        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/b.swift", validatorName: "swiftc",
            category: "type", exitCode: 1, rawOutput: "err B",
            advisory: "'b' is undefined", durationMs: 11
        )
        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/c.swift", validatorName: "swiftc",
            category: "type", exitCode: 0, rawOutput: nil,
            advisory: "", durationMs: 12
        )
        db.flushWrites()
        let rows = db.validationResults(sessionId: sid)
        let advisoryIds = rows.filter { $0.outcome == "advisory" }.map(\.id).sorted()
        let cleanId = rows.first { $0.outcome == "clean" }!.id
        // Producer-side mirror (what the u9b outbox emits when dual-write
        // is on): one stream event per canonical row.
        for id in advisoryIds + [cleanId] {
            _ = db.sessionEventStreamStore.appendEvent(
                sourceTable: "validation_results", sourceId: id,
                kind: "validation_results", projectRoot: root
            )
        }
        // An unrelated event the validation consumer must skip (offset
        // still advances past it, zero side effects from it).
        _ = db.sessionEventStreamStore.appendEvent(
            sourceTable: "token_events", sourceId: 999,
            kind: "token_events", projectRoot: root
        )
        db.flushWrites()
        return (advisoryIds, cleanId)
    }

    // MARK: - Test 1: exactly-once per event, offset-driven + idempotent

    @Test("standard-factory validation consumer drives delivery exactly once per event; restart replay and raw handler replay both double-drive nothing")
    func realWorkExactlyOnce() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let sid = "u9b3b-leg1-session"
        let (advisoryIds, _) = Self.seedRows(db, sid: sid)
        #expect(advisoryIds.count == 2)
        #expect(db.pendingValidationAdvisories(sessionId: sid).count == 2)

        // Capture the raw batch BEFORE draining so we can later replay the
        // exact events the consumer saw (the crash-between-handler-and-
        // commit scenario, where the offset did NOT advance).
        let rawBatch = db.sessionEventStreamStore.pullSince(
            consumerId: EventStreamDispatcher.ConsumerId.validation, limit: 100
        )
        #expect(rawBatch.count == 4, "2 advisory + 1 clean + 1 unrelated event on the stream")

        // The STANDARD factory must wire the real handler (registration is
        // part of this leg) — not the lag-only default.
        guard let dispatcher = EventStreamDispatcher.standard(
            db: db, dualWriteEnabled: { true }
        ) else {
            Issue.record("standard() must build with a live event-stream store")
            return
        }
        let processed = dispatcher.drainToHead(
            consumerId: EventStreamDispatcher.ConsumerId.validation
        )
        db.flushWrites()
        #expect(processed == 4, "the consumer advances past ALL events (clean + unrelated included)")
        #expect(dispatcher.lag(consumerId: EventStreamDispatcher.ConsumerId.validation) == 0)

        // REAL side effect, exactly once per advisory event: both advisory
        // rows are claimed (no longer pending) and the delivered counter
        // shows exactly 2. The clean row + unrelated event drive nothing.
        #expect(Self.deliveredCount(db) == 2,
                "exactly one auto_validate.delivered per advisory event")
        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty,
                "claimed rows are delivered+surfaced (commitOffset-driven delivery)")

        // RESTART replay (offset WAS committed): a fresh dispatcher on the
        // same persisted offsets re-delivers nothing.
        guard let restarted = EventStreamDispatcher.standard(
            db: db, dualWriteEnabled: { true }
        ) else {
            Issue.record("standard() must build on restart")
            return
        }
        let replayed = restarted.drainToHead(
            consumerId: EventStreamDispatcher.ConsumerId.validation
        )
        db.flushWrites()
        #expect(replayed == 0, "restart after commitOffset replays nothing")
        #expect(Self.deliveredCount(db) == 2, "restart does NOT double-drive")

        // CRASH replay (offset NOT committed): re-process the exact same
        // batch through the handler — the idempotent claim loses on every
        // already-claimed row and drives nothing.
        let redriven = ValidationStreamConsumer.process(db: db, batch: rawBatch)
        db.flushWrites()
        #expect(redriven == 0, "row-level claim makes the handler idempotent under replay")
        #expect(Self.deliveredCount(db) == 2, "raw replay does NOT double-drive")
    }

    // MARK: - Test 2: default-OFF means zero side effects

    @Test("default-OFF: dispatcher stays idle and the validation consumer drives zero side effects")
    func defaultOffZeroSideEffects() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let sid = "u9b3b-leg1-off-session"
        _ = Self.seedRows(db, sid: sid)

        guard let dispatcher = EventStreamDispatcher.standard(
            db: db, dualWriteEnabled: { false }
        ) else {
            Issue.record("standard() must build with a live event-stream store")
            return
        }

        // Flag OFF (the default): start() spawns no loops — synchronous
        // check, no wall-clock dependence.
        dispatcher.start(clock: ContinuousClock())
        #expect(dispatcher.isRunning == false, "dualWrite OFF ⇒ dispatcher idle")
        dispatcher.stop()
        db.flushWrites()

        // Zero side effects: no delivered counters, rows still pending,
        // offset untouched (all 4 events still ahead of the consumer).
        #expect(Self.deliveredCount(db) == 0,
                "default-OFF ⇒ zero auto_validate.delivered counters")
        #expect(db.pendingValidationAdvisories(sessionId: sid).count == 2,
                "default-OFF ⇒ advisory rows stay pending for the in-process leg")
        #expect(db.sessionEventStreamStore.lag(
            consumerId: EventStreamDispatcher.ConsumerId.validation) == 4,
            "default-OFF ⇒ offset untouched")
    }
}
