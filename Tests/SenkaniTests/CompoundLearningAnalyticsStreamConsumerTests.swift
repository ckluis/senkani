import Testing
import Foundation
@testable import Core

/// U.9b-3b (leg 2/4) — the `compound_learning_analytics` consumer's
/// real-work wiring: `CompoundLearningAnalyticsStreamConsumer` drains
/// `token_events` / `agent_trace_event` events from
/// `session_event_stream` and drives `compound_learning.analytics.*`
/// rollup counters via the existing `recordEvent` / `event_counters`
/// path, commitOffset-driven, with an applied-watermark idempotent claim.
///
/// FLAKE-DISCIPLINE (parent acceptance, R7/R8): no `Task.detached(.utility)`,
/// no second cooperative-pool hop, no wall-clock loop-timing assertion —
/// these tests drive the spine's SYNCHRONOUS `drainOnce`/`drainToHead`
/// seams and the handler's `process` function directly.
@Suite("U.9b-3b leg 2 — compound_learning_analytics consumer real work", .serialized)
struct CompoundLearningAnalyticsStreamConsumerTests {

    private static let root = "/tmp/u9b3b-leg2"

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u9b3b-leg2-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    /// Per-type sums of `compound_learning.analytics.*` counters across roots.
    private static func rollupCounts(_ db: SessionDatabase) -> [String: Int] {
        var out: [String: Int] = [:]
        let prefix = CompoundLearningAnalyticsStreamConsumer.rollupEventTypePrefix
        for row in db.eventCounts(prefix: prefix) {
            out[row.eventType, default: 0] += row.count
        }
        return out
    }

    /// Seed the stream with this consumer's analytics inputs — 2
    /// `token_events` + 1 `agent_trace_event` — plus 1
    /// `validation_results` event (the validation consumer's domain;
    /// this consumer must advance past it while rolling up nothing).
    private static func seedEvents(_ db: SessionDatabase) {
        _ = db.sessionEventStreamStore.appendEvent(
            sourceTable: "token_events", sourceId: 101,
            kind: "token_events", projectRoot: root
        )
        _ = db.sessionEventStreamStore.appendEvent(
            sourceTable: "token_events", sourceId: 102,
            kind: "token_events", projectRoot: root
        )
        _ = db.sessionEventStreamStore.appendEvent(
            sourceTable: "agent_trace_event", sourceId: 201,
            kind: "agent_trace_event", projectRoot: root
        )
        _ = db.sessionEventStreamStore.appendEvent(
            sourceTable: "validation_results", sourceId: 301,
            kind: "validation_results", projectRoot: root
        )
        db.flushWrites()
    }

    // MARK: - Test 1: exactly-once per event, offset-driven + idempotent

    @Test("standard-factory compound_learning_analytics consumer rolls up exactly once per event; restart replay and raw handler replay both double-drive nothing")
    func realWorkExactlyOnce() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        Self.seedEvents(db)
        let cid = EventStreamDispatcher.ConsumerId.compoundLearningAnalytics

        // Capture the raw batch BEFORE draining so we can later replay the
        // exact events the consumer saw (the crash-between-handler-and-
        // commit scenario, where the offset did NOT advance).
        let rawBatch = db.sessionEventStreamStore.pullSince(consumerId: cid, limit: 100)
        #expect(rawBatch.count == 4, "2 token_events + 1 agent_trace_event + 1 validation_results on the stream")

        // The STANDARD factory must wire the real handler (registration is
        // part of this leg) — not the lag-only default.
        guard let dispatcher = EventStreamDispatcher.standard(
            db: db, dualWriteEnabled: { true }
        ) else {
            Issue.record("standard() must build with a live event-stream store")
            return
        }
        let processed = dispatcher.drainToHead(consumerId: cid)
        db.flushWrites()
        #expect(processed == 4, "the consumer advances past ALL events (validation_results included)")
        #expect(dispatcher.lag(consumerId: cid) == 0)

        // REAL side effect, exactly once per acted-on event: one
        // compound_learning.analytics.<source_table> increment per
        // token_events / agent_trace_event event. The validation_results
        // event drives nothing here (the validation consumer's domain).
        var counts = Self.rollupCounts(db)
        #expect(counts["compound_learning.analytics.token_events"] == 2,
                "exactly one rollup per token_events event")
        #expect(counts["compound_learning.analytics.agent_trace_event"] == 1,
                "exactly one rollup per agent_trace_event event")
        #expect(counts["compound_learning.analytics.validation_results"] == nil,
                "validation_results events are NOT this consumer's rollup domain")

        // RESTART replay (offset WAS committed): a fresh dispatcher on the
        // same persisted offsets re-delivers nothing.
        guard let restarted = EventStreamDispatcher.standard(
            db: db, dualWriteEnabled: { true }
        ) else {
            Issue.record("standard() must build on restart")
            return
        }
        let replayed = restarted.drainToHead(consumerId: cid)
        db.flushWrites()
        #expect(replayed == 0, "restart after commitOffset replays nothing")
        counts = Self.rollupCounts(db)
        #expect(counts["compound_learning.analytics.token_events"] == 2,
                "restart does NOT double-roll-up")
        #expect(counts["compound_learning.analytics.agent_trace_event"] == 1)

        // CRASH replay (offset NOT committed): re-process the exact same
        // batch through the handler — the applied-watermark claim loses
        // on every already-claimed event id and drives nothing.
        let redriven = CompoundLearningAnalyticsStreamConsumer.process(db: db, batch: rawBatch)
        db.flushWrites()
        #expect(redriven == 0, "applied-watermark claim makes the handler idempotent under replay")
        counts = Self.rollupCounts(db)
        #expect(counts["compound_learning.analytics.token_events"] == 2,
                "raw replay does NOT double-roll-up")
        #expect(counts["compound_learning.analytics.agent_trace_event"] == 1)
    }

    // MARK: - Test 2: default-OFF means zero side effects

    @Test("default-OFF: dispatcher stays idle and the compound_learning_analytics consumer drives zero side effects")
    func defaultOffZeroSideEffects() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        Self.seedEvents(db)

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

        // Zero side effects: no rollup counters, offset untouched (all 4
        // events still ahead of the consumer), claim cursor never seeded.
        #expect(Self.rollupCounts(db).isEmpty,
                "default-OFF ⇒ zero compound_learning.analytics.* counters")
        let cid = EventStreamDispatcher.ConsumerId.compoundLearningAnalytics
        #expect(db.sessionEventStreamStore.lag(consumerId: cid) == 4,
                "default-OFF ⇒ offset untouched")
        #expect(!db.sessionEventStreamStore.allConsumerIds()
            .contains(CompoundLearningAnalyticsStreamConsumer.claimCursorId),
                "default-OFF ⇒ the applied-watermark claim cursor is never seeded")
    }
}
