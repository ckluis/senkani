import Testing
import Foundation
@testable import Core

// Wiring tests for the onboarding-p2-milestone-callsites round.
//
// Each of the seven `OnboardingMilestoneStore.record(.X)` callsites
// gets a focused test that verifies the line is in place. Core-side
// callsites (SessionDatabase.recordTokenEvent, BudgetConfig.loadFromDisk,
// SprintReviewViewModel.accept/reject) get behavioural tests that
// drive the production path under `withTestHome` and assert the
// milestone landed on disk. SwiftUI-side callsites (WorkspaceModel +
// LaunchCoordinator) get source-level guards — SenkaniTests can't link
// SenkaniApp, matching the pattern in `LaunchCoordinatorRoutingTests`.

private let repoRoot: String = {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
        let pkg = url.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: pkg.path) {
            return url.path
        }
    }
    return FileManager.default.currentDirectoryPath
}()

private func read(_ rel: String) -> String {
    let path = (repoRoot as NSString).appendingPathComponent(rel)
    return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

private func makeTempHome() -> String {
    let home = NSTemporaryDirectory()
        + "senkani-onb-cs-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
        atPath: home, withIntermediateDirectories: true)
    return home
}

private func cleanupHome(_ home: String) {
    try? FileManager.default.removeItem(atPath: home)
}

private func makeTempDB() -> (SessionDatabase, String) {
    let path = NSTemporaryDirectory()
        + "senkani-onb-cs-db-\(UUID().uuidString)/senkani.db"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: dir)
}

@Suite("Onboarding P2 — milestone callsite wiring", .serialized)
struct OnboardingMilestoneCallsiteTests {

