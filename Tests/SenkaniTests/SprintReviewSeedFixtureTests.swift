import Testing
import Foundation
@testable import Core

// Onboarding-milestone-7 acceptance criterion:
//
//   "The seeded row, when accepted or rejected, fires
//   `SprintReviewViewModel.accept`/`.reject` exactly the same as a real
//   sweep row would — i.e. the existing milestone call site at
//   `Sources/Core/SprintReviewViewModel.swift:242,261` is reached
//   unchanged."
//
// This test seeds via the public production API, then drives
// `SprintReviewViewModel.accept(...)` through the same dispatch the real
// UI calls, and verifies `OnboardingMilestoneStore.isCompleted(
// .firstStagedProposalReviewed)` flips true. If `accept` bypassed the
// existing call site, the milestone would not record and this test
// would fail.

@Suite("SprintReviewSeedFixture", .serialized)
struct SprintReviewSeedFixtureTests {

    @Test func seedThenAcceptFiresMilestone() throws {
        let storeTmp = NSTemporaryDirectory()
            + "senkani-seed-fixture-\(UUID().uuidString).json"
        let home = NSTemporaryDirectory()
            + "senkani-seed-fixture-home-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: storeTmp)
            try? FileManager.default.removeItem(atPath: home)
        }
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)

        try LearnedRulesStore.withPath(storeTmp) {
            try LearnedRulesStore.save(.empty)
            LearnedRulesStore.reload()

            let seededId = try OnboardingMilestoneStore.withTestHome(home) {
                try SprintReviewSeedFixture.seed(home: home)
            }
            #expect(seededId.hasPrefix("seed-fixture-"))

            let afterSeed = LearnedRulesStore.load()!
            #expect(afterSeed.rules.count == 1)
            #expect(afterSeed.rules.first?.id == seededId)
            #expect(afterSeed.rules.first?.status == .staged)

            let dbDir = "/tmp/senkani-seed-fixture-db-\(UUID().uuidString)"
            let db = SessionDatabase(path: dbDir + "/senkani.db")
            defer { TempSessionDatabase.cleanup(projectRoot: dbDir) }
            let root = NSTemporaryDirectory()
                + "senkani-seed-fixture-root-\(UUID().uuidString)"
            try FileManager.default.createDirectory(
                atPath: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: root) }

            try OnboardingMilestoneStore.withTestHome(home) {
                #expect(!OnboardingMilestoneStore.isCompleted(
                    .firstStagedProposalReviewed, home: home))
                try SprintReviewViewModel.accept(
                    rowId: seededId, kind: .filterRule,
                    projectRoot: root, db: db)
                #expect(OnboardingMilestoneStore.isCompleted(
                    .firstStagedProposalReviewed, home: home),
                    "Accept on the seeded row must fire firstStagedProposalReviewed through the unchanged SprintReviewViewModel.accept dispatch.")
            }

            let afterAccept = LearnedRulesStore.load()!
            #expect(afterAccept.rules.first?.status == .applied)
        }
    }

    @Test func seedRefusesWhenMilestoneAlreadyCompletedUnlessForced() throws {
        let storeTmp = NSTemporaryDirectory()
            + "senkani-seed-fixture-guard-\(UUID().uuidString).json"
        let home = NSTemporaryDirectory()
            + "senkani-seed-fixture-guard-home-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: storeTmp)
            try? FileManager.default.removeItem(atPath: home)
        }
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)

        try LearnedRulesStore.withPath(storeTmp) {
            try LearnedRulesStore.save(.empty)
            LearnedRulesStore.reload()

            try OnboardingMilestoneStore.withTestHome(home) {
                _ = OnboardingMilestoneStore.record(
                    .firstStagedProposalReviewed, home: home)
                #expect(OnboardingMilestoneStore.isCompleted(
                    .firstStagedProposalReviewed, home: home))

                #expect(throws: SprintReviewSeedFixture.SeedError.self) {
                    try SprintReviewSeedFixture.seed(home: home, force: false)
                }

                let forcedId = try SprintReviewSeedFixture.seed(
                    home: home, force: true)
                #expect(forcedId.hasPrefix("seed-fixture-"))
            }

            let loaded = LearnedRulesStore.load()!
            #expect(loaded.rules.count == 1)
        }
    }

    @Test func nextSyntheticIDSkipsCollisions() {
        let now = Date(timeIntervalSince1970: 1_715_558_400) // 2024-05-13 UTC
        let existing: Set<String> = [
            "seed-fixture-2024-05-13-001",
            "seed-fixture-2024-05-13-002",
        ]
        let next = SprintReviewSeedFixture.nextSyntheticID(
            now: now, existingIds: existing)
        #expect(next == "seed-fixture-2024-05-13-003")
    }
}
