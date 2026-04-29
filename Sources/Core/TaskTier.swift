import Foundation

// MARK: - TaskTier

/// Names *the work*, not *the engine*. Distinct from `ModelTier` which
/// names a specific model bin (local / quick / balanced / frontier).
///
/// The pair is the U.1a separation: routing decides the TaskTier from
/// task signals, then the FallbackLadder maps that to a concrete
/// ModelTier (with a budget clamp on top).
public enum TaskTier: String, Codable, Sendable, CaseIterable, Comparable {
    case simple
    case standard
    case complex
    case reasoning

    /// Ordinal rank — higher = more capable. Used by the budget clamp.
    public var rank: Int {
        switch self {
        case .simple:    return 0
        case .standard:  return 1
        case .complex:   return 2
        case .reasoning: return 3
        }
    }

    public static func < (lhs: TaskTier, rhs: TaskTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - FallbackLadder

/// An ordered list of ModelTiers to try when routing a task. Hard 3-entry
/// cap — Senkani's discipline. (Manifest's 5-entry default is the
/// deliberately undercut anti-pattern: longer ladders silently mask
/// upstream failures and inflate cost without operator awareness.)
///
/// Construction validates the cap. Out-of-range entry counts trip a
/// `precondition` — silent truncation is the worst failure mode for a
/// security-discipline cap. Tests pin the rejection.
public struct FallbackLadder: Sendable, Equatable {
    /// Hard cap. Three rungs is the most a ladder gets — primary + at
    /// most two fallbacks. Anything longer is a smell.
    public static let maxEntries = 3

    public let entries: [ModelTier]

    public init(entries: [ModelTier]) {
        precondition(
            entries.count >= 1 && entries.count <= Self.maxEntries,
            "FallbackLadder requires 1...\(Self.maxEntries) entries (got \(entries.count))"
        )
        self.entries = entries
    }

    /// Non-trapping constructor — returns nil instead of trapping.
    /// Used by tests that pin rejection without crashing the runner.
    public init?(safe entries: [ModelTier]) {
        guard entries.count >= 1 && entries.count <= Self.maxEntries else {
            return nil
        }
        self.entries = entries
    }

    /// First rung — the preferred ModelTier.
    public var primary: ModelTier { entries[0] }

    // MARK: Default Mapping

    /// Default ladder for a TaskTier. Each TaskTier gets a primary +
    /// (sometimes) a single fallback rung. Reasoning is opt-in only,
    /// so it has no automatic fallback — if Opus is unavailable, the
    /// caller deals.
    public static func `default`(for tier: TaskTier) -> FallbackLadder {
        switch tier {
        case .simple:
            // Local Gemma → Haiku if RAM/model unavailable.
            return FallbackLadder(entries: [.local, .quick])
        case .standard:
            // Haiku → Sonnet if degraded mode.
            return FallbackLadder(entries: [.quick, .balanced])
        case .complex:
            // Sonnet primary → Opus on retry.
            return FallbackLadder(entries: [.balanced, .frontier])
        case .reasoning:
            // Opus only — operator opt-in, no auto-fallback.
            return FallbackLadder(entries: [.frontier])
        }
    }
}

// MARK: - BudgetGate

/// Pure-function budget clamp on TaskTier. Given a desired task tier
/// and the current `BudgetConfig`, returns the highest tier the budget
/// can afford. No side effects, no I/O.
///
/// The clamp uses configured ceilings (in cents) — NOT current spend —
/// because this is a *plan* gate, not a *spend* gate. Spend gates live
/// in `HookRouter.checkHookBudgetGate` and `BudgetConfig.check`. This
/// prevents reasoning-tier work from being scheduled on a $5/day pane
/// regardless of whether today's spend is currently at $0 or $4.99.
public struct BudgetGate: Sendable {

    /// Default ceiling boundaries (in cents/day).
    /// Conservative — operators raise these by widening the limit.
    public static let simpleMaxCents: Int   = 100   // <$1/day → simple only
    public static let standardMaxCents: Int = 500   // <$5/day → standard max
    public static let complexMaxCents: Int  = 2000  // <$20/day → complex max
    // ≥$20/day → reasoning permitted

    /// Clamp a desired TaskTier to the highest tier allowed by the
    /// configured budget. Returns `desired` unchanged when no limits
    /// are configured (unlimited budget).
    public static func clamp(taskTier desired: TaskTier, budget: BudgetConfig) -> TaskTier {
        guard let dailyEquivalent = dailyEquivalentCents(of: budget) else {
            return desired
        }
        let ceiling: TaskTier
        switch dailyEquivalent {
        case ..<simpleMaxCents:    ceiling = .simple
        case ..<standardMaxCents:  ceiling = .standard
        case ..<complexMaxCents:   ceiling = .complex
        default:                   ceiling = .reasoning
        }
        return min(desired, ceiling)
    }

    /// Reduce the assorted limits in `BudgetConfig` to a single daily-
    /// equivalent ceiling. Daily wins; weekly is divided by 7; session
    /// is multiplied by an assumed 5 sessions/day. Returns nil when
    /// nothing is configured.
    static func dailyEquivalentCents(of budget: BudgetConfig) -> Int? {
        if let d = budget.dailyLimitCents { return d }
        if let w = budget.weeklyLimitCents { return w / 7 }
        if let s = budget.perSessionLimitCents { return s * 5 }
        return nil
    }
}
