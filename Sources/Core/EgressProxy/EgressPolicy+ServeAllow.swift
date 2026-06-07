import Foundation

/// V.13b-4b (Option B, operator decision 2026-06-01) — serve-arm egress
/// allow-rule DETECTION + the operator-actionable HINT.
///
/// Deny-on-miss is PRESERVED: senkani never auto-adds an allow rule for an
/// external host (that would silently weaken the default egress trust
/// posture — `EgressEvaluation.defaultDeny`'s standing Schneier note). The
/// operator authorizes `api.anthropic.com` egress explicitly by editing
/// `~/.senkani/egress-policy.json`; `senkani doctor` (and, once b-4c wires
/// it, `senkani serve`) SURFACE a one-line hint when that authorization is
/// absent — an actionable pointer instead of an opaque default-deny.
public extension EgressPolicy {

    /// The pane mode the serve path resolves to. Serve sends no
    /// `X-Senkani-Pane-Mode` header, so the daemon resolves
    /// `PaneMode.default` (`.general`).
    static var serveMode: PaneMode { .default }

    /// Does this policy ALLOW `host` under `mode` (static decision ==
    /// `.allow`)? False on deny / default-deny.
    func allows(host: String, mode: PaneMode = EgressPolicy.serveMode) -> Bool {
        engine(for: mode).evaluate(host: host).decision == .allow
    }

    /// One-line operator-actionable hint to surface at serve/doctor startup
    /// when `host` lacks an allow rule under the serve mode; `nil` when it
    /// IS allowed (no hint needed). Default `host` is the Anthropic API.
    func serveEgressAllowHint(host: String = "api.anthropic.com") -> String? {
        guard !allows(host: host) else { return nil }
        return "no egress allow rule for \(host) — to serve the Anthropic arm, add "
            + "{\"id\":\"serve-anthropic\",\"pattern\":\"\(host)\",\"mode\":\"exact\",\"decision\":\"allow\"} "
            + "under \"general\" in ~/.senkani/egress-policy.json "
            + "(deny-on-miss is the default; senkani will not add it for you)"
    }
}
