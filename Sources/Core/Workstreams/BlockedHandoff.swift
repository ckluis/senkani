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
/// are stable strings — they appear in any future
/// `workstream_handoffs.owner` column and serialize through Codable.
///
/// `operator` is a Swift keyword in operator-declaration context; the
/// case uses backticks to bypass the keyword and keep the wire form
/// `"operator"`.
public enum HandoffOwner: String, Codable, CaseIterable, Sendable {
    case `operator`
    case autonomousLoop  = "autonomous_loop"
    case externalService = "external_service"
}
