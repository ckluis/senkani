import Foundation

/// Phase V.17c — the thread-handoff guardrail predicate. When the
/// operator imports a provider thread from one adapter into another, the
/// guard reads the thread's LAST `ProviderRuntimeEvent` off the spine
/// (`provider_runtime_event`) and decides whether the thread is in a
/// stable, importable state.
///
/// **Importable ONLY when the thread's last event is `.turnCompleted`.**
/// A `turnCompleted` thread is at rest — there is no half-open approval,
/// input prompt, or tool call to be torn off mid-flight by a handoff.
/// Any other terminal state is a pending / aborted block with a
/// descriptive, testable reason string:
///
///   - `.approvalRequested` / `.approvalGranted` (without a following
///     completion) → `"pending approval"`
///   - `.userInputRequested` → `"pending user input"`
///   - `.toolCallStarted` (no matching finish / completion after) →
///     `"pending tool call"`
///   - `.turnAborted` → `"turn aborted"`
///   - no events for the thread → `"no completed turn"`
///   - any other non-terminal moment (`.messageStarted`,
///     `.messageDelta`, `.warning`, a bare `.toolCallFinished` not
///     followed by a turn boundary) → `"turn in progress"`
///
/// The guard is a pure predicate over the store read — it does NOT write
/// anything. The accept path (`SessionDatabase.recordThreadHandoff`) is
/// what persists the chained audit row, and it consults this predicate
/// plus the operator override to decide whether a row may land.
public struct ThreadHandoffGuard: Sendable {
    private let store: ProviderRuntimeEventStore

    public init(store: ProviderRuntimeEventStore) {
        self.store = store
    }

    /// The decision a guard returns. `importable == true` iff the
    /// thread's last event is `.turnCompleted`; otherwise
    /// `blockedReason` carries the operator-readable cause.
    public struct Decision: Sendable, Equatable {
        public let importable: Bool
        public let blockedReason: String?

        public init(importable: Bool, blockedReason: String?) {
            self.importable = importable
            self.blockedReason = blockedReason
        }
    }

    /// Decide whether `threadID` may be imported. `providerID`, when
    /// supplied, scopes the last-event read to that source adapter so a
    /// multi-provider thread is judged by the relinquishing adapter's
    /// last word, not a later event from a different adapter.
    public func canImport(threadID: String, providerID: String? = nil) -> Decision {
        guard let last = store.lastEventType(threadID: threadID, providerID: providerID) else {
            return Decision(importable: false, blockedReason: "no completed turn")
        }
        return Self.decide(forLastEvent: last)
    }

    /// Pure mapping from a thread's last event type to a decision.
    /// Extracted so the block-reason vocabulary is unit-testable
    /// without a store round-trip.
    public static func decide(forLastEvent last: ProviderRuntimeEvent.EventType) -> Decision {
        switch last {
        case .turnCompleted:
            return Decision(importable: true, blockedReason: nil)
        case .approvalRequested, .approvalGranted:
            return Decision(importable: false, blockedReason: "pending approval")
        case .userInputRequested:
            return Decision(importable: false, blockedReason: "pending user input")
        case .toolCallStarted:
            return Decision(importable: false, blockedReason: "pending tool call")
        case .turnAborted:
            return Decision(importable: false, blockedReason: "turn aborted")
        case .messageStarted, .messageDelta, .toolCallFinished, .warning:
            return Decision(importable: false, blockedReason: "turn in progress")
        }
    }
}

/// Phase V.17c — value type capturing one accepted thread handoff. This
/// is the structured artifact persisted as a `thread_handoff_event`
/// chained audit row (migration v43). `overrideReason` is non-nil ONLY
/// when the operator force-imported past a BLOCKED predicate; a normal
/// (predicate-importable) handoff carries `overrideReason == nil`, which
/// the writer stores as a NULL `override_reason` column.
public struct ThreadHandoff: Sendable, Equatable {
    public let fromProvider: String
    public let toProvider: String
    public let threadID: String
    public let acceptedBy: String
    public let preHandoffEventCount: Int
    public let postHandoffEventCount: Int
    /// nil → normal accepted handoff (predicate was importable).
    /// non-nil → operator force-import past a block; the free-text
    /// justification. An EMPTY / whitespace-only string is NOT a valid
    /// justification — the writer rejects it.
    public let overrideReason: String?

    public init(
        fromProvider: String,
        toProvider: String,
        threadID: String,
        acceptedBy: String,
        preHandoffEventCount: Int,
        postHandoffEventCount: Int,
        overrideReason: String? = nil
    ) {
        self.fromProvider = fromProvider
        self.toProvider = toProvider
        self.threadID = threadID
        self.acceptedBy = acceptedBy
        self.preHandoffEventCount = preHandoffEventCount
        self.postHandoffEventCount = postHandoffEventCount
        self.overrideReason = overrideReason
    }
}

/// Phase V.17c — outcome of a `recordThreadHandoff` accept. Explicit
/// enum so the accept path can branch on dedup / reject without
/// re-reading `sqlite3_changes`. Public so the `SessionDatabase`
/// forwarder + tests can name it without reaching into the internal
/// `TokenEventStore`.
public enum ThreadHandoffOutcome: Sendable, Equatable {
    /// A new chained `thread_handoff_event` row was written.
    case recorded
    /// The thread was already imported into the same target provider —
    /// the dedup index refused the second row.
    case idempotencyHit
    /// An operator override was attempted without a non-empty
    /// justification. No row was written (never silently writes).
    case rejectedMissingOverrideReason
}
