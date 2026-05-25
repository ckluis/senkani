import Foundation

/// Core-layer lifecycle record for a workstream. Sibling to (not a
/// replacement for) `SenkaniApp/Models/WorkstreamModel`. The app
/// model owns user-facing state (`name`, `panes`, `branch`,
/// `worktreePath`, `isActive`); this struct owns persisted runtime
/// state — `state`, `createdAt`, and the canonical `slug` used by
/// CLI / logs / audit-chain lookups. The two are joined on `id`.
///
/// Filed as child 1-of-3 from `phase-u11-pre-workstream-runtime-
/// scaffold` per the 2026-05-25 operator-confirmed decompose split.
/// This sub-item ships the foundation; the `PaneSessionDriver`
/// actor + app-layer slot wiring land in a-2, the 4 chained
/// `workstream.<event>` row writers + `ChainVerifier` extension
/// land in a-3.
public struct WorkstreamLifecycle: Codable, Equatable, Sendable {
    public let id: UUID
    public let slug: String
    public var state: WorkstreamState
    public let createdAt: Date

    public init(id: UUID, slug: String, state: WorkstreamState, createdAt: Date) {
        self.id = id
        self.slug = slug
        self.state = state
        self.createdAt = createdAt
    }
}

/// The five lifecycle states a workstream moves through. Raw values
/// are stable strings — they are persisted in the `workstreams.state`
/// SQL column (migration v37) and serialized through Codable.
public enum WorkstreamState: String, Codable, CaseIterable, Sendable {
    case staged
    case running
    case paused
    case blocked
    case archived
}

/// Structured error raised when a caller attempts an invalid
/// `WorkstreamState` transition. No crashes — callers translate
/// this into a structured chain-event row (a-3) or a UI-surface
/// error toast (a-2).
public struct WorkstreamStateTransitionError: Error, Equatable, Sendable {
    public let from: WorkstreamState
    public let to: WorkstreamState
    public let reason: String

    public init(from: WorkstreamState, to: WorkstreamState, reason: String) {
        self.from = from
        self.to = to
        self.reason = reason
    }
}

extension WorkstreamState {
    /// Validate a candidate state transition. Returns silently on
    /// success; throws `WorkstreamStateTransitionError` on a
    /// rejected transition.
    ///
    /// State machine (rejecting all other transitions):
    /// ```
    /// staged   -> running | archived
    /// running  -> paused  | blocked | archived
    /// paused   -> running | archived
    /// blocked  -> running | archived
    /// archived -> (terminal — nothing)
    /// ```
    /// Self-edges (e.g. `running -> running`) are rejected so the
    /// driver in a-2 can detect duplicate state writes.
    public func validateTransition(to next: WorkstreamState) throws {
        if self == next {
            throw WorkstreamStateTransitionError(
                from: self,
                to: next,
                reason: "self-transition not allowed")
        }
        let allowed: Set<WorkstreamState>
        switch self {
        case .staged:   allowed = [.running, .archived]
        case .running:  allowed = [.paused, .blocked, .archived]
        case .paused:   allowed = [.running, .archived]
        case .blocked:  allowed = [.running, .archived]
        case .archived: allowed = []
        }
        guard allowed.contains(next) else {
            throw WorkstreamStateTransitionError(
                from: self,
                to: next,
                reason: "transition not in state machine")
        }
    }
}

extension WorkstreamLifecycle {
    /// Apply a transition in place. Mutates `state` only on
    /// success; throws `WorkstreamStateTransitionError` on rejection
    /// and leaves the record untouched.
    public mutating func transition(to next: WorkstreamState) throws {
        try state.validateTransition(to: next)
        state = next
    }
}

/// The four `token_events.source` strings emitted by
/// `PaneSessionDriver` lifecycle transitions. Mapped one-to-one with
/// driver method names — `start()` emits `.start`, `pause()` emits
/// `.pause`, `resume()` emits `.resume`, `archive()` emits `.archive`.
///
/// U.11-pre a-3 introduces this enum + the chained-row writer
/// (`SessionDatabase.recordWorkstreamEvent`) that consumes it. Rows
/// chain under the `migration-v38` (or post-v38 `fresh-install`)
/// `token_events` anchor.
public enum WorkstreamChainEvent: String, Sendable {
    case start    = "workstream.start"
    case pause    = "workstream.pause"
    case resume   = "workstream.resume"
    case archive  = "workstream.archive"
}
