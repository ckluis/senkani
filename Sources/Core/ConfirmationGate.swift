import Foundation

/// Phase T.6a — write/exec confirmation gate.
///
/// Every write/exec-tagged tool call walks the gate. The gate consults
/// `MCPToolCatalog` to decide whether the tool requires confirmation;
/// if so, it asks the injected `policyResolver` for a decision and
/// records the outcome in the `confirmations` table (chained via T.5).
/// Read-tagged tools short-circuit with a no-row, `.auto` approval.
///
/// Round 1 default policy: `.auto` approval for every write/exec call,
/// but every approval still writes a chained row. Schneier's red flag
/// in the round-1 audit: an auto-approve default that doesn't audit is
/// invisible — the chained-row invariant is what makes this defensible.
///
/// Round T.6b's Settings UI lets the operator wire a real
/// `policyResolver` that prompts on `.write` / `.exec` and returns
/// `.approve` / `.deny`. Round T.6c routes the deny event to a
/// `NotificationSink`.
public enum ConfirmationGate {

    /// Resolved decision the caller acts on. Distinct from
    /// `ConfirmationDecision` so the gate can return "no row, just
    /// pass" for `.read` tools without inventing a fake row.
    public struct Outcome: Sendable, Equatable {
        /// What to do.
        public let decision: ConfirmationDecision
        /// Who decided.
        public let decidedBy: ConfirmationDecidedBy
        /// Optional human-readable reason, surfaced in the
        /// structured-error response for `.deny`.
        public let reason: String?
        /// rowid of the chained `confirmations` row, or -1 if no row
        /// was written (read-tagged tool, gate disabled).
        public let rowid: Int64

        public init(
            decision: ConfirmationDecision,
            decidedBy: ConfirmationDecidedBy,
            reason: String? = nil,
            rowid: Int64 = -1
        ) {
            self.decision = decision
            self.decidedBy = decidedBy
            self.reason = reason
            self.rowid = rowid
        }

        /// Convenience: the gate said pass.
        public var allows: Bool {
            decision == .approve || decision == .auto
        }
    }

    /// Policy resolver — given a tool name + catalog entry, return the
    /// decision. The default returns `.auto` (decided_by `auto`),
    /// matching the round-1 "every auto still audits" contract.
    public typealias PolicyResolver = @Sendable (
        _ toolName: String,
        _ config: MCPToolConfig
    ) -> (decision: ConfirmationDecision, decidedBy: ConfirmationDecidedBy, reason: String?)

    /// Production default. Auto-approve for every write/exec call and
    /// record the row with `decided_by='auto'`. Settings UI replaces
    /// this with a prompting resolver.
    public static let defaultResolver: PolicyResolver = { _, _ in
        return (.auto, .auto, nil)
    }

    /// Process-wide override. Tests + Settings UI assign here. The
    /// production default stays put when nothing was set.
    nonisolated(unsafe) public static var resolver: PolicyResolver = defaultResolver

    /// Test seam. Production uses `.shared`; tests pass a temp DB.
    nonisolated(unsafe) static var database: SessionDatabase = .shared

    /// Test seam. Production uses `MCPToolCatalog.shared`; tests pass
    /// a fresh catalog with a controlled tag set.
    nonisolated(unsafe) static var catalog: MCPToolCatalog = .shared

    /// Reset back to production defaults. Test fixtures call this in
    /// teardown to undo any resolver / database / catalog stub.
    public static func resetToDefaults() {
        resolver = defaultResolver
        database = .shared
        catalog = .shared
    }

    /// Evaluate whether this tool call should be confirmed, run the
    /// resolver if so, and persist the outcome. Returns the decision
    /// the caller should act on.
    @discardableResult
    public static func evaluate(toolName: String, requestedAt: Date = Date()) -> Outcome {
        // Unknown tools and read-tagged tools skip the gate entirely.
        // No row is written — this keeps the chain dense with rows that
        // actually represent a write/exec decision. (Schneier:
        // confirmations log is "things we asked about", not "every
        // tool call".)
        guard let config = catalog.config(for: toolName), config.requiresConfirmation else {
            return Outcome(
                decision: .auto,
                decidedBy: .auto,
                reason: nil,
                rowid: -1
            )
        }

        let (decision, decidedBy, reason) = resolver(toolName, config)
        let row = ConfirmationRow(
            toolName: toolName,
            requestedAt: requestedAt,
            decidedAt: Date(),
            decision: decision,
            decidedBy: decidedBy,
            reason: reason
        )
        let rowid = database.recordConfirmation(row)
        return Outcome(
            decision: decision,
            decidedBy: decidedBy,
            reason: reason,
            rowid: rowid
        )
    }

    /// Build the structured-error reason string the agent caller sees
    /// when the gate denies a call. Norman's audit: the message must
    /// name the tool and give a non-empty reason. The exact wording
    /// is the contract HookRouter / ToolRouter callers depend on.
    public static func denyReason(toolName: String, reason: String?) -> String {
        let detail = (reason?.isEmpty == false) ? reason! : "operator denied confirmation"
        return "Confirmation denied for '\(toolName)': \(detail)"
    }
}
