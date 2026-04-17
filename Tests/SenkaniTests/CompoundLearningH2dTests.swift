import Testing
import Foundation
@testable import Core

private let now = Date(timeIntervalSince1970: 1_713_360_000) // 2024-04-17

private func withTempStore(_ body: () throws -> Void) rethrows {
    let temp = NSTemporaryDirectory() + "senkani-h2d-\(UUID().uuidString).json"
    defer { try? FileManager.default.removeItem(atPath: temp) }
    try LearnedRulesStore.withPath(temp, body)
}

private func rule(id: String, status: LearnedRuleStatus, lastSeen: Date) -> LearnedFilterRule {
    LearnedFilterRule(
        id: id, command: "cmd-\(id)", subcommand: nil,
        ops: ["head(50)"], source: "s", confidence: 0.9,
        status: status, sessionCount: 3, createdAt: now,
        lastSeenAt: lastSeen
    )
}

private func ctxDoc(id: String, status: LearnedRuleStatus, lastSeen: Date) -> LearnedContextDoc {
    LearnedContextDoc(
        id: id, title: "t-\(id)", body: "x", sources: [],
        confidence: 0.9, status: status, createdAt: now,
        lastSeenAt: lastSeen
    )
}

@Suite("CompoundLearningReview — sprint review (H+2d)", .serialized)
struct SprintReviewTests {

    @Test func emptyWhenNoStaged() throws {
        try withTempStore {
            try LearnedRulesStore.save(.empty)
            let set = CompoundLearningReview.sprintReviewSet(windowDays: 7, now: now)
            #expect(set.isEmpty)
            #expect(set.totalCount == 0)
        }
    }

    @Test func filtersByWindow() throws {
        try withTempStore {
            let recent = rule(id: "recent", status: .staged,
                              lastSeen: now.addingTimeInterval(-3 * 86400))
            let old = rule(id: "old", status: .staged,
                           lastSeen: now.addingTimeInterval(-30 * 86400))
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.filterRule(recent), .filterRule(old)]))
            LearnedRulesStore.reload()

            let set = CompoundLearningReview.sprintReviewSet(windowDays: 7, now: now)
            #expect(set.filterRules.map(\.id) == ["recent"])
        }
    }

    @Test func excludesNonStagedArtifacts() throws {
        try withTempStore {
            let applied = rule(id: "a", status: .applied, lastSeen: now)
            let recurring = rule(id: "r", status: .recurring, lastSeen: now)
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.filterRule(applied), .filterRule(recurring)]))
            LearnedRulesStore.reload()
            let set = CompoundLearningReview.sprintReviewSet(windowDays: 7, now: now)
            #expect(set.filterRules.isEmpty,
                "only .staged artifacts land in sprint review")
        }
    }

    @Test func includesAllArtifactTypes() throws {
        try withTempStore {
            let f = rule(id: "f", status: .staged, lastSeen: now)
            let c = ctxDoc(id: "c", status: .staged, lastSeen: now)
            let i = LearnedInstructionPatch(
                id: "i", toolName: "exec", hint: "hint",
                sources: [], confidence: 0.9,
                status: .staged, createdAt: now, lastSeenAt: now)
            let w = LearnedWorkflowPlaybook(
                id: "w", title: "flow", description: "x", steps: [],
                sources: [], confidence: 0.9,
                status: .staged, createdAt: now, lastSeenAt: now)
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [
                    .filterRule(f), .contextDoc(c),
                    .instructionPatch(i), .workflowPlaybook(w)
                ]))
            LearnedRulesStore.reload()

            let set = CompoundLearningReview.sprintReviewSet(windowDays: 7, now: now)
            #expect(set.totalCount == 4)
            #expect(set.filterRules.count == 1)
            #expect(set.contextDocs.count == 1)
            #expect(set.instructionPatches.count == 1)
            #expect(set.workflowPlaybooks.count == 1)
        }
    }
}

@Suite("CompoundLearningReview — quarterly audit (H+2d)", .serialized)
struct QuarterlyAuditTests {

    @Test func noFlagsWhenEverythingFresh() throws {
        try withTempStore {
            let fresh = rule(id: "fresh", status: .applied, lastSeen: now)
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.filterRule(fresh)]))
            LearnedRulesStore.reload()
            let flags = CompoundLearningReview.quarterlyAuditFlags(
                appliedIdleDays: 60, now: now)
            #expect(flags.isEmpty)
        }
    }

    @Test func flagsIdleFilterRule() throws {
        try withTempStore {
            let stale = rule(id: "stale", status: .applied,
                             lastSeen: now.addingTimeInterval(-90 * 86400))
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.filterRule(stale)]))
            LearnedRulesStore.reload()
            let flags = CompoundLearningReview.quarterlyAuditFlags(
                appliedIdleDays: 60, now: now)
            #expect(flags.count == 1)
            #expect(flags[0].reason == .filterRuleNotFired)
            #expect(flags[0].idleDays >= 60)
        }
    }

    @Test func flagsInstructionPatchForMissingTool() throws {
        try withTempStore {
            let patch = LearnedInstructionPatch(
                id: "ip", toolName: "removed_tool", hint: "x",
                sources: [], confidence: 0.9,
                status: .applied, createdAt: now, lastSeenAt: now)
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.instructionPatch(patch)]))
            LearnedRulesStore.reload()

            let liveTools: Set<String> = ["read", "search"]
            let flags = CompoundLearningReview.quarterlyAuditFlags(
                appliedIdleDays: 60, liveToolNames: liveTools, now: now)
            #expect(flags.contains { $0.reason == .instructionPatchToolMissing })
        }
    }

    @Test func flagsStaleWorkflowPlaybook() throws {
        try withTempStore {
            let w = LearnedWorkflowPlaybook(
                id: "wp", title: "abandoned", description: "x", steps: [],
                sources: [], confidence: 0.9,
                status: .applied, createdAt: now,
                lastSeenAt: now.addingTimeInterval(-90 * 86400))
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.workflowPlaybook(w)]))
            LearnedRulesStore.reload()
            let flags = CompoundLearningReview.quarterlyAuditFlags(
                appliedIdleDays: 60, now: now)
            #expect(flags.contains { $0.reason == .workflowPlaybookNotObserved })
        }
    }

    @Test func skipsNonAppliedArtifacts() throws {
        try withTempStore {
            let staged = rule(id: "s", status: .staged,
                              lastSeen: now.addingTimeInterval(-100 * 86400))
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.filterRule(staged)]))
            LearnedRulesStore.reload()
            let flags = CompoundLearningReview.quarterlyAuditFlags(
                appliedIdleDays: 60, now: now)
            #expect(flags.isEmpty,
                "audit only flags .applied artifacts — staged is review territory")
        }
    }
}
