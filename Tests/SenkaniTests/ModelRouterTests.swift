import Testing
import Foundation
@testable import Core

// MARK: - Suite 1: Difficulty Scoring

@Suite("ModelRouter — Difficulty Scoring")
struct DifficultyScoreTests {

    @Test func trivialCommandScoresLow() {
        let score = ModelRouter.scoreDifficulty("ls")
        #expect(score <= 2, "Trivial command should score 1-2, got \(score)")
    }

    @Test func simpleTaskScoresLow() {
        let score = ModelRouter.scoreDifficulty("run tests")
        #expect(score >= 2 && score <= 5, "Simple task should score 2-5, got \(score)")
    }

    @Test func moderateTaskScoresMid() {
        let score = ModelRouter.scoreDifficulty("fix the login bug in auth.ts")
        #expect(score >= 4 && score <= 7, "Moderate task should score 4-7, got \(score)")
    }

    @Test func complexTaskScoresHigh() {
        let score = ModelRouter.scoreDifficulty("refactor auth middleware for better security")
        #expect(score >= 6 && score <= 10, "Complex task should score 6-10, got \(score)")
    }

    @Test func frontierTaskScoresMax() {
        let score = ModelRouter.scoreDifficulty(
            "refactor the entire authentication system across all microservices from scratch"
        )
        #expect(score >= 8, "Frontier task should score 8-10, got \(score)")
    }

    @Test func emptyPromptReturnsLowScore() {
        let score = ModelRouter.scoreDifficulty("")
        #expect(score >= 1 && score <= 3, "Empty prompt should score low, got \(score)")
    }

    @Test func veryLongPromptBumpsDifficulty() {
        let longPrompt = String(repeating: "implement feature ", count: 50)
        #expect(longPrompt.count > 500)
        let score = ModelRouter.scoreDifficulty(longPrompt)
        #expect(score >= 6, "Very long prompt should score high, got \(score)")
    }
}

// MARK: - Suite 2: Tier Mapping Boundaries

@Suite("ModelRouter — Tier Mapping")
struct TierMappingTests {

    @Test func score1MapsToLocal() {
        #expect(ModelRouter.tierForScore(1) == .local)
    }

    @Test func score2MapsToLocal() {
        #expect(ModelRouter.tierForScore(2) == .local)
    }

    @Test func score3MapsToQuick() {
        #expect(ModelRouter.tierForScore(3) == .quick)
    }

    @Test func score4MapsToQuick() {
        #expect(ModelRouter.tierForScore(4) == .quick)
    }

    @Test func score5MapsToBalanced() {
        #expect(ModelRouter.tierForScore(5) == .balanced)
    }

    @Test func score7MapsToBalanced() {
        #expect(ModelRouter.tierForScore(7) == .balanced)
    }

    @Test func score8MapsToFrontier() {
        #expect(ModelRouter.tierForScore(8) == .frontier)
    }

    @Test func score10MapsToFrontier() {
        #expect(ModelRouter.tierForScore(10) == .frontier)
    }
}

// MARK: - Suite 3: Preset Override

@Suite("ModelRouter — Preset Override")
struct PresetOverrideTests {

    @Test func autoPresetUsesScoring() {
        let result = ModelRouter.resolve(prompt: "refactor auth middleware", preset: .auto, gemma4Downloaded: true)
        #expect(result.tier == .balanced || result.tier == .frontier,
                "Auto on complex prompt should route to balanced or frontier, got \(result.tier)")
    }

    @Test func buildPresetAlwaysBalanced() {
        let result = ModelRouter.resolve(prompt: "ls", preset: .build)
        #expect(result.tier == .balanced, "Build preset should always use balanced, got \(result.tier)")
    }

    @Test func researchPresetAlwaysFrontier() {
        let result = ModelRouter.resolve(prompt: "ls", preset: .research)
        #expect(result.tier == .frontier, "Research preset should always use frontier, got \(result.tier)")
    }

    @Test func quickPresetAlwaysQuick() {
        let result = ModelRouter.resolve(prompt: "refactor everything from scratch", preset: .quick)
        #expect(result.tier == .quick, "Quick preset should always use quick, got \(result.tier)")
    }

    @Test func localPresetFallsBackWhenNoModel() {
        let result = ModelRouter.resolve(
            prompt: "hello",
            preset: .local,
            availableRAMGB: 2,
            gemma4Downloaded: false
        )
        #expect(result.tier == .quick, "Local should fall back to quick when no model, got \(result.tier)")
        #expect(result.reason.lowercased().contains("fallback") || result.reason.lowercased().contains("available"),
                "Reason should explain fallback: \(result.reason)")
    }
}

