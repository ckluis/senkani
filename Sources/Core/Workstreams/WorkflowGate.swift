import Foundation

/// U.11a-3 — third contract surface that layers a refusal mechanism on
/// top of a-1's `WorkstreamTaskContract` and a-2's `ValidationAssertion`.
/// A `WorkflowGate` represents a configured refusal hook the operator
/// (or an upstream component) has attached to a contract: it pins the
/// transition point (`kind`), the severity of refusal (`policy`), and
/// what to do on a re-attempt (`retry`).
///
/// Operator decisions locked in (decompose interview 2026-05-25):
///   - Q3 — gate refusal semantics = throw + persist. a-3 wires the
///     throw (via `GateRefusal`) and the per-evaluation audit row
///     (`gate.evaluate` chained row). The dedicated
///     `workstream_handoffs` SQLite table + `handoff.open`/`.close`
///     row kinds land in a-4.
///
/// Persistence note: a-3 ships no new table. The struct + chain row
/// kind (`gate.evaluate`) live alongside the existing v39 anchor (see
/// `ChainVerifier.verifyAnchorTokenEvents` — `migration-v39` already
/// joins both shape sets for `source` discrimination only).
public struct WorkflowGate: Codable, Equatable, Sendable {
    public let id: UUID
    public let contractID: UUID
    public let kind: GateKind
    public let policy: BlockingPolicy
    public let retry: RetryBehavior

    public init(
        id: UUID,
        contractID: UUID,
        kind: GateKind,
        policy: BlockingPolicy,
        retry: RetryBehavior
    ) {
        self.id = id
        self.contractID = contractID
        self.kind = kind
        self.policy = policy
        self.retry = retry
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case contractID = "contract_id"
        case kind
        case policy
        case retry
    }

    /// Evaluate the gate. In a-3 the evaluation is policy-only: the
    /// mere presence of the gate on the attached contract means it
    /// fires when the driver consults it for the matching transition.
    /// Returns the outcome that the driver then either honors (block →
    /// throw `GateRefusal`) or records-and-proceeds (warn / advisory).
    ///
    /// `currentState` is the persisted lifecycle state the driver
    /// observes at the consult point (`nil` for an initial insert).
    /// It is intentionally available for the predicate logic a later
    /// child layers in — today the mapping is policy → outcome.
    ///
    /// `workstreamID` is needed because a `block` outcome carries a
    /// `BlockedHandoff` value whose `workstreamID` field references
    /// the owning workstream (gates themselves only reference the
    /// contract, not the workstream — the contract carries the
    /// workstream FK).
    public func evaluate(
        currentState: WorkstreamState?,
        workstreamID: UUID
    ) -> GateOutcome {
        switch policy {
        case .block:
            // BlockedHandoff carries a structured reason — never a raw
            // stdout/stderr paste. The acceptance bullet "reads zero
            // raw-stdout substrings" is satisfied because the reason
            // is constructed from typed identifiers (kind + policy),
            // never from command output.
            let handoff = BlockedHandoff(
                id: UUID(),
                workstreamID: workstreamID,
                gateID: id,
                blockerReason: "gate.\(kind.rawValue) refused under block policy",
                owner: .operator,
                nextAction: "operator review required to clear gate.\(kind.rawValue) before re-attempt",
                evidenceBundle: []
            )
            return .blocked(handoff: handoff)
        case .warn:
            return .warned
        case .advisory:
            return .advisory
        }
    }
}

/// The 6 transition points a workflow gate can guard. Raw values are
/// stable strings — persisted in `token_events.command` on `gate.evaluate`
/// rows is the gate `kind` carried indirectly via the `BlockedHandoff`
/// reason; raw strings here pin the wire form for any future
/// `workflow_gates` table (a-4 or later).
public enum GateKind: String, Codable, CaseIterable, Sendable {
    case preRun    = "pre_run"
    case postRun   = "post_run"
    case preMerge  = "pre_merge"
    case validation
    case review
    case archive
}

/// The 3 refusal severities a gate may carry. `block` causes the
/// driver to throw `GateRefusal` and leave state untouched; `warn`
/// records a warned outcome and proceeds; `advisory` records an
/// advisory outcome and proceeds.
public enum BlockingPolicy: String, Codable, CaseIterable, Sendable {
    case block
    case warn
    case advisory
}

/// How a refused gate is intended to be re-attempted. `none` means
/// the gate is one-shot (no retry expected); `manual` requires the
/// operator to drive the re-attempt; `autoWithBackoff` means an
/// upstream scheduler will retry with backoff. a-3 carries this as
/// a value field only — a later child wires the retry behavior into
/// the driver's resume path.
public enum RetryBehavior: String, Codable, CaseIterable, Sendable {
    case none
    case manual
    case autoWithBackoff = "auto_with_backoff"
}

/// The 4 outcomes a gate evaluation can produce. `.allow` is the
/// canonical no-op (no audit row written by the driver — there's
/// nothing to record); the other three each get a `gate.evaluate`
/// chained row. `.blocked` additionally surfaces a `BlockedHandoff`
/// value the driver wraps in `GateRefusal` and throws.
public enum GateOutcome: Equatable, Sendable {
    case allow
    case blocked(handoff: BlockedHandoff)
    case warned
    case advisory

    /// Stable identifier used by the `gate.evaluate` row writer to
    /// populate the `token_events.command` column. Mirrors the
    /// `AssertionState.rawValue` shape used by a-2's writer.
    public var rawIdentifier: String {
        switch self {
        case .allow:    return "allow"
        case .blocked:  return "blocked"
        case .warned:   return "warned"
        case .advisory: return "advisory"
        }
    }
}

/// The error `PaneSessionDriver` throws when a `block`-policy gate
/// refuses a transition. State stays untouched — the driver consulted
/// the gate before any SQL update, recorded the `gate.evaluate` row,
/// then threw without applying the transition. Callers unwrap the
/// `handoff` to surface the structured reason / owner / next action
/// to the operator.
public struct GateRefusal: Error, Equatable, Sendable {
    public let handoff: BlockedHandoff

    public init(handoff: BlockedHandoff) {
        self.handoff = handoff
    }
}

/// The single `token_events.source` string emitted by the
/// `recordGateEvent` writer. Sibling to `AssertionChainEvent` /
/// `ContractChainEvent` / `WorkstreamChainEvent` — same chaining
/// mechanics under the `migration-v39` anchor.
public enum GateChainEvent: String, Sendable {
    case evaluate = "gate.evaluate"
}
