import Foundation

// MARK: - Model Preset

/// User-selectable model routing preset. Persisted per-pane.
/// Controls which Claude model tier handles tasks in a given terminal.
public enum ModelPreset: String, Codable, Sendable, CaseIterable {
    case auto       // Difficulty-based routing (default)
    case build      // Always Sonnet 4 — build/deploy tasks
    case research   // Always Opus 4 — deep research/refactoring
    case quick      // Always Haiku 3.5 — fast/cheap
    case local      // Gemma 4 only (no API) — air-gapped work

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .build: return "Build"
        case .research: return "Research"
        case .quick: return "Quick"
        case .local: return "Local"
        }
    }

    public var icon: String {
        switch self {
        case .auto: return "sparkles"
        case .build: return "hammer"
        case .research: return "magnifyingglass"
        case .quick: return "hare"
        case .local: return "desktopcomputer"
        }
    }

    public var description: String {
        switch self {
        case .auto: return "Routes to the cheapest capable model per task"
        case .build: return "Sonnet 4 — reliable for build and deploy tasks"
        case .research: return "Opus 4 — deep analysis, complex refactoring"
        case .quick: return "Haiku 3.5 — fast and cheap for simple tasks"
        case .local: return "Gemma 4 on-device — private, offline, $0"
        }
    }
}

// MARK: - Model Tier

/// Maps to a specific Claude model or local model.
public enum ModelTier: String, Codable, Sendable {
    case local     // Gemma 4 (on-device, $0)
    case quick     // claude-haiku-3.5
    case balanced  // claude-sonnet-4
    case frontier  // claude-opus-4

    /// The CLAUDE_MODEL env var value for this tier.
    public var claudeModelValue: String {
        switch self {
        case .local: return "local"
        case .quick: return "claude-haiku-3.5"
        case .balanced: return "claude-sonnet-4"
        case .frontier: return "claude-opus-4"
        }
    }

    /// Estimated cost per hour at typical usage (~50K tokens/hr).
    public var estimatedCostPerHour: Double {
        switch self {
        case .local: return 0.0
        case .quick: return 0.12
        case .balanced: return 0.45
        case .frontier: return 2.25
        }
    }

    public var displayName: String {
        switch self {
        case .local: return "Local (Gemma 4)"
        case .quick: return "Haiku 3.5"
        case .balanced: return "Sonnet 4"
        case .frontier: return "Opus 4"
        }
    }
}

// MARK: - Model Router

/// Routes tasks to model tiers based on difficulty scoring and user presets.
///
/// Carmack: All methods are pure functions with <0.1ms latency.
/// No regex, no DB queries, no model loading on the routing hot path.
public struct ModelRouter: Sendable {

    /// Result of a routing decision.
    public struct Decision: Sendable {
        public let tier: ModelTier
        public let score: Int
        public let reason: String
        /// TaskTier the router chose (intent), independent of the
        /// concrete `tier` (engine). nil for the legacy preset path
        /// where TaskTier wasn't computed.
        public let taskTier: TaskTier?
        /// Which rung of the FallbackLadder produced `tier`.
        /// 0 = primary, 1 = first fallback, 2 = second fallback.
        /// Synthesized fallbacks (e.g. one-rung-local + no Gemma) report
        /// the synthetic position as 1.
        public let ladderPosition: Int

        public init(
            tier: ModelTier,
            score: Int,
            reason: String,
            taskTier: TaskTier? = nil,
            ladderPosition: Int = 0
        ) {
            self.tier = tier
            self.score = score
            self.reason = reason
            self.taskTier = taskTier
            self.ladderPosition = ladderPosition
        }
    }

    // MARK: - Difficulty Scoring

    /// Score prompt difficulty 1-10. Pure string analysis, <0.1ms.
    /// No regex. No allocations beyond the input string scan.
    public static func scoreDifficulty(_ prompt: String) -> Int {
        let lower = prompt.lowercased()
        var score = 5

        // Trivial signals (score -= 2 each)
        let trivialVerbs = ["ls", "pwd", "cat", "echo", "cd", "mkdir", "rm", "mv", "cp",
                            "chmod", "which", "type", "date", "whoami", "hostname", "touch"]
        for verb in trivialVerbs {
            if lower.hasPrefix(verb) && (lower.count == verb.count || lower[lower.index(lower.startIndex, offsetBy: verb.count)] == " ") {
                score -= 2
                break
            }
        }

        if prompt.count < 20 { score -= 2 }

        // Simple signals (score -= 1 each, cap at -2)
        let simpleSignals = ["run ", "build ", "test ", "install ", "deploy ", "start ", "stop ",
                             "lint ", "format ", "check "]
        var simpleHits = 0
        for signal in simpleSignals {
            if lower.contains(signal) { simpleHits += 1 }
        }
        score -= min(simpleHits, 2)

        // Complex signals (score += 1 each, cap at +3)
        let complexSignals = ["refactor", "migrate", "architect", "design", "optimize",
                              "security", "audit", "performance", "debug", "investigate"]
        var complexHits = 0
        for signal in complexSignals {
            if lower.contains(signal) { complexHits += 1 }
        }
        score += min(complexHits, 3)

        // Frontier signals (score += 2 each, cap at +4)
        let frontierSignals = ["across multiple", "entire codebase", "from scratch",
                               "comprehensive", "all files"]
        var frontierHits = 0
        for signal in frontierSignals {
            if lower.contains(signal) { frontierHits += 1 }
        }
        score += min(frontierHits * 2, 4)

        // Long prompts tend to be complex
        if prompt.count > 500 { score += 2 }
        else if prompt.count > 200 { score += 1 }

        return max(1, min(10, score))
    }

