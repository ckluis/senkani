import Foundation

/// U.11a-2 — second contract surface that lives on top of a-1's
/// `WorkstreamTaskContract`. A `ValidationAssertion` is the structural
/// FK shape behind a contract's `acceptance: [UUID]` wire field: it
/// names the kind of check (lint / tests / perf / security / design /
/// completeness / custom), references evidence rows that already exist
/// in the data plane (`validation_results` via
/// `validationRunIDs`, `agent_trace_event` via
/// `agentTraceRefs`), and carries an explicit pass/fail/partial state.
///
/// Operator decisions locked in (decompose interview 2026-05-25):
///   - Q2 — assertion link = structural FK + composite, both optional
///     (0..n). Allows partial linkage; an assertion may hold no
///     evidence (provisional `.partial`) or evidence from either or
///     both stores.
///
/// Persistence note: a-2 ships no new table. The struct + chain row
/// kind (`assertion.record`) live alongside the existing v39 anchor.
/// A later child (a-4) lands the dedicated `workstream_assertions`
/// table if persistence beyond chain rows is needed.
public struct ValidationAssertion: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: AssertionKind
    /// 0..n structural FK references to `validation_results.validation_run_id`.
    /// Resolution does NOT enforce existence at construction time —
    /// `SessionDatabase.resolveValidationRuns(_:)` returns a structured
    /// `(resolved, unresolved)` partition so callers can act on
    /// missing evidence without crashing.
    public let validationRunIDs: [UUID]
    /// 0..n composite references to `agent_trace_event`
    /// `(session_id, tool_call_id)` rows. Resolution mirrors
    /// `validationRunIDs` — `SessionDatabase.resolveAgentTraceRefs(_:)`
    /// returns the same structured partition.
    public let agentTraceRefs: [AgentTraceRef]
    /// Authoritative state. The owner may set this explicitly even
    /// when evidence rows tell a different story (e.g. "still
    /// gathering data" overrides → `.partial` despite an all-clean
    /// resolved set). For derivation directly from evidence, see
    /// `ValidationAssertion.deriveState(...)`.
    public let state: AssertionState

    public init(
        id: UUID,
        kind: AssertionKind,
        validationRunIDs: [UUID],
        agentTraceRefs: [AgentTraceRef],
        state: AssertionState
    ) {
        self.id = id
        self.kind = kind
        self.validationRunIDs = validationRunIDs
        self.agentTraceRefs = agentTraceRefs
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case validationRunIDs = "validation_run_ids"
        case agentTraceRefs   = "agent_trace_refs"
        case state
    }

    /// Derive an `AssertionState` directly from resolved evidence.
    /// Callers that want the derived value pass `nil` for
    /// `override`; callers carrying an explicit override (the
    /// `ValidationAssertion.state` field at write time) pass that
    /// value to short-circuit the derivation.
    ///
    /// Algorithm:
    ///   - explicit override → returned verbatim.
    ///   - no resolved evidence on either side → `.partial`.
    ///   - all evidence clean → `.pass`.
    ///   - all evidence non-clean → `.fail`.
    ///   - mixed (any clean + any non-clean) → `.partial`.
    ///
    /// "Clean" predicate:
    ///   - `ValidationResultRow.outcome == "clean"` → pass.
    ///   - `AgentTraceEvent.result == .success` → pass.
    public static func deriveState(
        validationEvidence: ValidationEvidenceResolution,
        agentTraceEvidence: AgentTraceEvidenceResolution,
        override: AssertionState? = nil
    ) -> AssertionState {
        if let override { return override }
        var passCount = 0
        var failCount = 0
        for e in validationEvidence.resolved {
            if e.outcome == "clean" { passCount += 1 } else { failCount += 1 }
        }
        for e in agentTraceEvidence.resolved {
            if e.result == .success { passCount += 1 } else { failCount += 1 }
        }
        if passCount == 0 && failCount == 0 { return .partial }
        if failCount == 0 { return .pass }
        if passCount == 0 { return .fail }
        return .partial
    }
}

/// The 7 kinds an assertion may name. Six known cases plus a `custom`
/// variant carrying a free-text name. Codable shape:
///   - known kinds → `{"kind": "tests_green"}` (snake_case raw form).
///   - custom      → `{"kind": "custom", "name": "<free text>"}`.
public enum AssertionKind: Codable, Equatable, Sendable, Hashable {
    case testsGreen
    case lintClean
    case perfWithinBudget
    case securityClean
    case designApproved
    case completenessCheck
    case custom(name: String)

