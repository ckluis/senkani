import Testing
import Foundation
@testable import MCPServer
@testable import Core

@Suite("Per-Pane Budget Hard Caps")
struct BudgetPerPaneTests {

    // MARK: - Helpers

    /// Build a minimal MCPSession for budget tests (no index, no cache, no sessionId).
    private func makeSession() -> MCPSession {
        MCPSession(
            projectRoot: "/tmp/senkani-budget-test",
            filterEnabled: false,
            secretsEnabled: false,
            indexerEnabled: false,
            cacheEnabled: false
        )
    }

    // MARK: - Suite: Budget decision logic

    @Test func paneBudgetBlocksAtHardLimit() {
        let session = makeSession()
        // Set 10-cent pane cap
        session.updateConfig(budgetSessionCents: 10)
        // 140 000 bytes → costSavedCents(140_000) = 10¢ (Claude Sonnet 4 @ $3/M input)
        session.recordMetrics(rawBytes: 140_000, compressedBytes: 0, feature: "test")
        let decision = session.checkBudget()
        guard case .block = decision else {
            Issue.record("Expected .block at hard limit, got \(decision)")
            return
        }
    }

    @Test func paneBudgetWarnsAtSoftLimit() {
        let session = makeSession()
        // 10-cent cap; soft limit = 80% = 8¢
        session.updateConfig(budgetSessionCents: 10)
        // 120 000 bytes → 9¢ — above 8¢ soft limit, below 10¢ hard limit
        session.recordMetrics(rawBytes: 120_000, compressedBytes: 0, feature: "test")
        let decision = session.checkBudget()
        guard case .warn = decision else {
            Issue.record("Expected .warn at soft limit, got \(decision)")
            return
        }
    }

    @Test func paneBudgetAllowsBelowSoftLimit() {
        let session = makeSession()
        session.updateConfig(budgetSessionCents: 10)
        // 50 000 bytes → 3¢ — below 8¢ soft limit
        session.recordMetrics(rawBytes: 50_000, compressedBytes: 0, feature: "test")
        let decision = session.checkBudget()
        #expect(decision == .allow, "Expected .allow below soft limit")
    }

    @Test func paneBudgetNotSetAllows() {
        let session = makeSession()
        // No pane limit set; heavy usage should still allow (no global budget.json in CI)
        session.recordMetrics(rawBytes: 1_000_000, compressedBytes: 0, feature: "test")
        let decision = session.checkBudget()
        #expect(decision == .allow, "Expected .allow when no pane budget is configured")
    }

    // MARK: - Suite: Runtime configuration

    @Test func updateConfigSetsBudgetLimit() {
        let session = makeSession()
        session.updateConfig(budgetSessionCents: 500)
        #expect(session.paneBudgetSessionLimitCents == 500)
    }

    @Test func refreshConfigReadsBudgetKey() throws {
        // Write a temp config file with SENKANI_PANE_BUDGET_SESSION
        let configPath = "/tmp/senkani-budget-cfg-\(UUID().uuidString).env"
        defer { try? FileManager.default.removeItem(atPath: configPath) }
        try "SENKANI_PANE_BUDGET_SESSION=1000\n".write(toFile: configPath, atomically: true, encoding: .utf8)

        let session = MCPSession(
            projectRoot: "/tmp/senkani-budget-test",
            filterEnabled: false,
            secretsEnabled: false,
            indexerEnabled: false,
            cacheEnabled: false,
            configFilePath: configPath
        )
        session.refreshConfig()
        #expect(session.paneBudgetSessionLimitCents == 1000)
    }
}
