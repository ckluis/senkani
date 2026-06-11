import Testing
import Foundation
@testable import Core

/// U.9b-3b (leg 3/4) — the `agent_timeline` consumer's real-work wiring:
/// `AgentTimelineStreamConsumer` drains `token_events` /
/// `agent_trace_event` events from `session_event_stream` and maintains
/// the Agent Timeline's bus-driven feed-freshness signal
/// (`agent_timeline.feed.*` counters + the `feedVersion` change-detection
/// seam) via the existing `recordEvent` / `event_counters` path,
/// commitOffset-driven, with an applied-watermark idempotent claim under
/// the consumer's OWN cursor (`agent_timeline.applied`).
///
/// FLAKE-DISCIPLINE (parent acceptance, R7/R8): no `Task.detached(.utility)`,
/// no second cooperative-pool hop, no wall-clock loop-timing assertion —
/// these tests drive the spine's SYNCHRONOUS `drainOnce`/`drainToHead`
/// seams and the handler's `process` function directly.
@Suite("U.9b-3b leg 3 — agent_timeline consumer real work", .serialized)
struct AgentTimelineStreamConsumerTests {

    private static let root = "/tmp/u9b3b-leg3"

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u9b3b-leg3-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    /// Per-type sums of `agent_timeline.feed.*` counters across roots.
    private static func feedCounts(_ db: SessionDatabase) -> [String: Int] {
        var out: [String: Int] = [:]
        let prefix = AgentTimelineStreamConsumer.feedEventTypePrefix
        for row in db.eventCounts(prefix: prefix) {
            out[row.eventType, default: 0] += row.count
        }
        return out
    }

    /// Seed the stream with the timeline's data inputs — 2 `token_events`
    /// + 1 `agent_trace_event` — plus 1 `validation_results` event (the
    /// validation consumer's domain; this consumer must advance past it
    /// while bumping no feed counter for it).
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

    @Test("standard-factory agent_timeline consumer bumps the feed exactly once per event; restart replay and raw handler replay both double-drive nothing; cursor independent of the compound_learning_analytics consumer")
    func realWorkExactlyOnce() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        Self.seedEvents(db)
        let cid = EventStreamDispatcher.ConsumerId.agentTimeline

        // Distinct consumers process the same events independently by
        // design — the claim cursors must never collide.
        #expect(AgentTimelineStreamConsumer.claimCursorId
                != CompoundLearningAnalyticsStreamConsumer.claimCursorId,
                "agent_timeline's applied cursor must not collide with leg 2's")

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
        // agent_timeline.feed.<source_table> increment per token_events /
        // agent_trace_event event. The validation_results event drives
        // nothing here (the validation consumer's domain).
        var counts = Self.feedCounts(db)
        #expect(counts["agent_timeline.feed.token_events"] == 2,
                "exactly one feed bump per token_events event")
        #expect(counts["agent_timeline.feed.agent_trace_event"] == 1,
                "exactly one feed bump per agent_trace_event event")
        #expect(counts["agent_timeline.feed.validation_results"] == nil,
                "validation_results events are NOT the timeline's feed domain")

        // The change-detection seam the GUI half will consult: monotonic
        // data version, per-project and all-projects.
        #expect(AgentTimelineStreamConsumer.feedVersion(db: db) == 3,
                "feedVersion sums the feed counters (the timeline's data version)")
        #expect(AgentTimelineStreamConsumer.feedVersion(db: db, projectRoot: Self.root) == 3,
                "per-project feedVersion matches for the seeded root")
        #expect(AgentTimelineStreamConsumer.feedVersion(db: db, projectRoot: "/tmp/other-root") == 0,
                "an unrelated project's feedVersion stays 0")

        // INDEPENDENCE: the compound_learning_analytics consumer processes
        // the SAME events under ITS own cursor — agent_timeline's claims
        // must not have consumed them (the bus model: each consumer drains
        // independently).
        let clCid = EventStreamDispatcher.ConsumerId.compoundLearningAnalytics
        let clProcessed = dispatcher.drainToHead(consumerId: clCid)
        db.flushWrites()
        #expect(clProcessed == 4, "the sibling consumer still sees all 4 events under its own cursor")
        let clCounts = db.eventCounts(prefix: "compound_learning.analytics.")
            .reduce(into: [String: Int]()) { $0[$1.eventType, default: 0] += $1.count }
        #expect(clCounts["compound_learning.analytics.token_events"] == 2,
                "agent_timeline's claims do not starve the sibling consumer's rollups")
        #expect(clCounts["compound_learning.analytics.agent_trace_event"] == 1)

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
        counts = Self.feedCounts(db)
        #expect(counts["agent_timeline.feed.token_events"] == 2,
                "restart does NOT double-bump the feed")
        #expect(counts["agent_timeline.feed.agent_trace_event"] == 1)

        // CRASH replay (offset NOT committed): re-process the exact same
        // batch through the handler — the applied-watermark claim loses
        // on every already-claimed event id and drives nothing.
        let redriven = AgentTimelineStreamConsumer.process(db: db, batch: rawBatch)
        db.flushWrites()
        #expect(redriven == 0, "applied-watermark claim makes the handler idempotent under replay")
        counts = Self.feedCounts(db)
        #expect(counts["agent_timeline.feed.token_events"] == 2,
                "raw replay does NOT double-bump the feed")
        #expect(counts["agent_timeline.feed.agent_trace_event"] == 1)
        #expect(AgentTimelineStreamConsumer.feedVersion(db: db) == 3,
                "the data version is stable across both replay shapes")
    }

    // MARK: - Test 2: default-OFF means zero side effects

    @Test("default-OFF: dispatcher stays idle and the agent_timeline consumer drives zero side effects")
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

        // Zero side effects: no feed counters, data version 0, offset
        // untouched (all 4 events still ahead of the consumer), claim
        // cursor never seeded.
        #expect(Self.feedCounts(db).isEmpty,
                "default-OFF ⇒ zero agent_timeline.feed.* counters")
        #expect(AgentTimelineStreamConsumer.feedVersion(db: db) == 0,
                "default-OFF ⇒ the timeline's data version never moves")
        let cid = EventStreamDispatcher.ConsumerId.agentTimeline
        #expect(db.sessionEventStreamStore.lag(consumerId: cid) == 4,
                "default-OFF ⇒ offset untouched")
        #expect(!db.sessionEventStreamStore.allConsumerIds()
            .contains(AgentTimelineStreamConsumer.claimCursorId),
                "default-OFF ⇒ the applied-watermark claim cursor is never seeded")
    }
}
