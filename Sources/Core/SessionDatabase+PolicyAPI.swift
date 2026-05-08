import Foundation

/// Façade extension that fronts `PolicyStore` so callers (MCP server
/// bootstrap, CLI, replay harness) don't reach into the internal store
/// directly. Mirrors the pattern in `SessionDatabase+CommandAPI.swift`.
extension SessionDatabase {
    /// Capture the live policy and persist it against `sessionId`.
    /// Returns `true` if a new snapshot row landed, `false` when an
    /// identical-hash row already exists (the dedup case — no error)
    /// **or** when capturing the live state failed because the
    /// learned-rules file is present but unreadable / unencodable. In
    /// the failure case the call bumps
    /// `event_counters("security.policy.learned_rules_hash_failed")`
    /// so the breach surfaces in `senkani stats --security`.
    @discardableResult
    public func capturePolicySnapshot(
        sessionId: String,
        projectRoot: String? = nil
    ) -> Bool {
        let config: PolicyConfig
        do {
            config = try PolicyConfig.capture(projectRoot: projectRoot)
        } catch {
            recordEvent(
                type: "security.policy.learned_rules_hash_failed",
                projectRoot: projectRoot
            )
            return false
        }
        return policyStore.capture(sessionId: sessionId, config: config)
    }

    /// Persist a pre-built `PolicyConfig` against `sessionId`. Used by
    /// tests and any caller that already constructed the snapshot
    /// (replay fixtures, scheduled-task bootstraps).
    @discardableResult
    public func recordPolicySnapshot(
        sessionId: String,
        config: PolicyConfig
    ) -> Bool {
        return policyStore.capture(sessionId: sessionId, config: config)
    }

    /// Most-recent snapshot for a session, or nil if none exist.
    public func latestPolicySnapshot(sessionId: String) -> PolicySnapshotRow? {
        return policyStore.latest(sessionId: sessionId)
    }

    /// All snapshots for a session, newest first.
    public func allPolicySnapshots(sessionId: String) -> [PolicySnapshotRow] {
        return policyStore.all(sessionId: sessionId)
    }
}