    /// Stable string identifier for the kind. The serialized form
    /// for known cases; the tag for the `custom` case (carried with a
    /// separate `name` key).
    public var rawIdentifier: String {
        switch self {
        case .testsGreen:        return "tests_green"
        case .lintClean:         return "lint_clean"
        case .perfWithinBudget:  return "perf_within_budget"
        case .securityClean:     return "security_clean"
        case .designApproved:    return "design_approved"
        case .completenessCheck: return "completeness_check"
        case .custom:            return "custom"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kindStr = try c.decode(String.self, forKey: .kind)
        switch kindStr {
        case "tests_green":        self = .testsGreen
        case "lint_clean":         self = .lintClean
        case "perf_within_budget": self = .perfWithinBudget
        case "security_clean":     self = .securityClean
        case "design_approved":    self = .designApproved
        case "completeness_check": self = .completenessCheck
        case "custom":
            let name = try c.decode(String.self, forKey: .name)
            self = .custom(name: name)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "Unknown AssertionKind kind: \(kindStr)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rawIdentifier, forKey: .kind)
        if case .custom(let name) = self {
            try c.encode(name, forKey: .name)
        }
    }
}

/// Composite reference to one `agent_trace_event` row. SessionID +
/// toolCallID is the (V.18a-5) cross-cutting JOIN key that already
/// exists in the table. The pair is the natural primary key for that
/// store's per-tool-call evidence even though the column-level UNIQUE
/// constraint is on `idempotency_key`.
public struct AgentTraceRef: Codable, Equatable, Sendable, Hashable {
    public let sessionID: UUID
    public let toolCallID: String

    public init(sessionID: UUID, toolCallID: String) {
        self.sessionID = sessionID
        self.toolCallID = toolCallID
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID  = "session_id"
        case toolCallID = "tool_call_id"
    }
}

/// Authoritative assertion state. Stored on the `ValidationAssertion`
/// at the point a recorder lands the chain row; derivable from
/// evidence via `ValidationAssertion.deriveState(...)`.
public enum AssertionState: String, Codable, CaseIterable, Sendable {
    case pass
    case fail
    case partial
}

/// The single `token_events.source` string emitted by the
/// `recordAssertionEvent` writer. Sibling to `ContractChainEvent` /
/// `WorkstreamChainEvent` — same chaining mechanics under the
/// `migration-v39` anchor.
public enum AssertionChainEvent: String, Sendable {
    case record = "assertion.record"
}

/// One resolved `validation_results` evidence row backing a
/// `ValidationAssertion.validationRunIDs` entry. Carries the bits
/// `deriveState` needs (outcome + exit_code) without re-exposing the
/// full ValidationStore row shape.
public struct ResolvedValidationEvidence: Sendable, Equatable {
    public let runID: UUID
    public let resultRowID: Int64
    public let outcome: String
    public let exitCode: Int32

    public init(runID: UUID, resultRowID: Int64, outcome: String, exitCode: Int32) {
        self.runID = runID
        self.resultRowID = resultRowID
        self.outcome = outcome
        self.exitCode = exitCode
    }
}

/// Structured (resolved, unresolved) partition for a batch lookup
/// against `validation_results` by `validation_run_id`. Unresolved
/// IDs are surfaced as data (not thrown) so callers can decide
/// whether a partial resolution is recoverable.
public struct ValidationEvidenceResolution: Sendable, Equatable {
    public let resolved: [ResolvedValidationEvidence]
    public let unresolved: [UUID]

    public init(resolved: [ResolvedValidationEvidence], unresolved: [UUID]) {
        self.resolved = resolved
        self.unresolved = unresolved
    }

    public var hasUnresolved: Bool { !unresolved.isEmpty }
}

/// One resolved `agent_trace_event` evidence row backing a
/// `ValidationAssertion.agentTraceRefs` entry. Carries the bits
/// `deriveState` needs (`result` enum) plus the idempotency key for
/// downstream JOINs / diagnostics.
public struct ResolvedAgentTraceEvidence: Sendable, Equatable {
    public let ref: AgentTraceRef
    public let idempotencyKey: String
    public let result: CallResult

    public init(ref: AgentTraceRef, idempotencyKey: String, result: CallResult) {
        self.ref = ref
        self.idempotencyKey = idempotencyKey
        self.result = result
    }
}

/// Structured (resolved, unresolved) partition for a batch lookup
/// against `agent_trace_event` by `(session_id, tool_call_id)`.
/// Mirrors `ValidationEvidenceResolution`.
public struct AgentTraceEvidenceResolution: Sendable, Equatable {
    public let resolved: [ResolvedAgentTraceEvidence]
    public let unresolved: [AgentTraceRef]

    public init(resolved: [ResolvedAgentTraceEvidence], unresolved: [AgentTraceRef]) {
        self.resolved = resolved
        self.unresolved = unresolved
    }

    public var hasUnresolved: Bool { !unresolved.isEmpty }
}
