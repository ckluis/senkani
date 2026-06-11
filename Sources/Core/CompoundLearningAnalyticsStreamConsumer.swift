import Foundation

/// U.9b-3b (leg 2/4) — the `compound_learning_analytics` consumer's
/// REAL-work handler for the `EventStreamDispatcher` spine. Drains
/// `token_events` / `agent_trace_event` events from
/// `session_event_stream` — CompoundLearning's analytics inputs — and
/// drives the Analytics rollups through the same `recordEvent` /
/// `event_counters` path every `CompoundLearning.swift` counter already
/// uses, now `commitOffset`-driven (the u9b parent in-scope bullet).
///
/// ## What "real work" means here
///
/// CompoundLearning's Analyze surfaces consume `event_counters` rollups
/// via `eventCounts(prefix: "compound_learning.")`. The bus-side leg:
/// for each drained event from an acted-on source table, atomically
/// CLAIM the event (applied-watermark, see below) and bump one
/// `compound_learning.analytics.<source_table>` rollup counter for the
/// event's project root. `validation_results` events are the
/// `validation` consumer's domain (leg 1) and drive nothing here — the
/// offset still advances past them.
///
/// The OTHER half of this consumer's parent bullet — model-backed
/// enrichment (`GemmaRationaleRewriter` rewriting staged-rule
/// rationales) — is NOT wired to the bus: it requires a live MLX model
/// and runs per staged rule, not per stream event. It stays on its
/// existing operator paths (`senkani learn enrich`,
/// `CompoundLearning.runDailySweep(enricher:)`).
///
/// ## Exactly-once (Kleppmann: at-least-once delivery × idempotent effect)
///
/// Two independent guards compose into exactly-once:
///   1. **Offset-driven** — the dispatcher commits the consumer offset
///      past each batch, so a restart re-delivers nothing already
///      committed.
///   2. **Applied-watermark claim** — the canonical rows here
///      (`token_events`, `agent_trace_event`) carry no claim column, so
///      the idempotency arbiter is a second cursor row in the EXISTING
///      `session_event_stream_offsets` table (`claimCursorId`), advanced
///      through each event id BEFORE the rollup fires via the guarded
///      `SessionEventStreamStore.claimThrough` UPDATE
///      (`WHERE ... last_processed_event_id < ?`). Events arrive in
///      ascending id order, so a replay of any already-processed prefix
///      (crash between handler and commit, or an in-process race between
///      two dispatchers) loses the claim and drives NOTHING — at most
///      one rollup increment per stream event, ever. No migration: the
///      cursor row auto-seeds on first claim.
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
public enum CompoundLearningAnalyticsStreamConsumer {

    /// The `session_event_stream.source_table`s this consumer rolls up —
    /// CompoundLearning's analytics inputs. `validation_results` is the
    /// `validation` consumer's domain (leg 1), skipped here.
    public static let sourceTables: Set<String> = ["token_events", "agent_trace_event"]

    /// Rollup counter prefix. The full event type per acted-on event is
    /// `compound_learning.analytics.<source_table>` — under the same
    /// `compound_learning.` namespace every existing
    /// `CompoundLearning.swift` recordEvent path uses, so
    /// `eventCounts(prefix: "compound_learning.")` consumers aggregate
    /// it without change.
    public static let rollupEventTypePrefix = "compound_learning.analytics."

    /// The applied-watermark claim cursor id in
    /// `session_event_stream_offsets`. Distinct from the consumer's pull
    /// offset (`compound_learning_analytics`), which the dispatcher
    /// commits only AFTER the handler returns — this cursor advances
    /// per event INSIDE the handler, before each side effect, and is
    /// what makes crash-replay idempotent.
    public static let claimCursorId = "compound_learning_analytics.applied"

    /// Build the drop-in handler for
    /// `EventStreamDispatcher.register(consumerId:handler:)`. Captures
    /// the database; the spine is unchanged.
    public static func makeHandler(db: SessionDatabase) -> EventStreamDispatcher.Handler {
        return { batch in
            process(db: db, batch: batch)
        }
    }

    /// Process one pulled batch. Returns the number of rollup increments
    /// this call actually drove so tests can pin exactly-once directly.
    ///
    /// The watermark is advanced through EVERY event in the batch
    /// (acted-on or not) so the claim cursor tracks the consumer's
    /// progress and any replayed prefix loses wholesale; the rollup
    /// fires only for claim-winning events from acted-on source tables.
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
                type: rollupEventTypePrefix + event.sourceTable,
                projectRoot: event.projectRoot
            )
            driven += 1
        }
        return driven
    }
}
