import Foundation

/// Pane-mode taxonomy for T.1b egress policy framing.
///
/// Each open pane has exactly one resolved mode at any given time.
/// The mode shapes BOTH the per-pane allowlist consulted by the static
/// engine AND the prompt framing for the judge fallback.
///
/// `redteam` is the safety-critical case: a redteam pane is performing
/// adversarial work where any model-layer "allow" decision is ipso
/// facto wrong (Vitalik posture: a judge can be prompted into allowing
/// exfiltration; the deny-on-miss invariant must not yield to it). On
/// a static-miss for a redteam pane, the daemon denies WITHOUT
/// invoking the judge.
public enum PaneMode: String, Sendable, Codable, Equatable, CaseIterable {
    case research
    case write
    case redteam
    case general

    public static let `default` = PaneMode.general

    /// Whether the judge fallback is allowed for this pane-mode.
    /// `redteam` returns false — see the Vitalik note above.
    public var allowsJudge: Bool {
        self != .redteam
    }

    /// Internal proxy header name carrying the pane mode from the
    /// client (HookRouter-managed subprocess) to the daemon. The
    /// daemon strips this header before forwarding upstream so it is
    /// never visible to the external host.
    public static let proxyHeader = "X-Senkani-Pane-Mode"

    /// Parse a header value back to the typed enum. Returns
    /// `.default` (`.general`) on missing or unrecognized values —
    /// the deny-on-miss invariant lives in the rule engine, not in
    /// the pane-mode parser.
    public static func parseHeaderValue(_ raw: String?) -> PaneMode {
        guard let raw else { return .default }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return PaneMode(rawValue: trimmed) ?? .default
    }
}
