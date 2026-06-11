import Foundation

/// U.9b-3b (leg 1/4) — the `validation` consumer's REAL-work handler for
/// the `EventStreamDispatcher` spine. Drains `validation_results` events
/// from `session_event_stream` and drives the existing
/// `auto_validate.delivered` path, now `commitOffset`-driven (the u9b
/// parent in-scope bullet).
///
/// ## What "real work" means here
///
/// The in-process delivered path (`HookRouter.appendAndMarkValidationIfSurfaced`)
/// marks advisory rows surfaced + records `auto_validate.delivered` when an
/// advisory's text is appended to a deny response. The bus-side equivalent:
/// for each drained `validation_results` event, atomically CLAIM the
/// canonical advisory row (`delivered = 1, surfaced_at = now` — but ONLY if
/// it is still pending) and record `auto_validate.delivered` for the claim.
///
/// ## Exactly-once (Kleppmann: at-least-once delivery × idempotent effect)
///
/// Two independent guards compose into exactly-once:
///   1. **Offset-driven** — the dispatcher commits the consumer offset past
///      each batch, so a restart re-delivers nothing already committed.
///   2. **Idempotent claim** — `claimValidationDelivery` is a guarded
///      UPDATE (`WHERE ... delivered = 0 AND surfaced_at IS NULL`) that
///      returns whether THIS call flipped the row. A replay of the same
///      event (crash between handler and commit) or a race with the
///      in-process HookRouter leg loses the claim and drives NOTHING — at
///      most one `auto_validate.delivered` per canonical row, ever,
///      regardless of which leg wins.
///
/// Non-advisory events (clean/dropped rows, other source tables) claim
/// nothing and drive nothing — the offset still advances past them.
///
/// ## Default-OFF preserved
///
/// This type only runs when the dispatcher's loops run, which requires the
/// operator-opt-in `WorkBusConfig.dualWrite` flag (and a started
/// dispatcher — there is no production `start()` call sites change in this
/// leg). With the flag at its default `false` the handler never fires:
/// zero claims, zero counters, byte-identical behavior.
///
/// ## Flake invariant (parent acceptance, R7/R8)
///
/// Pure-synchronous: no `Task`, no `Task.detached(.utility)`, no second
/// cooperative-pool hop. The claim runs on `SessionDatabase`'s own serial
/// queue via `queue.sync`; the handler itself runs inline on the
/// dispatcher's drain path. Tests drive `drainOnce`/`drainToHead`.
public enum ValidationStreamConsumer {

    /// The `session_event_stream.source_table` this consumer acts on.
    public static let sourceTable = "validation_results"

    /// The existing delivered-path event counter, now commitOffset-driven.
    public static let deliveredEventType = "auto_validate.delivered"

    /// Build the drop-in handler for
    /// `EventStreamDispatcher.register(consumerId:handler:)`. Captures the
    /// database; the spine is unchanged.
    public static func makeHandler(db: SessionDatabase) -> EventStreamDispatcher.Handler {
        return { batch in
            process(db: db, batch: batch)
        }
    }

    /// Process one pulled batch. Returns the number of rows this call
    /// actually claimed (i.e. `auto_validate.delivered` events driven) so
    /// tests can pin exactly-once directly.
    @discardableResult
    public static func process(
        db: SessionDatabase,
        batch: [SessionEventStreamStore.Event]
    ) -> Int {
        var driven = 0
        for event in batch where event.sourceTable == sourceTable {
            // Idempotent claim: flips the canonical row to delivered ONLY
            // if it is a still-pending advisory. Replays and cross-leg
            // races lose the claim and drive nothing.
            guard db.claimValidationDelivery(resultId: event.sourceId) else { continue }
            db.recordEvent(type: deliveredEventType, projectRoot: event.projectRoot)
            driven += 1
        }
        return driven
    }
}
