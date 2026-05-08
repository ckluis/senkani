import Testing
import Foundation
@testable import MCPServer
@testable import Core

/// Cross-layer budget enforcement tests. Symmetric coverage of the two gates
/// Senkani ships for budget: `await MCPSession.checkBudget()` (ToolRouter path,
/// before MCP-routed tools) and `HookRouter.checkHookBudgetGate(...)` (hook
/// path, before non-MCP tools like Read / Bash / Grep). If one gate
/// regresses, these tests surface it even if the other still passes.
///
/// Asymmetry by design:
/// - MCP gate enforces pane-cap + per-session + daily + weekly (via
///   `await session.checkBudget()` which combines them).
/// - Hook gate enforces daily + weekly only (per-session is MCP-scoped;
///   pane-cap attaches to an `MCPSession` which isn't in scope for hook
///   events on Read/Bash/Grep). This is encoded in `checkHookBudgetGate`
///   passing `sessionCents: 0`.
@Suite("Budget — Dual-layer enforcement (MCP ↔ Hook)")
struct BudgetEnforcementDualLayerTests {

    // MARK: - Helpers

    private func makeSession() -> MCPSession {
        MCPSession(
            projectRoot: "/tmp/senkani-budget-dual-\(UUID().uuidString.prefix(8))",
            filterEnabled: false,
            secretsEnabled: false,
            indexerEnabled: false,
            cacheEnabled: false
        )
    }

    // MARK: - (a) MCP gate — global per-session limit

    @Test("MCP gate blocks on global per-session limit")
    func mcpBlocksOnGlobalSessionLimit() async {
        let session = makeSession()
        // 140 000 raw bytes → 10¢ cost savings (Claude Sonnet 4 pricing).
        await session.recordMetrics(rawBytes: 140_000, compressedBytes: 0, feature: "test")

        let decision = await BudgetConfig.withTestOverrideAsync(
            BudgetConfig(perSessionLimitCents: 10)
        ) {
            await session.checkBudget()
        }

        guard case .block = decision else {
            Issue.record("Expected .block at global per-session hard limit, got \(decision)")
            return
        }
    }

    @Test("MCP gate warns at global per-session soft limit")
    func mcpWarnsOnGlobalSessionSoftLimit() async {
        let session = makeSession()
        // 120 000 bytes → 9¢ — above 8¢ soft limit, below 10¢ hard.
        await session.recordMetrics(rawBytes: 120_000, compressedBytes: 0, feature: "test")

        let decision = await BudgetConfig.withTestOverrideAsync(
            BudgetConfig(perSessionLimitCents: 10)
        ) {
            await session.checkBudget()
        }

        guard case .warn = decision else {
            Issue.record("Expected .warn at soft limit, got \(decision)")
            return
        }
    }

    // MARK: - (b) Hook gate — daily + weekly

    @Test("Hook gate blocks when daily exceeded")
    func hookBlocksWhenDailyExceeded() async {
        let decision = await BudgetConfig.withTestOverrideAsync(
            BudgetConfig(dailyLimitCents: 100)
        ) {
            HookRouter.checkHookBudgetGate(
                projectRoot: "/tmp/proj",
                costForToday: { 150 },
                costForWeek: { 0 }
            )
        }
        guard case .block(let reason) = decision else {
            Issue.record("Expected .block on daily limit exceeded, got \(decision)")
            return
        }
        #expect(reason.contains("Daily"))
    }

    @Test("Hook gate blocks when weekly exceeded")
    func hookBlocksWhenWeeklyExceeded() async {
        let decision = await BudgetConfig.withTestOverrideAsync(
            BudgetConfig(weeklyLimitCents: 500)
        ) {
            HookRouter.checkHookBudgetGate(
                projectRoot: "/tmp/proj",
                costForToday: { 0 },
                costForWeek: { 600 }
            )
        }
        guard case .block(let reason) = decision else {
            Issue.record("Expected .block on weekly limit exceeded, got \(decision)")
            return
        }
        #expect(reason.contains("Weekly"))
    }

    // MARK: - (c) Pane cap — only enforced at MCP layer

