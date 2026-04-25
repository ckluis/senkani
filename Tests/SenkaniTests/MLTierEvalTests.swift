import Testing
import Foundation
@testable import Bench

@Suite("MLTierEval")
struct MLTierEvalTests {

    // MARK: - Fixture sanity

    @Test func testTwentyTasksTotal() {
        let all = MLTierEvalTasks.all()
        #expect(all.count == 20)
    }

    @Test func testTenRationaleTenVision() {
        let rationale = MLTierEvalTasks.rationaleTasks()
        let vision = MLTierEvalTasks.visionTasks()
        #expect(rationale.count == 10)
        #expect(vision.count == 10)
        #expect(rationale.allSatisfy { $0.category == .rationale })
        #expect(vision.allSatisfy { $0.category == .vision })
    }

    @Test func testTaskIdsAreUnique() {
        let all = MLTierEvalTasks.all()
        let ids = Set(all.map(\.id))
        #expect(ids.count == all.count)
    }

    @Test func testEveryRationaleTaskHasExpectedKeywords() {
        for t in MLTierEvalTasks.rationaleTasks() {
            #expect(!t.expectedAnyOf.isEmpty, "task \(t.id) has no expected keywords")
            #expect(t.imageRef == nil, "rationale task \(t.id) should not have an imageRef")
        }
    }

    @Test func testEveryVisionTaskReferencesAnImage() {
        for t in MLTierEvalTasks.visionTasks() {
            #expect(t.imageRef != nil, "vision task \(t.id) is missing imageRef")
            #expect(!t.expectedAnyOf.isEmpty, "vision task \(t.id) has no expected keywords")
        }
    }

    @Test func testEveryVisionTaskImageRefResolvesToARealFile() {
        for t in MLTierEvalTasks.visionTasks() {
            guard let url = t.imageURL else {
                Issue.record("vision task \(t.id) imageRef \(t.imageRef ?? "nil") did not resolve via Bundle.module")
                continue
            }
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "vision task \(t.id) resolved to \(url.path) but file is missing"
            )
        }
    }

    @Test func testRationaleTaskImageURLIsNil() {
        for t in MLTierEvalTasks.rationaleTasks() {
            #expect(t.imageURL == nil, "rationale task \(t.id) unexpectedly resolved an imageURL")
        }
    }

    // MARK: - passes(response:)

    @Test func testTaskPassesOnSubstringMatch() {
        let task = MLTierEvalTask(
            id: "x", category: .rationale, prompt: "p",
            expectedAnyOf: ["foo", "bar"]
        )
        #expect(task.passes(response: "the FOO is here") == true)   // case-insensitive
        #expect(task.passes(response: "no match here") == false)
        #expect(task.passes(response: "") == false)
    }

    @Test func testEmptyExpectedDoesNotMatchEverything() {
        // Defensive: an empty/blank string in expectedAnyOf must not silently
        // pass every response.
        let task = MLTierEvalTask(
            id: "x", category: .rationale, prompt: "p",
            expectedAnyOf: [""]
        )
        #expect(task.passes(response: "anything") == false)
    }

    // MARK: - Rating thresholds

    @Test func testRatingThresholds() {
        #expect(MLTierQualityRating.rate(passRate: 1.0) == .excellent)
        #expect(MLTierQualityRating.rate(passRate: 0.80) == .excellent)
        #expect(MLTierQualityRating.rate(passRate: 0.79) == .acceptable)
        #expect(MLTierQualityRating.rate(passRate: 0.60) == .acceptable)
        #expect(MLTierQualityRating.rate(passRate: 0.59) == .degraded)
        #expect(MLTierQualityRating.rate(passRate: 0.0) == .degraded)
    }

    // MARK: - Runner

    @Test func testRunnerCountsPassesAndComputesMedian() async {
        // Synthetic runner: returns "foo" for tasks whose id contains "1",
        // "miss" otherwise. Latency = 10ms, 20ms, 30ms, ...
        let tasks: [MLTierEvalTask] = (1...5).map { i in
            MLTierEvalTask(id: "task_\(i)", category: .rationale,
                           prompt: "p", expectedAnyOf: ["foo"])
        }

        var step = 0
        let base = Date(timeIntervalSince1970: 0)
        let clock: () -> Date = {
            defer { step += 1 }
            // Each task: start=10*step, end=10*step+10
            return base.addingTimeInterval(Double(step) * 0.010)
        }

        let result = await MLTierEvalRunner.evaluate(
            tier: (id: "test", name: "test"),
            tasks: tasks,
            clock: clock
        ) { task in
            // Pass tasks whose id ends in 1 or 3 (2/5 = 40%)
            let last = task.id.last.map { String($0) } ?? ""
            return (response: (last == "1" || last == "3") ? "foo" : "miss",
                    outputTokens: 7)
        }

        #expect(result.passed == 2)
        #expect(result.total == 5)
        #expect(result.totalOutputTokens == 35)
        #expect(result.rating == .degraded)  // 40% < 60%
        #expect(abs(result.medianLatencyMs - 10.0) < 0.01)
    }

    @Test func testNotEvaluatedHelper() {
        let r = MLTierEvalRunner.notEvaluated(
            tier: (id: "gemma4-26b-apex", name: "Gemma 4 26B"),
            reason: "insufficient RAM (8 GB; tier requires 16 GB)"
        )
        #expect(r.rating == .notEvaluated)
        #expect(r.passed == 0)
        #expect(r.total == 0)
        #expect(r.skipReason?.contains("16 GB") == true)
    }

    // MARK: - Persistence

    @Test func testReportRoundTrip() throws {
        let tmp = URL(fileURLWithPath: "/tmp/senkani-mleval-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let report = MLTierEvalReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            machineRamGB: 16,
            tiers: [
                MLTierEvalResult(
                    tierId: "gemma4-e4b",
                    tierName: "Gemma 4 E4B",
                    rating: .acceptable,
                    passed: 14,
                    total: 20,
                    medianLatencyMs: 220,
                    totalOutputTokens: 1_400,
                    evaluatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
            ]
        )

        try MLTierEvalReportStore.save(report, to: tmp)
        let loaded = MLTierEvalReportStore.load(from: tmp)
        #expect(loaded != nil)
        #expect(loaded?.machineRamGB == 16)
        #expect(loaded?.tiers.count == 1)
        let first = loaded!.tiers[0]
        #expect(first.tierId == "gemma4-e4b")
        #expect(first.rating == .acceptable)
        #expect(first.passed == 14)
        #expect(first.passRate == 0.7)
    }

    @Test func testReportLookupByTier() {
        let report = MLTierEvalReport(
            generatedAt: Date(),
            machineRamGB: 8,
            tiers: [
                MLTierEvalRunner.notEvaluated(
                    tier: (id: "gemma4-26b-apex", name: "26B"),
                    reason: "insufficient RAM"
                ),
                MLTierEvalResult(
                    tierId: "gemma4-e4b",
                    tierName: "E4B",
                    rating: .excellent,
                    passed: 17, total: 20,
                    medianLatencyMs: 200, totalOutputTokens: 1_200,
                    evaluatedAt: Date()
                ),
            ]
        )

        #expect(report.result(for: "gemma4-e4b")?.rating == .excellent)
        #expect(report.result(for: "gemma4-26b-apex")?.rating == .notEvaluated)
        #expect(report.result(for: "missing-tier") == nil)
    }

    @Test func testLoadMissingReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/senkani-mleval-missing-\(UUID().uuidString).json")
        #expect(MLTierEvalReportStore.load(from: url) == nil)
    }
}
