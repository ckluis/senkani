import Foundation

/// T.2c-2 — typed error thrown when a `redteam` pane attempts to
/// dispatch to a non-local `ModelTier`. Per Schneier: a redteam pane
/// is by definition an adversarial workspace; any model-layer dispatch
/// to a remote adapter leaks the adversarial payload outside the
/// daemon. The block is HARD — no operator override — because override
/// would defeat the purpose of marking the pane redteam in the first
/// place.
///
/// Synchronously raised BEFORE any network IO. Callers MUST resolve a
/// `ModelTier` and call `RedteamEgressGuard.enforce(...)` ahead of
/// the actual dispatch call.
public struct RedteamPaneEgressBlocked: Error, Equatable, CustomStringConvertible {
    /// The tier the caller attempted to dispatch into. Carried so
    /// audit-row writers can record which non-local destination was
    /// refused.
    public let tier: ModelTier

    public init(tier: ModelTier) {
        self.tier = tier
    }

    public var description: String {
        "RedteamPaneEgressBlocked: redteam pane refused dispatch to non-local tier \(tier.rawValue)"
    }
}

/// Guard that enforces the redteam-pane outbound-egress block.
///
/// Usage at any `ModelTier` dispatch site:
///
///     try RedteamEgressGuard.enforce(paneMode: paneMode, tier: decision.tier)
///     // … only reached when allowed; safe to invoke the adapter.
///
/// `.local` tiers (Gemma 4 on-device) are always permitted — they
/// don't leave the machine. `.quick` / `.balanced` / `.frontier`
/// (Claude API tiers) are blocked under `.redteam`.
public enum RedteamEgressGuard {
    public static func enforce(paneMode: PaneMode, tier: ModelTier) throws {
        guard paneMode == .redteam else { return }
        if tier != .local {
            throw RedteamPaneEgressBlocked(tier: tier)
        }
    }
}