    // 1. WorkspaceModel.addProject — source-level guard.
    @Test("WorkspaceModel.addProject records .projectSelected")
    func addProjectRecordsProjectSelected() {
        let src = read("SenkaniApp/Models/WorkspaceModel.swift")
        #expect(!src.isEmpty,
                "SenkaniApp/Models/WorkspaceModel.swift must exist.")
        #expect(src.contains("func addProject(path:"),
                "WorkspaceModel must expose addProject(path:).")
        #expect(src.contains(
            "OnboardingMilestoneStore.record(.projectSelected)"),
            "addProject must record .projectSelected on success.")
    }

    // 2. LaunchCoordinator.launchPane — source-level guard.
    @Test("LaunchCoordinator.launchPane records .agentLaunched")
    func launchPaneRecordsAgentLaunched() {
        let src = read("SenkaniApp/Services/LaunchCoordinator.swift")
        #expect(!src.isEmpty,
                "SenkaniApp/Services/LaunchCoordinator.swift must exist.")
        #expect(src.contains("func launchPane("),
                "LaunchCoordinator must expose launchPane(...).")
        #expect(src.contains(
            "OnboardingMilestoneStore.record(.agentLaunched)"),
            "launchPane must record .agentLaunched on success.")
    }

    // 3. SessionDatabase.recordTokenEvent — fires .firstTrackedEvent.
    @Test("SessionDatabase.recordTokenEvent records .firstTrackedEvent")
    func recordTokenEventFiresFirstTrackedEvent() {
        let home = makeTempHome()
        defer { cleanupHome(home) }
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(path: dbPath) }

        OnboardingMilestoneStore.withTestHome(home) {
            #expect(!OnboardingMilestoneStore.isCompleted(
                .firstTrackedEvent, home: home))
            let sid = db.createSession(
                projectRoot: "/tmp/test-project",
                agentType: .claudeCode)
            db.recordTokenEvent(
                sessionId: sid, paneId: nil,
                projectRoot: "/tmp/test-project",
                source: "mcp_tool", toolName: "read", model: nil,
                inputTokens: 100, outputTokens: 10,
                savedTokens: 0, costCents: 5,
                feature: "filter", command: nil, modelTier: nil)
            #expect(OnboardingMilestoneStore.isCompleted(
                .firstTrackedEvent, home: home),
                "recordTokenEvent must fire .firstTrackedEvent.")
        }
    }

    // 4. SessionDatabase.recordTokenEvent — fires .firstNonzeroSavings
    //    iff savedTokens > 0.
    @Test("recordTokenEvent fires .firstNonzeroSavings only when savedTokens > 0")
    func recordTokenEventGatesFirstNonzeroSavings() {
        let home = makeTempHome()
        defer { cleanupHome(home) }
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(path: dbPath) }

        OnboardingMilestoneStore.withTestHome(home) {
            let sid = db.createSession(
                projectRoot: "/tmp/test-project",
                agentType: .claudeCode)
            // savedTokens == 0 must NOT fire firstNonzeroSavings.
            db.recordTokenEvent(
                sessionId: sid, paneId: nil,
                projectRoot: "/tmp/test-project",
                source: "mcp_tool", toolName: "read", model: nil,
                inputTokens: 100, outputTokens: 10,
                savedTokens: 0, costCents: 5,
                feature: "filter", command: nil, modelTier: nil)
            #expect(!OnboardingMilestoneStore.isCompleted(
                .firstNonzeroSavings, home: home),
                "savedTokens == 0 must not fire .firstNonzeroSavings.")
            // savedTokens > 0 must fire it.
            db.recordTokenEvent(
                sessionId: sid, paneId: nil,
                projectRoot: "/tmp/test-project",
                source: "mcp_tool", toolName: "read", model: nil,
                inputTokens: 100, outputTokens: 10,
                savedTokens: 50, costCents: 5,
                feature: "filter", command: nil, modelTier: nil)
            #expect(OnboardingMilestoneStore.isCompleted(
                .firstNonzeroSavings, home: home),
                "savedTokens > 0 must fire .firstNonzeroSavings.")
        }
    }

    // 5. BudgetConfig.loadFromDisk — fires .firstBudgetSet for a
    //    non-default config; not for an empty/default file.
    @Test("BudgetConfig.loadFromDisk records .firstBudgetSet when non-default")
    func loadFromDiskFiresFirstBudgetSet() throws {
        let home = makeTempHome()
        defer { cleanupHome(home) }

        // Default file (every limit nil) must NOT fire. The synthesised
        // Codable requires every field to be present — softLimitPercent
        // doesn't have an `Optional<Double>` type, so we always supply
        // it even when no budget limits are set.
        let defaultPath = home + "/budget-default.json"
        try Data(#"{"softLimitPercent":0.8}"#.utf8)
            .write(to: URL(fileURLWithPath: defaultPath))
        OnboardingMilestoneStore.withTestHome(home) {
            let cfg = BudgetConfig.loadFromDisk(path: defaultPath)
            #expect(!cfg.isNonDefault,
                "Limits-nil config must not be flagged non-default.")
            #expect(!OnboardingMilestoneStore.isCompleted(
                .firstBudgetSet, home: home),
                "Default-only budget must not fire .firstBudgetSet.")
        }

        // Non-default file must fire.
        let nonDefaultPath = home + "/budget-nondefault.json"
        try Data(#"{"dailyLimitCents":1000,"softLimitPercent":0.8}"#.utf8)
            .write(to: URL(fileURLWithPath: nonDefaultPath))
        OnboardingMilestoneStore.withTestHome(home) {
            let cfg = BudgetConfig.loadFromDisk(path: nonDefaultPath)
            #expect(cfg.isNonDefault, "Decoded config must be non-default.")
            #expect(OnboardingMilestoneStore.isCompleted(
                .firstBudgetSet, home: home),
                "Non-default budget must fire .firstBudgetSet.")
        }
    }

    // 6. WorkspaceModel.addWorkstream — source-level guard.
    @Test("WorkspaceModel.addWorkstream records .firstWorkstreamCreated")
    func addWorkstreamRecordsFirstWorkstreamCreated() {
        let src = read("SenkaniApp/Models/WorkspaceModel.swift")
        #expect(!src.isEmpty,
                "SenkaniApp/Models/WorkspaceModel.swift must exist.")
        #expect(src.contains("func addWorkstream("),
                "WorkspaceModel must expose addWorkstream(...).")
        #expect(src.contains(
            "OnboardingMilestoneStore.record(.firstWorkstreamCreated)"),
            "addWorkstream must record .firstWorkstreamCreated on success.")
    }

    // 7. SprintReviewViewModel.accept and .reject — fire
    //    .firstStagedProposalReviewed.
    @Test("SprintReviewViewModel.accept/reject record .firstStagedProposalReviewed")
    func acceptOrRejectRecordsFirstStagedProposalReviewed() throws {
        let home = makeTempHome()
        defer { cleanupHome(home) }

        // accept path
        let storePathAccept = NSTemporaryDirectory()
            + "senkani-onb-cs-rules-accept-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: storePathAccept) }
        try LearnedRulesStore.withPath(storePathAccept) {
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5,
                artifacts: [.filterRule(LearnedFilterRule(
                    id: "acc", command: "cmd", subcommand: "sub",
                    ops: ["head(50)"], source: "signal",
                    confidence: 0.82, status: .staged,
                    sessionCount: 3, createdAt: Date(),
                    rationale: "r", recurrenceCount: 5,
                    lastSeenAt: Date()))]))
            LearnedRulesStore.reload()
            let (db, dbPath) = makeTempDB()
            defer { cleanupDB(path: dbPath) }
            let projectRoot = NSTemporaryDirectory()
                + "senkani-onb-cs-acc-root-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(
                atPath: projectRoot,
                withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: projectRoot) }

            try OnboardingMilestoneStore.withTestHome(home) {
                #expect(!OnboardingMilestoneStore.isCompleted(
                    .firstStagedProposalReviewed, home: home))
                try SprintReviewViewModel.accept(
                    rowId: "acc", kind: .filterRule,
                    projectRoot: projectRoot, db: db)
                #expect(OnboardingMilestoneStore.isCompleted(
                    .firstStagedProposalReviewed, home: home),
                    "accept must fire .firstStagedProposalReviewed.")
            }
        }

        // reject path — fresh home so the milestone has to fire from
        // the reject branch on its own.
        let home2 = makeTempHome()
        defer { cleanupHome(home2) }
        let storePathReject = NSTemporaryDirectory()
            + "senkani-onb-cs-rules-reject-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: storePathReject) }
        try LearnedRulesStore.withPath(storePathReject) {
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5,
                artifacts: [.filterRule(LearnedFilterRule(
                    id: "rej", command: "cmd", subcommand: "sub",
                    ops: ["head(50)"], source: "signal",
                    confidence: 0.82, status: .staged,
                    sessionCount: 3, createdAt: Date(),
                    rationale: "r", recurrenceCount: 5,
                    lastSeenAt: Date()))]))
            LearnedRulesStore.reload()

            try OnboardingMilestoneStore.withTestHome(home2) {
                #expect(!OnboardingMilestoneStore.isCompleted(
                    .firstStagedProposalReviewed, home: home2))
                try SprintReviewViewModel.reject(
                    rowId: "rej", kind: .filterRule)
                #expect(OnboardingMilestoneStore.isCompleted(
                    .firstStagedProposalReviewed, home: home2),
                    "reject must fire .firstStagedProposalReviewed.")
            }
        }
    }
}
