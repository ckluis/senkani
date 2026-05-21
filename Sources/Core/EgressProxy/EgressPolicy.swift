import Foundation

/// Per-pane-mode egress policy bundle for T.1b.
///
/// An `EgressPolicy` carries one `EgressRuleEngine` per `PaneMode`. The
/// connection handler resolves the request's pane mode from the
/// `X-Senkani-Pane-Mode` header (defaulting to `.general`) and routes
/// the host through that mode's engine. A static-miss either fires the
/// judge fallback (`.research`, `.write`, `.general`) or denies
/// outright (`.redteam`).
///
/// The on-disk format is `~/.senkani/egress-policy.json`:
///
/// ```json
/// {
///   "modes": {
///     "general":  [{"id": "...", "pattern": "...", "mode": "exact|...", "decision": "allow|deny"}],
///     "research": [...],
///     "write":    [...],
///     "redteam":  [...]
///   }
/// }
/// ```
///
/// A missing mode key falls back to the built-in defaults below — that
/// way an operator who only customizes `redteam` doesn't accidentally
/// blanket-deny `general`-pane traffic.
public struct EgressPolicy: Sendable, Equatable {
    /// One engine per mode. Always covers all 4 cases (built-in
    /// defaults fill in missing keys at load time).
    public let engines: [PaneMode: EgressRuleEngine]

    public init(engines: [PaneMode: EgressRuleEngine]) {
        self.engines = engines
    }

    /// The engine for a given pane mode. Guaranteed non-nil because
    /// `init(loading:)` and `defaults()` always populate all 4 keys.
    public func engine(for mode: PaneMode) -> EgressRuleEngine {
        engines[mode] ?? engines[.default] ?? EgressRuleEngine(rules: [])
    }

    // MARK: - Defaults

    /// Built-in policy used when no `egress-policy.json` is present, or
    /// to fill missing-mode keys when one is. The defaults are
    /// intentionally minimal — a fresh install denies everything; the
    /// operator opts in by editing the file. The defaults reserve
    /// rule-id prefixes per mode so audit rows are mode-attributable.
    public static func defaults() -> EgressPolicy {
        var dict: [PaneMode: EgressRuleEngine] = [:]
        for mode in PaneMode.allCases {
            dict[mode] = EgressRuleEngine(rules: [])
        }
        return EgressPolicy(engines: dict)
    }

    // MARK: - Loader

    /// On-disk JSON wire-shape. Decoded at daemon start; never
    /// re-loaded on a per-request hot path.
    private struct Wire: Codable {
        let modes: [String: [WireRule]]
    }

    private struct WireRule: Codable {
        let id: String
        let pattern: String
        let mode: String      // exact|prefix|suffix|glob
        let decision: String  // allow|deny
    }

    /// Encode this policy to the same JSON wire-shape `load(from:)`
    /// reads. The dispatcher writes its per-target override policy via
    /// this serializer so a live EgressProxy daemon (or test stub) can
    /// pick it up via `SENKANI_EGRESS_POLICY_OVERRIDE`. Output is
    /// byte-stable (`[.sortedKeys, .withoutEscapingSlashes]`).
    public func encodeWireJSON() throws -> Data {
        var modes: [String: [WireRule]] = [:]
        for mode in PaneMode.allCases {
            let engine = engines[mode] ?? EgressRuleEngine(rules: [])
            modes[mode.rawValue] = engine.rules.map { r in
                WireRule(id: r.id, pattern: r.pattern,
                         mode: r.mode.rawValue, decision: r.decision.rawValue)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire(modes: modes))
    }

    /// Load from a JSON file path. Missing file → defaults. Malformed
    /// file → defaults (with a stderr warning the daemon surfaces;
    /// tests detect this via the `degradedReason` channel below). Per-
    /// mode keys not present in the file fall through to the
    /// `defaults()` engine for that mode — partial customization is
    /// supported.
    public static func load(from path: String) -> (policy: EgressPolicy, degradedReason: String?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return (defaults(), nil)
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            return (defaults(), "egress-policy.json parse failure: \(error.localizedDescription)")
        }

        var engines: [PaneMode: EgressRuleEngine] = [:]
        for mode in PaneMode.allCases {
            let key = mode.rawValue
            guard let wireRules = wire.modes[key] else {
                engines[mode] = EgressRuleEngine(rules: [])
                continue
            }
            let parsed: [EgressRule] = wireRules.compactMap { w in
                guard let m = EgressRule.Mode(rawValue: w.mode),
                      let d = EgressRule.Decision(rawValue: w.decision) else {
                    return nil
                }
                return EgressRule(id: w.id, pattern: w.pattern, mode: m, decision: d)
            }
            engines[mode] = EgressRuleEngine(rules: parsed)
        }
        return (EgressPolicy(engines: engines), nil)
    }
}
