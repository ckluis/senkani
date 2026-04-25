import Testing
import Foundation
@testable import Core

// MARK: - InstructionPatchStore tests

private let fixedDate = Date(timeIntervalSince1970: 1_713_360_000)

private func makePatch(
    id: String = UUID().uuidString,
    tool: String = "exec",
    hint: String = "specify path",
    sources: [String] = ["s-1"],
    status: LearnedRuleStatus = .recurring
) -> LearnedInstructionPatch {
    LearnedInstructionPatch(
        id: id, toolName: tool, hint: hint, sources: sources,
        confidence: 0.85, status: status, createdAt: fixedDate
    )
}

@Suite("InstructionPatchStore lifecycle", .serialized)
struct InstructionPatchStoreTests {

    private func withTempStore(_ body: () throws -> Void) rethrows {
        let temp = NSTemporaryDirectory() + "senkani-ips-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp, body)
    }

    @Test func observeAppendsNewPatchAsRecurring() throws {
        try withTempStore {
            try LearnedRulesStore.observeInstructionPatch(makePatch(id: "p-1"))
            let patches = LearnedRulesStore.load()!.instructionPatches
            #expect(patches.count == 1)
            #expect(patches[0].status == .recurring)
        }
    }

    @Test func observeMergesByToolAndHint() throws {
        try withTempStore {
            try LearnedRulesStore.observeInstructionPatch(makePatch(id: "p-1", sources: ["s-1"]))
            try LearnedRulesStore.observeInstructionPatch(makePatch(id: "p-2", sources: ["s-2"]))
            let patches = LearnedRulesStore.load()!.instructionPatches
            #expect(patches.count == 1)
            #expect(patches[0].recurrenceCount == 2)
            #expect(patches[0].sources.contains("s-2"))
        }
    }

    @Test func observeDoesNotMergeAcrossTools() throws {
        try withTempStore {
            try LearnedRulesStore.observeInstructionPatch(makePatch(id: "p-1", tool: "exec"))
            try LearnedRulesStore.observeInstructionPatch(makePatch(id: "p-2", tool: "kb_search"))
            let patches = LearnedRulesStore.load()!.instructionPatches
            #expect(patches.count == 2, "different toolName → distinct artifacts")
        }
    }

    @Test func applyOnlyMovesStagedToApplied() throws {
        try withTempStore {
            try LearnedRulesStore.observeInstructionPatch(makePatch(id: "p-1"))
            let id = LearnedRulesStore.load()!.instructionPatches[0].id
            // Apply on .recurring is a no-op (Schneier: no auto-apply).
            try LearnedRulesStore.applyInstructionPatch(id: id)
            #expect(LearnedRulesStore.load()!.instructionPatches[0].status == .recurring)
            try LearnedRulesStore.promoteInstructionPatchToStaged(id: id)
            try LearnedRulesStore.applyInstructionPatch(id: id)
            #expect(LearnedRulesStore.load()!.instructionPatches[0].status == .applied)
        }
    }

    @Test func appliedInstructionPatchesIsAliasForAppliedStatus() throws {
        try withTempStore {
            let r = makePatch(id: "r", hint: "be specific", status: .recurring)
            let a = makePatch(id: "a", hint: "use --json", status: .applied)
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5,
                artifacts: [.instructionPatch(r), .instructionPatch(a)]))
            LearnedRulesStore.reload()
            #expect(LearnedRulesStore.appliedInstructionPatches().map(\.id) == ["a"])
        }
    }

    @Test func rejectIsTerminalAndBlocksFurtherObservation() throws {
        try withTempStore {
            try LearnedRulesStore.observeInstructionPatch(makePatch(id: "p-1"))
            let id = LearnedRulesStore.load()!.instructionPatches[0].id
            try LearnedRulesStore.rejectInstructionPatch(id: id)
            try LearnedRulesStore.observeInstructionPatch(makePatch(id: "p-2"))
            let patches = LearnedRulesStore.load()!.instructionPatches
            #expect(patches.count == 1)
            #expect(patches[0].status == .rejected)
            #expect(patches[0].recurrenceCount == 1)
        }
    }
}