// MARK: - Suite 4: RAM Gating

@Suite("ModelRouter — RAM Gating")
struct RAMGatingTests {

    @Test func localWithSufficientRAMAndDownloadedModel() {
        let result = ModelRouter.resolve(
            prompt: "analyze screenshot",
            preset: .local,
            availableRAMGB: 16,
            gemma4Downloaded: true
        )
        #expect(result.tier == .local, "Local with sufficient RAM + model should stay local, got \(result.tier)")
    }

    @Test func autoLocalFallsBackNoGemma() {
        // Score 1 would map to .local, but no model → falls back to .quick
        let result = ModelRouter.resolve(
            prompt: "ls",
            preset: .auto,
            availableRAMGB: 16,
            gemma4Downloaded: false
        )
        #expect(result.tier == .quick, "Auto local tier should fall back to quick when no Gemma 4, got \(result.tier)")
    }
}

// MARK: - Suite 5: Env Var Values

@Suite("ModelRouter — Env Var Values")
struct EnvVarTests {

    @Test func tierClaudeModelValues() {
        #expect(ModelTier.local.claudeModelValue == "local")
        #expect(ModelTier.quick.claudeModelValue == "claude-haiku-3.5")
        #expect(ModelTier.balanced.claudeModelValue == "claude-sonnet-4")
        #expect(ModelTier.frontier.claudeModelValue == "claude-opus-4")
    }

    @Test func presetToEnvVarIntegration() {
        let result = ModelRouter.resolve(prompt: "anything", preset: .build)
        #expect(result.tier.claudeModelValue == "claude-sonnet-4",
                "Build → balanced → claude-sonnet-4, got \(result.tier.claudeModelValue)")
    }
}

// MARK: - Suite 6: TaskTier Ladder + Clamp (U.1a)

@Suite("ModelRouter — TaskTier Ladder")
struct TaskTierLadderTests {

    // FallbackLadder cap

