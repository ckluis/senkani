import Foundation

/// One entry in the static egress allow / deny list. The rule engine is
/// deny-wins: if any matching rule is `.deny`, the request is blocked;
/// otherwise an `.allow` match wins; otherwise the engine falls back to
/// the deny-on-miss default.
///
/// Match modes (Carmack audit 2026-05-06: keep matchers boring):
///   - `.exact`  — host equals (post-normalization) the rule pattern.
///   - `.prefix` — host starts with the rule pattern. The pattern MUST
///     end at a host-label boundary (`.`) or be the full host. So
///     `example.com` (prefix) matches `example.com` and
///     `api.example.com` does NOT match — that's what `.suffix` is for.
///     `.prefix` is intended for path-style allowlists (rare here).
///   - `.suffix` — host ends with the rule pattern at a label boundary.
///     `example.com` matches `example.com` AND `api.example.com` AND
///     `deep.api.example.com`, but NOT `notexample.com`. This is the
///     usual mode an operator means by "allow example.com and its
///     subdomains."
///   - `.glob`   — `*` matches any single label sequence; one `*` only;
///     intended for `*.example.com` style. We deliberately don't ship
///     full POSIX glob — the surface is too forgiving and the deny-by-
///     default semantics are what matter.
public struct EgressRule: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable, Codable {
        case exact, prefix, suffix, glob
    }
    public enum Decision: String, Sendable, Equatable, Codable {
        case allow, deny
    }

    public let id: String
    public let pattern: String
    public let mode: Mode
    public let decision: Decision

    public init(id: String, pattern: String, mode: Mode, decision: Decision) {
        self.id = id
        self.pattern = pattern
        self.mode = mode
        self.decision = decision
    }

    /// Does this rule match the (already-normalized) host? Pattern is
    /// also normalized at evaluation time so the operator doesn't have
    /// to remember to lowercase / strip ports in their config.
    public func matches(host: String) -> Bool {
        let p = EgressHostNormalizer.normalize(pattern)
        switch mode {
        case .exact:
            return host == p
        case .prefix:
            if host == p { return true }
            return host.hasPrefix(p)
        case .suffix:
            if host == p { return true }
            // Label-boundary anchor: `api.example.com` matches `example.com`
            // because the character before `example.com` in the host is `.`.
            // `notexample.com` does NOT match because the character before
            // `example.com` is `t` (no boundary).
            guard host.hasSuffix(p) else { return false }
            let prefixLen = host.count - p.count
            if prefixLen == 0 { return true }
            let boundaryIdx = host.index(host.startIndex, offsetBy: prefixLen - 1)
            return host[boundaryIdx] == "."
        case .glob:
            return Self.globMatch(pattern: p, host: host)
        }
    }

    /// Single-`*` glob matcher. Examples:
    ///   - `*.example.com`     matches `api.example.com`, `a.b.example.com`
    ///   - `api.*.example.com` matches `api.east.example.com`
    /// Multiple `*` returns false rather than falling back to a more
    /// permissive matcher — keeps blast radius bounded.
    private static func globMatch(pattern: String, host: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return parts.count == 1 && String(parts[0]) == host
        }
        let head = String(parts[0])
        let tail = String(parts[1])
        guard host.hasPrefix(head), host.hasSuffix(tail) else { return false }
        let middleLen = host.count - head.count - tail.count
        if middleLen < 0 { return false }
        // Disallow empty middle UNLESS the pattern was something like
        // `*foo` (head empty) — the empty-middle case there is fine.
        if middleLen == 0 && !head.isEmpty && !tail.isEmpty { return false }
        return true
    }
}

/// Static rule engine evaluation result.
public struct EgressEvaluation: Sendable, Equatable {
    public let decision: EgressRule.Decision
    public let ruleId: String

    public init(decision: EgressRule.Decision, ruleId: String) {
        self.decision = decision
        self.ruleId = ruleId
    }

    /// Sentinel emitted when no rule matches. The default policy is
    /// `deny-wins-on-miss` — Schneier audit 2026-05-06: any future
    /// "deferred decision to operator" mode must NOT silently change
    /// this sentinel; it must add a separate path.
    public static let defaultDeny = EgressEvaluation(decision: .deny, ruleId: "default-deny")
}

public struct EgressRuleEngine: Sendable {
    public let rules: [EgressRule]

    public init(rules: [EgressRule]) {
        self.rules = rules
    }

    /// Evaluate a host against the rule set. The host argument may be
    /// raw — the engine normalizes it internally before matching.
    /// Deny-wins: the first matching `.deny` short-circuits regardless
    /// of any later `.allow`.
    public func evaluate(host: String) -> EgressEvaluation {
        let normalized = EgressHostNormalizer.normalize(host)
        var firstAllow: EgressRule?
        for rule in rules where rule.matches(host: normalized) {
            if rule.decision == .deny {
                return EgressEvaluation(decision: .deny, ruleId: rule.id)
            }
            if firstAllow == nil {
                firstAllow = rule
            }
        }
        if let allow = firstAllow {
            return EgressEvaluation(decision: .allow, ruleId: allow.id)
        }
        return .defaultDeny
    }
}