    @Test("Pane-cap fires at MCP layer independently of global config")
    func paneCapIndependentOfGlobal() async {
        let session = makeSession()
        await session.updateConfig(budgetSessionCents: 10)
        await session.recordMetrics(rawBytes: 140_000, compressedBytes: 0, feature: "test")

        // No global config at all — pane-cap should still block.
        let decision = await BudgetConfig.withTestOverrideAsync(BudgetConfig()) {
            await session.checkBudget()
        }

        guard case .block(let reason) = decision else {
            Issue.record("Expected pane-cap .block without any global limits, got \(decision)")
            return
        }
        #expect(reason.contains("Pane"))
    }

    // MARK: - (d) Below-limit — both layers pass

    @Test("Below-limit call passes both layers cleanly")
    func bothLayersAllowBelowLimit() async {
        let session = makeSession()
        // 50 000 bytes → 3¢, well below either limit.
        await session.recordMetrics(rawBytes: 50_000, compressedBytes: 0, feature: "test")

        let (mcpDecision, hookDecision) = await BudgetConfig.withTestOverrideAsync(
            BudgetConfig(dailyLimitCents: 1_000, weeklyLimitCents: 5_000)
        ) { () -> (BudgetConfig.Decision, BudgetConfig.Decision) in
            let mcp = await session.checkBudget()
            let hook = HookRouter.checkHookBudgetGate(
                projectRoot: "/tmp/proj",
                costForToday: { 50 },
                costForWeek: { 100 }
            )
            return (mcp, hook)
        }

        #expect(mcpDecision == .allow, "Expected MCP .allow well below all limits, got \(mcpDecision)")
        #expect(hookDecision == .allow, "Expected hook .allow well below all limits, got \(hookDecision)")
    }

    // MARK: - (e) Cross-layer independence

    @Test("Hook gate skips when no daily/weekly limit configured")
    func hookAllowsWhenNoGlobalLimits() async {
        let decision = await BudgetConfig.withTestOverrideAsync(BudgetConfig()) {
            HookRouter.checkHookBudgetGate(
                projectRoot: "/tmp/proj",
                costForToday: { 999_999 },
                costForWeek: { 999_999 }
            )
        }
        #expect(decision == .allow, "Expected .allow when no daily/weekly limits set, got \(decision)")
    }

    @Test("Hook gate skips when projectRoot is nil")
    func hookAllowsWhenProjectRootNil() async {
        // Even with a tight limit + huge cost, nil projectRoot short-circuits
        // the gate (matches the original `if projectRoot != nil` guard in
        // `HookRouter.handle` — hook events without cwd aren't project-scoped).
        let decision = await BudgetConfig.withTestOverrideAsync(
            BudgetConfig(dailyLimitCents: 1)
        ) {
            HookRouter.checkHookBudgetGate(
                projectRoot: nil,
                costForToday: { 999 },
                costForWeek: { 999 }
            )
        }
        #expect(decision == .allow)
    }

    @Test("MCP gate fires even with no hook binary / no hook state")
    func mcpGateIndependentOfHook() async {
        // Exercise the cross-layer-dependency acceptance: ToolRouter's gate
        // must NOT require any hook plumbing. This test calls the MCP gate
        // with (a) a pane cap, (b) a global session limit, and (c) no hook
        // setup whatsoever. Both sub-cases must still block.
        let session = makeSession()
        await session.recordMetrics(rawBytes: 140_000, compressedBytes: 0, feature: "test")

        // Subcase 1: pane-cap only
        await session.updateConfig(budgetSessionCents: 10)
        let paneDecision = await BudgetConfig.withTestOverrideAsync(BudgetConfig()) {
            await session.checkBudget()
        }
        guard case .block = paneDecision else {
            Issue.record("Pane-cap did not fire without hook plumbing, got \(paneDecision)")
            return
        }

        // Subcase 2: global per-session only (no pane-cap — fresh session)
        let session2 = makeSession()
        await session2.recordMetrics(rawBytes: 140_000, compressedBytes: 0, feature: "test")
        let globalDecision = await BudgetConfig.withTestOverrideAsync(
            BudgetConfig(perSessionLimitCents: 10)
        ) {
            await session2.checkBudget()
        }
        guard case .block = globalDecision else {
            Issue.record("Global per-session did not fire without hook plumbing, got \(globalDecision)")
            return
        }
    }
}
