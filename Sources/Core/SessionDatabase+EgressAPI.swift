import Foundation

/// Session DB façade for the EgressProxy decision audit log (Phase T.1a).
/// Mirrors `SessionDatabase+TokenEventAPI` shape.
extension SessionDatabase {

    /// Record one allow/deny decision emitted by the rule engine. Best-
    /// effort: a SQLite write failure does not propagate — the listener
    /// must keep running even if the audit DB is offline. Returns
    /// `true` on a successful chained insert.
    @discardableResult
    public func recordEgressDecision(
        host: String,
        method: String,
        decision: EgressRule.Decision,
        ruleId: String,
        latencyUs: Int64 = 0,
        paneId: String? = nil,
        projectRoot: String? = nil
    ) -> Bool {
        egressDecisionStore.record(
            host: host,
            method: method,
            decision: decision,
            ruleId: ruleId,
            latencyUs: latencyUs,
            paneId: paneId,
            projectRoot: projectRoot
        )
    }

    /// Most recent decisions in descending id order.
    public func recentEgressDecisions(limit: Int = 100) -> [EgressDecisionStore.Row] {
        egressDecisionStore.recent(limit: limit)
    }

    /// Total decision count. Surfaced by `senkani doctor` and the egress
    /// status subcommand so the operator can see policy activity.
    public func egressDecisionCount() -> Int64 {
        egressDecisionStore.count()
    }

    /// Drop the chain cache after a `--repair-chain`. Called by
    /// `ChainRepairer` (round 4 wired all four legacy participants;
    /// future rounds extend coverage to this table).
    func invalidateEgressDecisionsChainCache() {
        queue.sync {
            egressDecisionStore.invalidateChainCache()
        }
    }
}
