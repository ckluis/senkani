import Foundation

/// U.11a-1 — first contract surface that lives on top of the U.11-pre
/// runtime scaffold (workstreams table + `PaneSessionDriver`). A
/// `WorkstreamTaskContract` is the structured handoff between
/// operator intent and a driver-managed pane session: it pins
/// objective, file scope, allowed tools, dependencies, budget,
/// command list, acceptance assertion ids, and a review tier.
///
/// The 11 fields below match the scope bullet in the per-item file.
/// The off-by-one in the item's `## Acceptance` line ("10 fields") is
/// a typo — counting the listed names gives 11; we ship the named
/// fields. The closing summary calls this out.
///
/// U.3 leg 3 adds an OPTIONAL `task_class` field (the `--allow-classes`
/// class gate). It is JSON-only: encoded into `contracts.json` when present
/// and omitted when nil (`encodeIfPresent`), with NO DB column (the v39
/// `workstream_contracts` table is never written by the autorun loop). A nil
/// `taskClass` encodes byte-identically to the pre-leg-3 shape.
///
/// `acceptance: [UUID]` is wire-only here — the assertion type
/// (`ValidationAssertion`) and its FK lookup land in a-2.
///
/// JSON round-trip is byte-identical when encoded with the canonical
/// encoder (sorted keys + ISO-8601 dates). Persistence in v39's
/// `workstream_contracts` table stores list-typed fields and the
/// nested `budget` as JSON TEXT columns; raw column types are
/// chosen for query-side filters (BLOB UUIDs, TEXT enums).
public struct WorkstreamTaskContract: Codable, Equatable, Sendable {
    public let id: UUID
    public let workstreamID: UUID
    public let objective: String
    public let fileScope: [String]
    public let allowedTools: [String]
    public let dependencies: [UUID]
    public let staleSpecAt: Date?
    public let budget: ContractBudget
    public let commands: [String]
    public let acceptance: [UUID]
    public let reviewLevel: ReviewLevel
    /// U.3 leg-3 inferred task class (the `--allow-classes` gate). Optional
    /// and JSON-only: omitted from the encoding when nil; no DB column.
    public let taskClass: TaskClass?

    public init(
        id: UUID,
        workstreamID: UUID,
        objective: String,
        fileScope: [String],
        allowedTools: [String],
        dependencies: [UUID],
        staleSpecAt: Date?,
        budget: ContractBudget,
        commands: [String],
        acceptance: [UUID],
        reviewLevel: ReviewLevel,
        taskClass: TaskClass? = nil
    ) {
        self.id = id
        self.workstreamID = workstreamID
        self.objective = objective
        self.fileScope = fileScope
        self.allowedTools = allowedTools
        self.dependencies = dependencies
        self.staleSpecAt = staleSpecAt
        self.budget = budget
        self.commands = commands
        self.acceptance = acceptance
        self.reviewLevel = reviewLevel
        self.taskClass = taskClass
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workstreamID = "workstream_id"
        case objective
        case fileScope = "file_scope"
        case allowedTools = "allowed_tools"
        case dependencies
        case staleSpecAt = "stale_spec_at"
        case budget
        case commands
        case acceptance
        case reviewLevel = "review_level"
        case taskClass = "task_class"
    }
}

/// Per-contract budget — wall-clock and token caps the driver
/// enforces before yielding control back to the operator. Both
/// caps are required; callers pass explicit zero to disable.
public struct ContractBudget: Codable, Equatable, Sendable {
    public let tokensMax: Int
    public let wallClockMaxS: Int

    public init(tokensMax: Int, wallClockMaxS: Int) {
        self.tokensMax = tokensMax
        self.wallClockMaxS = wallClockMaxS
    }

    private enum CodingKeys: String, CodingKey {
        case tokensMax = "tokens_max"
        case wallClockMaxS = "wall_clock_max_s"
    }
}

/// Review tier the contract demands before a pane session closes
/// the task out. Raw values are stable strings — persisted in
/// `workstream_contracts.review_level` and serialized through
/// Codable.
public enum ReviewLevel: String, Codable, CaseIterable, Sendable {
    case none
    case selfReview = "self_review"
    case codexReview = "codex_review"
    case operatorReview = "operator_review"
}

/// The two `token_events.source` strings emitted by the
/// `recordContractEvent` writer. Sibling to
/// `WorkstreamChainEvent` — same chaining mechanics under the
/// `migration-v39` anchor.
///
/// Rows chain under the `migration-v39` (or post-v39 `fresh-
/// install`) `token_events` anchor.
public enum ContractChainEvent: String, Sendable {
    case attach  = "contract.attach"
    case advance = "contract.advance"
}
