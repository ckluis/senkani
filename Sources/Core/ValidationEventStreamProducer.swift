import Foundation

/// U.9c-1 — the production producer surface for `session_event_stream`'s
/// `validation_results` source.
///
/// **Load-bearing context.** Before this phase the `session_event_stream`
/// mirror table had ZERO production writers even with
/// `WorkBusConfig.dualWrite == true`: the U.9b dual-write path
/// (`AutoValidateDualWrite`, `PaneRefreshDualWrite`) enqueues straight into
/// `session_work_queue` and BYPASSES the outbox, so the four
/// `*StreamConsumer` pull loops read an always-empty stream. U.9c-1 wires
/// the first REAL producer: `ValidationStore.insertValidationResultWithOutbox`
/// routes the canonical `validation_results` insert plus a paired stream row
/// through `SessionDatabase.withOutboxTransaction`, atomically, gated by the
/// same default-OFF `dualWrite` flag.
///
/// The atomic write itself lives in `ValidationStore` (it needs that store's
/// chain internals). This type owns the shared vocabulary — the source-table
/// name and the observability counters — plus the parity audit that lets an
/// operator (Majors) confirm every canonical row gained its paired stream
/// row.
public enum ValidationEventStreamProducer {

    /// The `session_event_stream.source_table` this producer writes and the
    /// `validation` consumer reads. Identical to
    /// `ValidationStreamConsumer.sourceTable` by contract.
    public static let sourceTable = "validation_results"

    /// Incremented once per canonical row that landed WITH its paired
    /// stream row (dual-write ON). Never emitted when dual-write is OFF —
    /// the outbox path is not entered at all.
    public static let producedCounter = "session_event_stream.validation_produced"

    /// Parity audit counters (Majors observability). Emitted by
    /// `recordParityAudit`.
    public static let parityMatchCounter   = "session_event_stream.validation_parity_match"
    public static let parityDivergeCounter = "session_event_stream.validation_parity_diverge"

    /// Snapshot of canonical-vs-stream row counts for the
    /// `validation_results` source.
    public struct ParityAudit: Sendable, Equatable {
        public let canonicalRows: Int
        public let streamRows: Int

        public init(canonicalRows: Int, streamRows: Int) {
            self.canonicalRows = canonicalRows
            self.streamRows = streamRows
        }

        /// Canonical rows that never gained a paired stream row register as
        /// a positive delta; the atomic producer keeps this at 0.
        public var delta: Int { canonicalRows - streamRows }
        public var diverged: Bool { delta != 0 }
    }

    /// Compare the canonical `validation_results` row count against the
    /// paired `session_event_stream` rows and emit the match/diverge
    /// counter. A DB that dual-wrote from birth reports `diverged == false`;
    /// a canonical row written WITHOUT the outbox (the legacy
    /// fire-and-forget path, or a deliberately injected divergence) makes
    /// the audit report the gap. Returns the audit so callers/tests branch.
    @discardableResult
    public static func recordParityAudit(
        db: SessionDatabase,
        projectRoot: String? = nil
    ) -> ParityAudit {
        let audit = ParityAudit(
            canonicalRows: db.validationResultsRowCount(),
            streamRows: db.sessionEventStreamStore.count(sourceTable: sourceTable)
        )
        db.recordEvent(
            type: audit.diverged ? parityDivergeCounter : parityMatchCounter,
            projectRoot: projectRoot
        )
        return audit
    }
}