    @Test func fallbackLadderRejectsFourEntriesViaSafeInit() {
        let four: [ModelTier] = [.local, .quick, .balanced, .frontier]
        #expect(FallbackLadder(safe: four) == nil,
                "Ladder with 4 entries must be rejected (cap is 3)")
    }

    @Test func fallbackLadderRejectsEmptyViaSafeInit() {
        #expect(FallbackLadder(safe: []) == nil,
                "Empty ladder must be rejected — at least one rung required")
    }

    @Test func fallbackLadderAcceptsOneTwoOrThreeEntries() {
        #expect(FallbackLadder(safe: [.quick]) != nil)
        #expect(FallbackLadder(safe: [.quick, .balanced]) != nil)
        #expect(FallbackLadder(safe: [.local, .quick, .balanced]) != nil)
    }

    @Test func defaultLadderForReasoningHasOnlyOneRung() {
        let ladder = FallbackLadder.default(for: .reasoning)
        #expect(ladder.entries == [.frontier],
                "Reasoning tier ladder must be Opus-only, no auto-fallback")
    }

    @Test func defaultLadderForSimpleStartsLocal() {
        let ladder = FallbackLadder.default(for: .simple)
        #expect(ladder.primary == .local,
                "Simple tier primary should be local Gemma")
        #expect(ladder.entries.count >= 2,
                "Simple tier should have a fallback rung for no-Gemma machines")
    }

    // BudgetGate clamp

    @Test func clampUnlimitedBudgetReturnsDesired() {
        let unlimited = BudgetConfig()
        #expect(BudgetGate.clamp(taskTier: .reasoning, budget: unlimited) == .reasoning)
        #expect(BudgetGate.clamp(taskTier: .simple, budget: unlimited) == .simple)
    }

    @Test func clampTinyDailyBudgetForcesSimple() {
        let tight = BudgetConfig(dailyLimitCents: 50)  // $0.50/day
        #expect(BudgetGate.clamp(taskTier: .reasoning, budget: tight) == .simple,
                "$0.50/day must clamp reasoning down to simple")
    }

    @Test func clampMidDailyBudgetForcesStandard() {
        let mid = BudgetConfig(dailyLimitCents: 300)  // $3/day
        #expect(BudgetGate.clamp(taskTier: .reasoning, budget: mid) == .standard,
                "$3/day must clamp reasoning down to standard")
    }

    @Test func clampGenerousDailyBudgetAllowsComplex() {
        let generous = BudgetConfig(dailyLimitCents: 1500)  // $15/day
        #expect(BudgetGate.clamp(taskTier: .reasoning, budget: generous) == .complex,
                "$15/day must clamp reasoning down to complex (just under the $20 reasoning floor)")
    }

    @Test func clampLargeDailyBudgetAllowsReasoning() {
        let large = BudgetConfig(dailyLimitCents: 5000)  // $50/day
        #expect(BudgetGate.clamp(taskTier: .reasoning, budget: large) == .reasoning,
                "$50/day must permit reasoning")
    }

    @Test func clampWeeklyBudgetDividedBySeven() {
        // $5/week → ~$0.71/day equivalent → strictly under the
        // simple ceiling ($1/day). Confirms weekly→daily division.
        let weekly = BudgetConfig(weeklyLimitCents: 500)
        #expect(BudgetGate.clamp(taskTier: .complex, budget: weekly) == .simple,
                "$5/week ≈ $0.71/day must clamp complex to simple")
    }

    @Test func clampDoesNotElevateBelowDesired() {
        let huge = BudgetConfig(dailyLimitCents: 10_000)  // $100/day
        #expect(BudgetGate.clamp(taskTier: .simple, budget: huge) == .simple,
                "Clamp must never elevate desired tier — only floor it")
    }

    // ModelRouter.resolve(taskTier:)

    @Test func resolveWithTaskTierUsesPrimaryRung() {
        let unlimited = BudgetConfig()
        let result = ModelRouter.resolve(
            taskTier: .standard,
            budget: unlimited,
            availableRAMGB: 16,
            gemma4Downloaded: true
        )
        // Standard ladder = [.quick, .balanced]; primary = .quick.
        #expect(result.tier == .quick,
                "Standard primary rung should be quick (Haiku)")
        #expect(result.reason.contains("primary"),
                "Reason should record which rung was used: \(result.reason)")
    }

    @Test func resolveWithTaskTierWalksLocalRungWhenNoGemma() {
        let unlimited = BudgetConfig()
        let result = ModelRouter.resolve(
            taskTier: .simple,
            budget: unlimited,
            availableRAMGB: 16,
            gemma4Downloaded: false
        )
        // Simple ladder = [.local, .quick]; local unavailable → walks to .quick.
        #expect(result.tier == .quick,
                "Simple primary should walk past .local when Gemma 4 unavailable, got \(result.tier)")
    }

    @Test func resolveWithTaskTierClampsByBudget() {
        let tight = BudgetConfig(dailyLimitCents: 50)  // $0.50/day → simple ceiling
        let result = ModelRouter.resolve(
            taskTier: .reasoning,
            budget: tight,
            availableRAMGB: 16,
            gemma4Downloaded: true
        )
        #expect(result.tier == .local,
                "Reasoning under tight budget must clamp to simple → local primary, got \(result.tier)")
        #expect(result.reason.contains("clamped"),
                "Reason should record the clamp: \(result.reason)")
    }

    @Test func resolveWithExplicitLadderBypassesDefault() {
        let unlimited = BudgetConfig()
        let custom = FallbackLadder(entries: [.frontier])
        let result = ModelRouter.resolve(
            taskTier: .standard,
            budget: unlimited,
            availableRAMGB: 16,
            gemma4Downloaded: true,
            ladder: custom
        )
        #expect(result.tier == .frontier,
                "Explicit ladder must be honored regardless of TaskTier default")
    }

    @Test func resolveSynthesizesFallbackForOneRungLocalLadder() {
        // A pathological one-rung-of-local ladder + no Gemma → must
        // synthesize .quick rather than crash or return .local.
        let unlimited = BudgetConfig()
        let oneRung = FallbackLadder(entries: [.local])
        let result = ModelRouter.resolve(
            taskTier: .simple,
            budget: unlimited,
            availableRAMGB: 16,
            gemma4Downloaded: false,
            ladder: oneRung
        )
        #expect(result.tier == .quick,
                "One-rung local ladder must synthesize .quick when Gemma 4 unavailable, got \(result.tier)")
        #expect(result.reason.lowercased().contains("synthesized"),
                "Reason must flag the synthesis: \(result.reason)")
    }

    // TaskTier ordering

    @Test func taskTierComparableOrdering() {
        #expect(TaskTier.simple < TaskTier.standard)
        #expect(TaskTier.standard < TaskTier.complex)
        #expect(TaskTier.complex < TaskTier.reasoning)
    }
}
