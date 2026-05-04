import Foundation

/// Façade extension that fronts `PolicyStore` so callers (MCP server
/// bootstrap, CLI, replay harness) don't reach into the internal store
/// directly. Mirrors the pattern in `SessionDatabase+CommandAPI.swift`.
extension SessionDatabase {
    /// Capture the live policy and persist it against `sessionId`.
    /// Returns `true` if a new snapshot row landed, `false` when an
    /// identical-hash row already exists (the dedup case — no error).
    @discardableResult
    public func capturePolicySnapshot(
        sessionId: String,
        projectRoot: String? = nil
    ) -> Bool {
        let config = PolicyConfig.capture(projectRoot: projectRoot)
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
