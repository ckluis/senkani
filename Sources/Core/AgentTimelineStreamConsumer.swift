import Foundation

/// U.9b-3b (leg 3/4) — the `agent_timeline` consumer's REAL-work handler
/// for the `EventStreamDispatcher` spine. Drains `token_events` /
/// `agent_trace_event` events from `session_event_stream` — the Agent
/// Timeline's data inputs — and maintains the timeline's bus-driven feed
/// freshness signal, now `commitOffset`-driven (the u9b parent in-scope
/// bullet).
///
/// ## What "real work" means here (right-sized per the item's own note)
///
/// The existing Agent Timeline (`AgentTimelinePane`) has no stored
/// projection: it blind-polls the canonical `token_events` query
/// (`recentTokenEvents`, every 500ms) plus a telemetry-correlation pass
/// (every 2s) on a wall-clock cadence, whether or not anything changed.
/// The consumer-side data prep that is headless-buildable is the
/// CHANGE-DETECTION feed the timeline reads:
///
///   - per claim-winning event from an acted-on source table, bump one
///     `agent_timeline.feed.<source_table>` counter for the event's
///     project root via the existing `recordEvent` / `event_counters`
///     path — a monotonic, per-project data version for the timeline's
///     inputs;
///   - `feedVersion(db:projectRoot:)` is the cheap read seam the pane's
///     poll consults: re-run the heavy row + correlation queries only
///     when the version moved.
///
/// The RENDER half — `AgentTimelinePane` actually consulting
/// `feedVersion` to gate its `refreshEvents()` / `refreshCorrelations()`
/// passes, and everything visual — is GUI-gated and stays on its
/// existing polling behavior (deferred, per the item's "right-size at
/// pick time" note). `validation_results` events are the `validation`
/// consumer's domain (leg 1) and drive nothing here — the offset still
/// advances past them.
///
/// ## Exactly-once (Kleppmann: at-least-once delivery × idempotent effect)
///
/// Two independent guards compose into exactly-once:
///   1. **Offset-driven** — the dispatcher commits the consumer offset
///      past each batch, so a restart re-delivers nothing already
///      committed.
///   2. **Applied-watermark claim** — the canonical rows here
///      (`token_events`, `agent_trace_event`) carry no claim column, so
///      the idempotency arbiter is the generic
///      `SessionEventStreamStore.claimThrough` applied-watermark claim
///      (introduced by leg 2, REUSED here) under this consumer's OWN
///      cursor row (`agent_timeline.applied` — distinct from leg 2's
///      `compound_learning_analytics.applied`; distinct consumers each
///      process the same events independently by design, so cursor ids
///      must never collide). Events arrive in ascending id order, so a
///      replay of any already-processed prefix (crash between handler
///      and commit, or an in-process race between two dispatchers)
///      loses the claim and drives NOTHING — at most one feed increment
///      per stream event, ever. No migration: the cursor row auto-seeds
///      on first claim.
///
/// The watermark advances through EVERY event (acted-on or not) so any
/// replayed prefix loses wholesale and the cursor reads sensibly next
/// to the pull offset in `senkani doctor`'s per-consumer lag listing.
///
/// ## Default-OFF preserved
///
/// This type only runs when the dispatcher's loops run, which requires
/// the operator-opt-in `WorkBusConfig.dualWrite` flag (and a started
/// dispatcher). With the flag at its default `false` the handler never
/// fires: zero claims, zero counters, byte-identical behavior.
///
/// ## Flake invariant (parent acceptance, R7/R8)
///
/// Pure-synchronous: no `Task`, no `Task.detached(.utility)`, no second
/// cooperative-pool hop. The claim runs on `SessionDatabase`'s own
/// serial queue via `queue.sync`; the handler itself runs inline on the
/// dispatcher's drain path. Tests drive `drainOnce`/`drainToHead`.
public enum AgentTimelineStreamConsumer {

    /// The `session_event_stream.source_table`s this consumer acts on —
    /// the Agent Timeline's data inputs (`token_events` powers the event
    /// rows; `agent_trace_event` powers the trace/badge correlation
    /// half). `validation_results` is the `validation` consumer's domain
    /// (leg 1), skipped here.
    public static let sourceTables: Set<String> = ["token_events", "agent_trace_event"]

    /// Feed-freshness counter prefix. The full event type per acted-on
    /// event is `agent_timeline.feed.<source_table>` — one monotonic
    /// counter per (project root, source table) in the existing
    /// `event_counters` table, which is what makes `feedVersion` a
    /// cheap change-detection read for the timeline's poll.
    public static let feedEventTypePrefix = "agent_timeline.feed."

    /// The applied-watermark claim cursor id in
    /// `session_event_stream_offsets`. Distinct from the consumer's pull
    /// offset (`agent_timeline`), which the dispatcher commits only
    /// AFTER the handler returns — this cursor advances per event INSIDE
    /// the handler, before each side effect, and is what makes
    /// crash-replay idempotent. Also distinct from every other
    /// consumer's claim cursor (leg 2 owns
    /// `compound_learning_analytics.applied`).
    public static let claimCursorId = "agent_timeline.applied"

    /// Build the drop-in handler for
    /// `EventStreamDispatcher.register(consumerId:handler:)`. Captures
    /// the database; the spine is unchanged.
    public static func makeHandler(db: SessionDatabase) -> EventStreamDispatcher.Handler {
        return { batch in
            process(db: db, batch: batch)
        }
    }

    /// Process one pulled batch. Returns the number of feed increments
    /// this call actually drove so tests can pin exactly-once directly.
    ///
    /// The watermark is advanced through EVERY event in the batch
    /// (acted-on or not) so the claim cursor tracks the consumer's
    /// progress and any replayed prefix loses wholesale; the feed
    /// counter bumps only for claim-winning events from acted-on source
    /// tables.
    @discardableResult
    public static func process(
        db: SessionDatabase,
        batch: [SessionEventStreamStore.Event]
    ) -> Int {
        guard let stream = db.sessionEventStreamStore else { return 0 }
        var driven = 0
        for event in batch {
            // Idempotent claim: wins iff the applied watermark is
            // strictly behind this event id. Replays and in-process
            // races lose the claim and drive nothing.
            guard stream.claimThrough(cursorId: claimCursorId, eventId: event.id) else { continue }
            guard sourceTables.contains(event.sourceTable) else { continue }
            db.recordEvent(
                type: feedEventTypePrefix + event.sourceTable,
                projectRoot: event.projectRoot
            )
            driven += 1
        }
        return driven
    }

    /// The timeline's bus-driven data version: the total count of feed
    /// increments for `projectRoot` (or across all projects when nil —
    /// matching `AgentTimelinePane`'s all-projects fallback). Monotonic;
    /// a poll that sees an unchanged version can skip the heavy
    /// `recentTokenEvents` + correlation queries. This is the headless
    /// read seam the GUI half consumes when its wiring lands.
    public static func feedVersion(db: SessionDatabase, projectRoot: String? = nil) -> Int {
        let rows = db.eventCounts(projectRoot: projectRoot, prefix: feedEventTypePrefix)
        return rows.reduce(0) { $0 + $1.count }
    }
}
