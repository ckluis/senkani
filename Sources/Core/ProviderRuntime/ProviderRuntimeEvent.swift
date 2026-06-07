import Foundation

/// Phase V.17a-1 — canonical event the four provider-runtime adapters
/// (Codex CLI, Claude Code, Gemini CLI, OpenCode — v17a-2..5) all emit,
/// and the spine the V.17b dashboard + V.17c thread-handoff guardrails
/// hang off of. One value per observable runtime moment: a message
/// chunk, a tool call boundary, an approval / input prompt, a
/// turn boundary, or a warning.
///
/// Conformed dimensions match the V.2 `AgentTraceEvent` vocabulary
/// (`pane`, `session_id`, `tool_call_id`) so the projection helper
/// (`ProviderRuntimeEventStore.projectIntoAgentTrace(_:)`) can write
/// through to the existing canonical-trace row without a second
/// translation table. `provider_id` is the new dimension — every event
/// names its source adapter so a multi-provider session can be sliced
/// by adapter without joining anywhere.
///
/// Provenance: `rawPayloadHash` is the SHA-256 of the originating
/// stream slice that produced this event. The store enforces it
/// UNIQUE at the SQL layer — a retry of the same JSONL line lands one
/// row, not two, even if the adapter is restarted mid-stream
/// (Schneier: derive idempotency from canonical inputs, not from
/// caller-supplied keys).
///
/// Audit-chain note: `provider_runtime_event` is NOT in the T.5 audit
/// chain. This is an accepted risk per V.2 precedent — the V.2
/// `agent_trace_event` canonical row itself doesn't participate in
/// the chain because it is one tier of derivation away from the
/// chain-anchored `token_events` source. V.17a's
/// `provider_runtime_event` is one further tier from any chained
/// source. Tampering is detectable by re-deriving from the underlying
/// CLI session logs (paths recorded in the adapter implementation).
public struct ProviderRuntimeEvent: Sendable, Equatable {

    /// The ten canonical runtime moments. V.17a's parent decomposition
    /// (2026-05-23) locks this set — adapters in v17a-2..5 must not
    /// introduce provider-specific cases; new vocabulary requires a
    /// follow-on backlog item that extends both this enum and the
    /// projection helper in one go.
    public enum EventType: String, Sendable, CaseIterable, Codable {
        case messageStarted     = "message_started"
        case messageDelta       = "message_delta"
        case toolCallStarted    = "tool_call_started"
        case toolCallFinished   = "tool_call_finished"
        case approvalRequested  = "approval_requested"
        case approvalGranted    = "approval_granted"
        case userInputRequested = "user_input_requested"
        case turnCompleted      = "turn_completed"
        case turnAborted        = "turn_aborted"
        case warning            = "warning"
    }

    /// Token snapshot recorded on events that carry usage information
    /// (typically `messageDelta`, `turnCompleted`). All fields default
    /// to nil — adapters populate only what the underlying CLI surface
    /// actually reports.
    public struct TokenSnapshot: Sendable, Equatable, Codable {
        public let promptTokens: Int?
        public let completionTokens: Int?
        public let cachedTokens: Int?

