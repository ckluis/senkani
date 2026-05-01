import Foundation

/// Phase V.5c — bridges the KB write (`KnowledgeStore.backfillNullAuthorship`)
/// with the chain-participating audit log (`SessionDatabase.recordCommand`).
///
/// The CLI command (`senkani authorship backfill`) does flag parsing,
/// dry-run preview, and stdout formatting; the actual side-effects live
/// here so the same code path is testable end-to-end against a temp
/// `KnowledgeStore` + temp `SessionDatabase`. Each backfill batch lands
/// one row in the chained `commands` table — that row is the
/// "self-audited row in the chain" required by the V.5c acceptance.
///
/// Cavoukian invariant: this entry point ONLY runs when an operator
/// explicitly invokes the CLI subcommand. There is no automatic /
/// implicit / scheduled call site for this helper anywhere in the
/// codebase, and adding one would violate the V.5 contract.
public enum AuthorshipBackfillRunner {

    public struct Result: Sendable, Equatable {
        /// Rows actually written. Equal to the dry-run count when the
        /// table is quiescent; smaller when concurrent writes flipped
        /// some rows off the NULL predicate between the count and the
        /// UPDATE (rare — the CLI invocation is single-shot).
        public let updated: Int
        /// The fresh session id created to anchor the audit-chain row,
        /// or `nil` if `updated == 0` (no batch, no audit row needed).
        public let auditSessionId: String?
    }

    /// Run a backfill batch end-to-end:
    ///
    /// 1. Bulk-update legacy NULL rows in the KB.
    /// 2. If any rows were written, open a fresh session in
    ///    `sessionDatabase` and record one `commands` row with
    ///    `tool_name="authorship.backfill"`. The recordCommand path is
    ///    the chain-participating insert (Phase T.5 round 3) — every
    ///    row carries `prev_hash`/`entry_hash`/`chain_anchor_id`.
    /// 3. Close the session.
    ///
    /// The audit row is written even for partial success; the only
    /// "no audit row" case is `updated == 0` (idempotent re-run).
    @discardableResult
    public static func run(
        store: KnowledgeStore,
        sessionDatabase: SessionDatabase,
        since: Date,
        sinceLabel: String,
        tag: AuthorshipTag,
        projectRoot: String? = nil
    ) -> Result {
        let updated = store.backfillNullAuthorship(since: since, tag: tag)
        guard updated > 0 else {
            return Result(updated: 0, auditSessionId: nil)
        }
        let sessionId = sessionDatabase.createSession(
            projectRoot: projectRoot,
            agentType: nil
        )
        sessionDatabase.recordCommand(
            sessionId: sessionId,
            toolName: "authorship.backfill",
            command: "--since \(sinceLabel) --tag \(tag.rawValue)",
            rawBytes: 0,
            compressedBytes: 0,
            feature: "kb_authorship_backfill",
            outputPreview: "rows=\(updated) tag=\(tag.rawValue)"
        )
        sessionDatabase.endSession(sessionId: sessionId)
        return Result(updated: updated, auditSessionId: sessionId)
    }
}