    // MARK: - Tier Mapping

    /// Map a difficulty score (1-10) to a model tier.
    /// Boundaries: 1-2→local, 3-4→quick, 5-7→balanced, 8-10→frontier
    public static func tierForScore(_ score: Int) -> ModelTier {
        switch score {
        case 1...2: return .local
        case 3...4: return .quick
        case 5...7: return .balanced
        default:    return .frontier  // 8-10
        }
    }

    /// Map a difficulty score (1-10) to a TaskTier (the *work*).
    /// Boundaries align with `tierForScore`:
    ///   1-2 → simple    (local-class — small / trivial)
    ///   3-4 → standard  (quick-class — routine engineering)
    ///   5-7 → complex   (balanced-class — non-trivial reasoning)
    ///   8-10 → reasoning (frontier-class — opt-in deep work)
    public static func taskTierForScore(_ score: Int) -> TaskTier {
        switch score {
        case 1...2: return .simple
        case 3...4: return .standard
        case 5...7: return .complex
        default:    return .reasoning  // 8-10
        }
    }

    /// Classify a prompt to its TaskTier — the U.1b corpus gate calls
    /// this. Pure function over `scoreDifficulty`; no I/O, no allocs
    /// beyond the input scan.
    public static func classify(prompt: String) -> TaskTier {
        taskTierForScore(scoreDifficulty(prompt))
    }

    // MARK: - Resolution

    /// Resolve the final model tier for a prompt + preset combination.
    ///
    /// - If preset != .auto, returns the fixed tier for that preset.
    /// - If preset == .auto, scores the prompt and maps to a tier.
    /// - RAM gating: if tier is .local but Gemma 4 isn't available, falls back to .quick.
    public static func resolve(
        prompt: String,
        preset: ModelPreset,
        availableRAMGB: Int = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)),
        gemma4Downloaded: Bool = false
    ) -> Decision {
        switch preset {
        case .build:
            return Decision(tier: .balanced, score: 0, reason: "Build preset → Sonnet 4")
        case .research:
            return Decision(tier: .frontier, score: 0, reason: "Research preset → Opus 4")
        case .quick:
            return Decision(tier: .quick, score: 0, reason: "Quick preset → Haiku 3.5")
        case .local:
            if gemma4Downloaded && availableRAMGB >= 4 {
                return Decision(tier: .local, score: 0, reason: "Local preset → Gemma 4 on-device")
            } else {
                return Decision(tier: .quick, score: 0,
                    reason: "Local preset fallback → no Gemma 4 model available, using Haiku 3.5")
            }
        case .auto:
            let score = scoreDifficulty(prompt)
            var tier = tierForScore(score)

            // RAM-gate local tier: if no Gemma 4, fall back to quick
            if tier == .local && !gemma4Downloaded {
                tier = .quick
                return Decision(tier: tier, score: score,
                    reason: "Auto scored \(score) → local, but no Gemma 4 available → Haiku 3.5")
            }

            return Decision(tier: tier, score: score,
                reason: "Auto scored \(score) → \(tier.displayName)")
        }
    }

    // MARK: - TaskTier-aware Resolution (U.1a)

    /// Resolve a TaskTier-driven routing decision through the
    /// FallbackLadder + BudgetGate clamp. Distinct from the legacy
    /// `resolve(prompt:preset:...)` path — callers that have a
    /// TaskTier in hand (e.g. from a planner output) skip the
    /// difficulty-scoring heuristic.
    ///
    /// Resolution order:
    ///   1. Clamp the desired TaskTier against the budget ceiling.
    ///   2. Pick the ladder (custom or default-for-clamped-tier).
    ///   3. Try the primary rung. If it's `.local` and Gemma 4 is
    ///      unavailable, walk to the next rung. Synthesize `.quick`
    ///      as a final fallback only if the ladder lacks a second
    ///      rung — keeps the "no silent surprises" contract.
    public static func resolve(
        taskTier desired: TaskTier,
        budget: BudgetConfig = BudgetConfig.load(),
        availableRAMGB: Int = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)),
        gemma4Downloaded: Bool = false,
        ladder: FallbackLadder? = nil
    ) -> Decision {
        let clamped = BudgetGate.clamp(taskTier: desired, budget: budget)
        let chosenLadder = ladder ?? FallbackLadder.default(for: clamped)
        let clampNote = (clamped == desired)
            ? ""
            : " (clamped from \(desired.rawValue) by budget)"

        var tier = chosenLadder.primary
        var rungUsed = 0

        // RAM-gate the local rung — walk to the next rung if Gemma 4
        // can't actually run.
        let canRunLocal = gemma4Downloaded && availableRAMGB >= 4
        if tier == .local && !canRunLocal {
            if chosenLadder.entries.count > 1 {
                tier = chosenLadder.entries[1]
                rungUsed = 1
            } else {
                tier = .quick
                let reason = "TaskTier \(desired.rawValue)\(clampNote) → \(tier.displayName) (synthesized fallback — local unavailable, ladder had no second rung)"
                return Decision(
                    tier: tier, score: 0, reason: reason,
                    taskTier: clamped, ladderPosition: 1
                )
            }
        }

        let rungNote = rungUsed == 0 ? "primary rung" : "rung \(rungUsed + 1)"
        let reason = "TaskTier \(desired.rawValue)\(clampNote) → \(tier.displayName) (\(rungNote))"
        return Decision(
            tier: tier, score: 0, reason: reason,
            taskTier: clamped, ladderPosition: rungUsed
        )
    }
}
