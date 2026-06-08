import Foundation

/// U.9b-2 — the dual-write bus leg + parity accounting for the
/// `PaneRefreshCoordinator` migration onto `SessionWorkQueueStore`. Carved
/// into its own pure type so the bus-enqueue + parity logic is
/// deterministically testable without driving a real tile-refresh sweep.
///
/// This MIRRORS `AutoValidateDualWrite` (the u9b-1 carve-child) verbatim in
/// shape: a pure synchronous enum that enqueues onto the bus and emits a
/// parity counter. It deliberately REUSES the four shared
/// `session_work_bus.parity_*` counters defined on `AutoValidateDualWrite`
/// rather than minting per-subsystem counters — the parity diagnostics
/// (`senkani doctor`, child u9b-3) roll up one shared family of counters
/// across all migrated subsystems.
///
/// Concurrency: every method here is synchronous and runs on the caller's
/// thread (the existing `withTaskGroup` child task inside
/// `PaneRefreshCoordinator.tick`). It deliberately does NOT spawn a
/// `Task.detached` — that is the load-bearing no-flake guarantee. Unlike
/// the AutoValidate path (which lived on a detached `.utility` worker),
/// PaneRefresh already runs on structured `withTaskGroup` tasks, so this
/// leg reuses that task's thread with zero extra cooperative-pool hops.
///
/// Default-safe: this type is only invoked when `WorkBusConfig.dualWrite`
/// is `true`. With the flag at its default `false`, `PaneRefreshCoordinator`
/// never calls in here — the production path is byte-identical to U.9a
/// (zero `session_work_queue` rows for `pane_refresh`, zero parity
/// counters, existing tile-state semantics unchanged).
public enum PaneRefreshDualWrite {

    /// The `session_work_queue.kind` the pane-refresh dual-write leg uses.
    public static let kind = "pane_refresh"

    /// Compact payload the bus leg enqueues. Opaque to the queue; carries
    /// enough to reconstruct the work + correlate with the in-process tile.
    struct Payload: Codable {
        let tileId: String
    }

    /// Run the dual-write bus leg for one refreshed tile: enqueue the work
    /// onto `SessionWorkQueueStore` and emit the shared parity counter keyed
    /// to which leg(s) delivered. Returns the enqueued rowid (or -1 when the
    /// bus enqueue failed) so callers/tests can branch.
    @discardableResult
    public static func run(
        db: SessionDatabase,
        projectRoot: String,
        tileId: String,
        inProcessLegOK: Bool
    ) -> Int64 {
        let payload = encodePayload(tileId: tileId)
        let rowId = db.sessionWorkQueueStore.enqueue(
            kind: kind,
            payload: payload,
            projectRoot: projectRoot
        )
        let busLegOK = rowId > 0
        // Reuse the SHARED parity truth-table from the u9b-1 carve-child —
        // exactly one of the four `session_work_bus.parity_*` counters per
        // item, keyed to which leg(s) delivered. No new counters minted.
        AutoValidateDualWrite.emitParity(
            db: db,
            projectRoot: projectRoot,
            inProcessLegOK: inProcessLegOK,
            busLegOK: busLegOK
        )
        return rowId
    }

    /// Encode the bus payload. Falls back to a minimal JSON string if the
    /// encoder fails (the queue payload is opaque — never throws).
    static func encodePayload(tileId: String) -> String {
        let payload = Payload(tileId: tileId)
        guard let data = try? JSONEncoder().encode(payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"tile_id\":\"\(tileId)\"}"
        }
        return str
    }
}