        public init(
            promptTokens: Int? = nil,
            completionTokens: Int? = nil,
            cachedTokens: Int? = nil
        ) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.cachedTokens = cachedTokens
        }
    }

    /// Status of the V.2 projection (write-through to
    /// `agent_trace_event`). The store sets this when the event is
    /// inserted; readers can filter to projected rows without joining.
    public enum ProjectionStatus: String, Sendable, CaseIterable, Codable {
        /// Event type is not projection-eligible (only
        /// `toolCallFinished` and `turnCompleted` project today).
        case ineligible
        /// Projection-eligible but not yet attempted. Stored on
        /// `insert(event:)` for eligible events; the projection helper
        /// flips this when it runs.
        case pending
        /// Projection helper ran and wrote a new
        /// `agent_trace_event` row.
        case projected
        /// Projection helper ran and observed an idempotency hit
        /// (the canonical trace row already existed). The provider
        /// event is still recorded; the projection just dedup'd.
        case dedup
    }

    // MARK: - Conformed dimensions

    /// The adapter that emitted this event. Stable per provider over
    /// the life of the project (e.g. `codex`, `claude_code`, `gemini`,
    /// `opencode`). Cross-cutting queries can pivot by `providerID`
    /// without joining the events table to an adapter table.
    public let providerID: String

    /// Senkani session id. Pairs with `agent_trace_event.session_id`
    /// added in migration v32 for the cross-cutting join.
    public let sessionID: String?

    /// Senkani thread id. Optional because not every adapter exposes
    /// a thread layer above sessions.
    public let threadID: String?

    /// Provider-level turn id. Stable across the events of one turn so
    /// `messageStarted → messageDelta* → turnCompleted` correlate
    /// without timestamp guessing.
    public let turnID: String?

    /// Pane this event belongs to. Pairs with
    /// `agent_trace_event.pane`.
    public let pane: String?

    // MARK: - Event facts

    public let type: EventType

    /// Wall-clock moment the event was observed (adapter-side, not
    /// store-side).
    public let observedAt: Date

    /// Token snapshot for events that carry usage information. nil for
    /// events without a usage shape.
    public let tokens: TokenSnapshot?

    /// For `toolCallStarted` / `toolCallFinished`: the provider's
    /// tool-call id. Pairs with `agent_trace_event.tool_call_id`.
    public let toolCallID: String?

    /// For `toolCallStarted`: the provider-side tool name (e.g.
    /// "shell.exec", "file.read"). nil for non-tool events.
    public let toolName: String?

    /// For `toolCallFinished`: the typed outcome (`success`,
    /// `error`, `denied`, etc. — provider-specific strings; not
    /// constrained by an enum because adapters vary).
    public let toolResult: String?

    /// For `approvalRequested`/`approvalGranted`: the approval
    /// identifier so request/grant pairs correlate.
    public let approvalID: String?

    /// Per-event warning strings. Always a list (possibly empty); not
    /// a separate event type because most adapters emit warnings
    /// inline with other events.
    public let warnings: [String]

    /// Status of the V.2 projection. Set to `.ineligible` for events
    /// whose `type` doesn't project; `.pending` for eligible events
    /// pre-projection; the projection helper flips to `.projected` or
    /// `.dedup`.
    public let projectionStatus: ProjectionStatus

    /// SHA-256 of the originating stream slice. Drives the SQL-layer
    /// UNIQUE constraint. Adapters compute this from the raw bytes
    /// they ingested; the store does not recompute.
    public let rawPayloadHash: String

    // MARK: - Init

    public init(
        providerID: String,
        sessionID: String? = nil,
        threadID: String? = nil,
        turnID: String? = nil,
        pane: String? = nil,
        type: EventType,
        observedAt: Date,
        tokens: TokenSnapshot? = nil,
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolResult: String? = nil,
        approvalID: String? = nil,
        warnings: [String] = [],
        projectionStatus: ProjectionStatus = .ineligible,
        rawPayloadHash: String
    ) {
        self.providerID = providerID
        self.sessionID = sessionID
        self.threadID = threadID
        self.turnID = turnID
        self.pane = pane
        self.type = type
        self.observedAt = observedAt
        self.tokens = tokens
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolResult = toolResult
        self.approvalID = approvalID
        self.warnings = warnings
        self.projectionStatus = projectionStatus
        self.rawPayloadHash = rawPayloadHash
    }

    /// True when the event's type projects into `agent_trace_event`.
    /// Today only `.toolCallFinished` and `.turnCompleted` project —
    /// they map to "one canonical trace row per tool call /
    /// per turn". Other event types stay raw for the V.17b dashboard
    /// + V.17c thread-handoff guardrails to read directly.
    public var isProjectable: Bool {
        switch type {
        case .toolCallFinished, .turnCompleted:
            return true
        case .messageStarted, .messageDelta, .toolCallStarted,
             .approvalRequested, .approvalGranted,
             .userInputRequested, .turnAborted, .warning:
            return false
        }
    }
}
