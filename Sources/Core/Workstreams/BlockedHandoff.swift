import Foundation

/// U.11a-3 — value-type-only first cut of the blocked-handoff record.
/// A `BlockedHandoff` is the structured artifact a `block`-policy
/// `WorkflowGate` produces when it refuses a transition: it names the
/// gate that refused, the workstream that was blocked, who owns the
/// follow-up, what action will clear the block, and pointers to
/// evidence rows already on disk.
///
/// **No `render()` method here.** The README-friendly markdown render
/// belongs to a later child (a-4) alongside the dedicated
/// `workstream_handoffs` SQLite table + `handoff.open` / `handoff.close`
/// chain rows. Today the driver throws `GateRefusal(handoff:)`; callers
/// destructure the handoff to surface fields directly.
///
/// Operator decision Q3 (decompose 2026-05-25) — gate refusal semantics
/// = throw + persist. a-3 wires the throw. The per-evaluation audit row
/// (`gate.evaluate`) is what "persist" means in a-3; the durable
/// per-handoff record lands in a-4.
///
/// Acceptance bullet "BlockedHandoff value carries structured reason
/// and reads zero raw-stdout substrings": the `blockerReason` is built
/// from typed identifiers (gate kind + policy enum); it is never a
/// paste of command stdout/stderr. The `evidenceBundle` field carries
/// path strings / `token_events` rowid references — also structured.
public struct BlockedHandoff: Codable, Equatable, Sendable {
    public let id: UUID
    public let workstreamID: UUID
    public let gateID: UUID
    public let blockerReason: String
    public let owner: HandoffOwner
    public let nextAction: String
    /// 0..n structured pointers: file paths and/or `token_events` row
    /// id references (`"token_events#<rowid>"` shape). Free-text
    /// strings, but each entry is intended to be machine-parseable;
    /// callers building UI surfaces split on `#`.
    public let evidenceBundle: [String]

    public init(
        id: UUID,
        workstreamID: UUID,
        gateID: UUID,
        blockerReason: String,
        owner: HandoffOwner,
        nextAction: String,
        evidenceBundle: [String]
    ) {
        self.id = id
        self.workstreamID = workstreamID
        self.gateID = gateID
        self.blockerReason = blockerReason
        self.owner = owner
        self.nextAction = nextAction
        self.evidenceBundle = evidenceBundle
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workstreamID   = "workstream_id"
        case gateID         = "gate_id"
        case blockerReason  = "blocker_reason"
        case owner
        case nextAction     = "next_action"
        case evidenceBundle = "evidence_bundle"
    }
}

/// Who owns the follow-up that clears a `BlockedHandoff`. Raw values
/// are stable strings — they appear in the
/// `workstream_handoffs.owner` column (U.11a-4 / migration v40) and
/// serialize through Codable.
///
/// `operator` is a Swift keyword in operator-declaration context; the
/// case uses backticks to bypass the keyword and keep the wire form
/// `"operator"`.
public enum HandoffOwner: String, Codable, CaseIterable, Sendable {
    case `operator`
    case autonomousLoop  = "autonomous_loop"
    case externalService = "external_service"
}

/// U.11a-4 — `token_events.source` strings emitted by the handoff
/// row-kind writer. Sibling to `GateChainEvent` / `AssertionChainEvent`
/// / `ContractChainEvent` / `WorkstreamChainEvent` — same chaining
/// mechanics under the `migration-v40` anchor.
///
/// `handoff.open` is emitted alongside the `workstream_handoffs` row
/// insert when a `block`-policy gate refuses a transition.
/// `handoff.close` is emitted when the operator (or driver) marks the
/// handoff resolved — see `PaneSessionDriver.markHandoffResolved`.
public enum HandoffChainEvent: String, Sendable {
    case open  = "handoff.open"
    case close = "handoff.close"
}

extension BlockedHandoff {
    /// U.11a-4 — operator-readable structured render of a blocked
    /// handoff. Returns a multi-line block built from typed fields
    /// only; never inputs raw stdout/stderr bytes.
    ///
    /// The acceptance bullet "render-without-terminal-output
    /// guarantee" is satisfied because the only string inputs are:
    ///
    ///   - `blockerReason` and `nextAction` — both constructed from
    ///     typed identifiers in `WorkflowGate.evaluate` (see a-3's
    ///     structured-reason invariant); they are not stdout pastes.
    ///   - `evidenceBundle` entries — structured pointers (file
    ///     paths or `token_events#<rowid>` references); each entry is
    ///     surfaced as `evidence: <pointer>`, never inlined.
    ///
    /// Format is line-oriented with a `BlockedHandoff` header so a
    /// CLI / pane surface can `grep` for handoff blocks in a log
    /// stream. Field order is fixed for diff-stability.
    public func render() -> String {
        let evidenceLines: String
        if evidenceBundle.isEmpty {
            evidenceLines = "  (no evidence references)"
        } else {
            evidenceLines = evidenceBundle
                .map { "  - evidence: \($0)" }
                .joined(separator: "\n")
        }
        return """
        BlockedHandoff
          handoff_id: \(id.uuidString)
          workstream_id: \(workstreamID.uuidString)
          gate_id: \(gateID.uuidString)
          owner: \(owner.rawValue)
          reason: \(blockerReason)
          next_action: \(nextAction)
          evidence:
        \(evidenceLines)
        """
    }
}
