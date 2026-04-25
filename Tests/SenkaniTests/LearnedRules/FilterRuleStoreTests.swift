import Testing
import Foundation
@testable import Core
@testable import Filter

// MARK: - FilterRuleStore tests
//
// Per-artifact tests for the filter-rule lifecycle extension shipped
// under `luminary-2026-04-24-6-learnedrulesstore-split`. The
// CompoundLearningH1 / H2a / H2b suites cover the higher-level
// generator → store integration; this file exercises the store API
// directly so a pure-store regression surfaces without an indirection.

private let fixedDate = Date(timeIntervalSince1970: 1_713_360_000)

private func makeRule(
    id: String = UUID().uuidString,
    command: String = "git",
    sub: String? = "log",
    ops: [String] = ["head(50)"],
    source: String = "s-1",
    status: LearnedRuleStatus = .recurring
) -> LearnedFilterRule {
    LearnedFilterRule(
        id: id, command: command, subcommand: sub, ops: ops,
        source: source, confidence: 0.9, status: status,
        sessionCount: 1, createdAt: fixedDate
    )
}

@Suite("FilterRuleStore lifecycle", .serialized)
struct FilterRuleStoreTests {

    private func withTempStore(_ body: () throws -> Void) rethrows {
        let temp = NSTemporaryDirectory() + "senkani-frs-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp, body)
    }

    @Test func observeAppendsNewRuleAsRecurring() throws {
        try withTempStore {
            try LearnedRulesStore.observe(makeRule(id: "r-1"))
            let file = LearnedRulesStore.load()!
            #expect(file.rules.count == 1)
            #expect(file.rules[0].status == .recurring)
            #expect(file.rules[0].recurrenceCount == 1)
        }
    }

    @Test func observeMergesByCommandSubcommandOps() throws {
        try withTempStore {
            try LearnedRulesStore.observe(makeRule(id: "r-1", source: "s-1"))
            try LearnedRulesStore.observe(makeRule(id: "r-2", source: "s-2"))
            let file = LearnedRulesStore.load()!
            // Same (command, subcommand, ops) → one rule, recurrence bumped.
            #expect(file.rules.count == 1)
            #expect(file.rules[0].recurrenceCount == 2)
            #expect(file.rules[0].sources.contains("s-2"))
        }
    }

    @Test func observeRespectsRejectedStickiness() throws {
        try withTempStore {
            try LearnedRulesStore.observe(makeRule(id: "r-1"))
            // Find the persisted rule so we hit the same id on reject.
            let persistedId = LearnedRulesStore.load()!.rules[0].id
            try LearnedRulesStore.reject(id: persistedId)
            // Re-observe identical rule shape — should be a no-op now.
            try LearnedRulesStore.observe(makeRule(id: "r-2", source: "s-2"))
            let file = LearnedRulesStore.load()!
            #expect(file.rules.count == 1)
            #expect(file.rules[0].status == .rejected)
            #expect(file.rules[0].recurrenceCount == 1, "rejected rule must NOT bump on re-observe")
        }
    }

    @Test func promoteToStagedRequiresRecurringStatus() throws {
        try withTempStore {
            try LearnedRulesStore.observe(makeRule(id: "r-1"))
            let id = LearnedRulesStore.load()!.rules[0].id
            try LearnedRulesStore.promoteToStaged(id: id)
            #expect(LearnedRulesStore.load()!.rules[0].status == .staged)
            // Already staged → no-op (does not silently re-stage or revert).
            try LearnedRulesStore.promoteToStaged(id: id)
            #expect(LearnedRulesStore.load()!.rules[0].status == .staged)
        }
    }

    @Test func applyMovesStagedToApplied() throws {
        try withTempStore {
            try LearnedRulesStore.observe(makeRule(id: "r-1"))
            let id = LearnedRulesStore.load()!.rules[0].id
            try LearnedRulesStore.promoteToStaged(id: id)
            try LearnedRulesStore.apply(id: id)
            #expect(LearnedRulesStore.load()!.rules[0].status == .applied)
        }
    }

    @Test func applyAllPromotesAllStagedRules() throws {
        try withTempStore {
            // Insert two distinct rules, both staged.
            let a = makeRule(id: "a", command: "git", status: .staged)
            let b = makeRule(id: "b", command: "docker", status: .staged)
            try LearnedRulesStore.save(LearnedRulesFile(version: 5, rules: [a, b]))
            LearnedRulesStore.reload()
            try LearnedRulesStore.applyAll()
            let after = LearnedRulesStore.load()!
            #expect(after.rules.allSatisfy { $0.status == .applied })
        }
    }

    @Test func setEnrichedRationaleWritesAndIsNoOpForUnknownId() throws {
        try withTempStore {
            try LearnedRulesStore.observe(makeRule(id: "r-1"))
            let id = LearnedRulesStore.load()!.rules[0].id
            try LearnedRulesStore.setEnrichedRationale(id: id, text: "Strip noisy INFO lines.")
            #expect(LearnedRulesStore.load()!.rules[0].enrichedRationale == "Strip noisy INFO lines.")
            // Unknown id is a tolerated no-op — the daily sweep races
            // with operator-driven deletes and must not crash.
            try LearnedRulesStore.setEnrichedRationale(id: "does-not-exist", text: "x")
            #expect(LearnedRulesStore.load()!.rules[0].enrichedRationale == "Strip noisy INFO lines.")
        }
    }

    @Test func loadAppliedAndLoadRecurringFilterByStatus() throws {
        try withTempStore {
            let r = makeRule(id: "r", command: "ls", status: .recurring)
            let s = makeRule(id: "s", command: "cat", status: .staged)
            let a = makeRule(id: "a", command: "rm", status: .applied)
            try LearnedRulesStore.save(LearnedRulesFile(version: 5, rules: [r, s, a]))
            LearnedRulesStore.reload()
            #expect(LearnedRulesStore.loadApplied().map(\.command) == ["rm"])
            #expect(LearnedRulesStore.loadRecurring().map(\.command) == ["ls"])
        }
    }
}
