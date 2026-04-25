import Testing
import Foundation
@testable import Core

// MARK: - WorkflowPlaybookStore tests

private let fixedDate = Date(timeIntervalSince1970: 1_713_360_000)

private func makePlaybook(
    id: String = UUID().uuidString,
    title: String = "outline-then-fetch",
    description: String = "# outline → fetch\n\nThe common pair.",
    steps: [LearnedWorkflowStep] = [
        LearnedWorkflowStep(toolName: "outline", example: "."),
        LearnedWorkflowStep(toolName: "fetch", example: "."),
    ],
    sources: [String] = ["s-1"],
    status: LearnedRuleStatus = .recurring
) -> LearnedWorkflowPlaybook {
    LearnedWorkflowPlaybook(
        id: id, title: title, description: description, steps: steps,
        sources: sources, confidence: 0.9, status: status,
        createdAt: fixedDate
    )
}

@Suite("WorkflowPlaybookStore lifecycle", .serialized)
struct WorkflowPlaybookStoreTests {

    private func withTempStore(_ body: () throws -> Void) rethrows {
        let temp = NSTemporaryDirectory() + "senkani-wps-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp, body)
    }

    @Test func observeAppendsNewPlaybookAsRecurring() throws {
        try withTempStore {
            try LearnedRulesStore.observeWorkflowPlaybook(makePlaybook(id: "w-1"))
            let pls = LearnedRulesStore.load()!.workflowPlaybooks
            #expect(pls.count == 1)
            #expect(pls[0].status == .recurring)
        }
    }

    @Test func observeMergesByTitleAndRefreshesSteps() throws {
        try withTempStore {
            try LearnedRulesStore.observeWorkflowPlaybook(makePlaybook(id: "w-1", sources: ["s-1"]))
            let updated = makePlaybook(
                id: "w-2",
                description: "# refined description",
                steps: [
                    LearnedWorkflowStep(toolName: "outline", example: "v2"),
                    LearnedWorkflowStep(toolName: "fetch", example: "v2"),
                    LearnedWorkflowStep(toolName: "summarize", example: "v2"),
                ],
                sources: ["s-2"]
            )
            try LearnedRulesStore.observeWorkflowPlaybook(updated)
            let pls = LearnedRulesStore.load()!.workflowPlaybooks
            #expect(pls.count == 1, "same title → merged")
            #expect(pls[0].recurrenceCount == 2)
            #expect(pls[0].steps.count == 3, "refined steps replace prior")
            #expect(pls[0].sources.contains("s-2"))
        }
    }

    @Test func observeRespectsRejectedStickiness() throws {
        try withTempStore {
            try LearnedRulesStore.observeWorkflowPlaybook(makePlaybook(id: "w-1"))
            let id = LearnedRulesStore.load()!.workflowPlaybooks[0].id
            try LearnedRulesStore.rejectWorkflowPlaybook(id: id)
            try LearnedRulesStore.observeWorkflowPlaybook(makePlaybook(id: "w-2"))
            let pls = LearnedRulesStore.load()!.workflowPlaybooks
            #expect(pls.count == 1)
            #expect(pls[0].status == .rejected)
            #expect(pls[0].recurrenceCount == 1)
        }
    }

    @Test func promoteAndApplyTransitions() throws {
        try withTempStore {
            try LearnedRulesStore.observeWorkflowPlaybook(makePlaybook(id: "w-1"))
            let id = LearnedRulesStore.load()!.workflowPlaybooks[0].id
            try LearnedRulesStore.promoteWorkflowPlaybookToStaged(id: id)
            #expect(LearnedRulesStore.load()!.workflowPlaybooks[0].status == .staged)
            try LearnedRulesStore.applyWorkflowPlaybook(id: id)
            #expect(LearnedRulesStore.load()!.workflowPlaybooks[0].status == .applied)
            // applyWorkflowPlaybook on already-applied is a no-op (idempotent).
            try LearnedRulesStore.applyWorkflowPlaybook(id: id)
            #expect(LearnedRulesStore.load()!.workflowPlaybooks[0].status == .applied)
        }
    }

    @Test func workflowPlaybooksInStatusFiltersAndSortsDesc() throws {
        try withTempStore {
            let older = makePlaybook(id: "old", title: "alpha", status: .applied)
            let newerDate = fixedDate.addingTimeInterval(3600)
            let newer = LearnedWorkflowPlaybook(
                id: "new", title: "beta", description: "n",
                steps: [LearnedWorkflowStep(toolName: "n", example: ".")],
                sources: ["s"], confidence: 0.9, status: .applied,
                createdAt: newerDate
            )
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5,
                artifacts: [.workflowPlaybook(older), .workflowPlaybook(newer)]))
            LearnedRulesStore.reload()
            let applied = LearnedRulesStore.workflowPlaybooks(inStatus: .applied)
            #expect(applied.map(\.id) == ["new", "old"])
        }
    }
}
