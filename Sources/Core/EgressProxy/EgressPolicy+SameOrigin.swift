import Foundation

extension EgressPolicy {
    /// U.2a-2b — same-origin allowlist policy for browser validation
    /// dispatch. The Chromium subprocess routes through the EgressProxy
    /// daemon (T.1a) with this policy active so off-allowlist requests
    /// are denied with the engine's structured rule_id while the page's
    /// own host (and its label-bound subdomains) load normally.
    ///
    /// Construction:
    ///   - One rule: `id="validate_browser_same_origin", mode=.suffix,
    ///     decision=.allow, pattern=<targetURL.host>`.
    ///   - Same rule applied to ALL `PaneMode` engines so the policy is
    ///     pane-mode-agnostic (validation dispatch isn't an operator
    ///     pane).
    ///
    /// Off-host requests fall to the default-deny sentinel
    /// (`EgressEvaluation.defaultDeny`) — the same behavior the daemon
    /// already exhibits on an unmatched host.
    ///
    /// Returns `nil` when the URL has no host component (e.g.
    /// `file://`); the dispatcher refuses to spawn the browser in that
    /// case rather than fall back to a permissive policy.
    public static func sameOriginAllowlist(targetURL: URL) -> EgressPolicy? {
        guard let host = targetURL.host, !host.isEmpty else { return nil }
        let normalized = EgressHostNormalizer.normalize(host)
        let rule = EgressRule(
            id: "validate_browser_same_origin",
            pattern: normalized,
            mode: .suffix,
            decision: .allow
        )
        let engine = EgressRuleEngine(rules: [rule])
        var engines: [PaneMode: EgressRuleEngine] = [:]
        for mode in PaneMode.allCases {
            engines[mode] = engine
        }
        return EgressPolicy(engines: engines)
    }
}
