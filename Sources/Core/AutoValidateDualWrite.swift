import Foundation

/// U.9b-1 — the dual-write bus leg + parity accounting for the
/// `AutoValidateQueue` migration onto `SessionWorkQueueStore`. Carved into
/// its own pure type so the parity logic is deterministically testable
/// without spawning a real validator subprocess.
///
/// Concurrency: every method here is synchronous and runs on the caller's
/// thread (the existing off-actor `Task.detached(.utility)` worker in
/// `AutoValidateQueue.startValidation`). It deliberately does NOT spawn a
/// second `Task.detached(.utility)` — that is the load-bearing no-flake
/// guarantee (the R7/R8 cooperative-pool-starvation pattern is not
/// reintroduced; the bus enqueue + counters reuse the worker's thread).
///
/// Default-safe: this type is only invoked when `WorkBusConfig.dualWrite`
/// is `true`. With the flag at its default `false`, `AutoValidateQueue`
/// never calls in here — the production path is byte-identical to U.9a
/// (zero `session_work_queue` rows for `auto_validate`, zero parity
/// counters).
public enum AutoValidateDualWrite {

    /// The `session_work_queue.kind` the auto-validate dual-write leg uses.
    public static let kind = "auto_validate"

    /// The four parity event-counter names (under `event_counters` via
    /// `SessionDatabase.recordEvent`). Emitted ONLY when dual-write is on.
    public static let parityMatch          = "session_work_bus.parity_match"
    public static let parityDiverge        = "session_work_bus.parity_diverge"
    public static let parityBusOnly        = "session_work_bus.parity_bus_only"
    public static let parityInProcessOnly  = "session_work_bus.parity_inprocess_only"

    /// Compact payload the bus leg enqueues. Opaque to the queue; carries
    /// enough to reconstruct the work + correlate with the in-process row.
    struct Payload: Codable {
        let sessionId: String
        let path: String
        let attemptCount: Int
    }

    /// Run the dual-write bus leg for one completed validation: enqueue
    /// the work onto `SessionWorkQueueStore` and emit the parity counter
    /// keyed to which leg(s) delivered. Returns the enqueued rowid (or -1
    /// when the bus enqueue failed) so callers/tests can branch.
    @discardableResult
    public static func run(
        db: SessionDatabase,
        sessionId: String,
        path: String,
        projectRoot: String,
        attempts: [AutoValidateWorker.ValidationAttempt],
        inProcessLegOK: Bool
    ) -> Int64 {
        let payload = encodePayload(sessionId: sessionId, path: path, attemptCount: attempts.count)
        let rowId = db.sessionWorkQueueStore.enqueue(
            kind: kind,
            payload: payload,
            projectRoot: projectRoot
        )
        let busLegOK = rowId > 0
        emitParity(db: db, projectRoot: projectRoot, inProcessLegOK: inProcessLegOK, busLegOK: busLegOK)
        return rowId
    }

    /// Pure parity-counter selection. Emits EXACTLY ONE counter per item,
    /// keyed to which leg(s) won:
    ///   - both legs OK            ⇒ `.parity_match`
    ///   - only the bus leg OK     ⇒ `.parity_bus_only`
    ///   - only the in-process OK  ⇒ `.parity_inprocess_only`
    ///   - neither leg OK          ⇒ `.parity_diverge`
    /// Exposed for direct unit testing of the truth table without
    /// spawning a validator.
    public static func emitParity(
        db: SessionDatabase,
        projectRoot: String,
        inProcessLegOK: Bool,
        busLegOK: Bool
    ) {
        let counter: String
        switch (inProcessLegOK, busLegOK) {
        case (true, true):   counter = parityMatch
        case (false, true):  counter = parityBusOnly
        case (true, false):  counter = parityInProcessOnly
        case (false, false): counter = parityDiverge
        }
        db.recordEvent(type: counter, projectRoot: projectRoot)
    }

    /// Encode the bus payload. Falls back to a minimal JSON string if the
    /// encoder fails (the queue payload is opaque — never throws).
    static func encodePayload(sessionId: String, path: String, attemptCount: Int) -> String {
        let payload = Payload(sessionId: sessionId, path: path, attemptCount: attemptCount)
        guard let data = try? JSONEncoder().encode(payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"session_id\":\"\(sessionId)\"}"
        }
        return str
    }
}
