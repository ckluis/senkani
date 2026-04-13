import Testing
import Foundation
@testable import Bench

@Suite("BenchmarkScenarios — Scenario Data")
struct ScenarioSimulatorTests {

    @Test func allScenariosHaveValidData() {
        for scenario in BenchmarkScenarios.all {
            #expect(!scenario.name.isEmpty, "\(scenario.id) has empty name")
            #expect(!scenario.description.isEmpty, "\(scenario.id) has empty description")
            #expect(!scenario.calls.isEmpty, "\(scenario.id) has no calls")
            #expect(scenario.multiplier > 1.0, "\(scenario.id) multiplier \(scenario.multiplier) should be > 1.0")
            #expect(scenario.totalSaved > 0, "\(scenario.id) totalSaved should be > 0")
        }
    }

    @Test func scenarioMultipliersInExpectedRange() {
        for scenario in BenchmarkScenarios.all {
            #expect(scenario.multiplier >= 4.0,
                    "\(scenario.id) multiplier \(scenario.multiplier) is below minimum 4.0x")
            #expect(scenario.multiplier <= 25.0,
                    "\(scenario.id) multiplier \(scenario.multiplier) exceeds maximum 25.0x")
        }
    }

    @Test func scenarioFeatureBreakdownSumsCorrectly() {
        for scenario in BenchmarkScenarios.all {
            let breakdownTotal = scenario.featureBreakdown.reduce(0) { $0 + $1.savedBytes }
            #expect(breakdownTotal == scenario.totalSaved,
                    "\(scenario.id) breakdown sum \(breakdownTotal) != totalSaved \(scenario.totalSaved)")
        }
    }

    @Test func scenarioCallCountMatchesCalls() {
        for scenario in BenchmarkScenarios.all {
            #expect(scenario.callCount == scenario.calls.count,
                    "\(scenario.id) callCount \(scenario.callCount) != calls.count \(scenario.calls.count)")
        }
    }

    @Test func scenarioCostEstimatesPositive() {
        for scenario in BenchmarkScenarios.all {
            #expect(scenario.rawCostCents > 0, "\(scenario.id) rawCostCents should be > 0")
            #expect(scenario.optimizedCostCents >= 0, "\(scenario.id) optimizedCostCents should be >= 0")
            #expect(scenario.optimizedCostCents < scenario.rawCostCents,
                    "\(scenario.id) optimized cost should be less than raw cost")
        }
    }

    @Test func exploreCBHasExpectedCallTypes() {
        let scenario = BenchmarkScenarios.all.first { $0.id == "explore_codebase" }!
        let reads = scenario.calls.filter { $0.tool == "read" }
        let searches = scenario.calls.filter { $0.tool == "search" }
        let outlines = scenario.calls.filter { $0.tool == "outline" }
        let deps = scenario.calls.filter { $0.tool == "deps" }

        #expect(reads.count >= 10, "Explore should have >= 10 read calls, got \(reads.count)")
        #expect(searches.count >= 3, "Explore should have >= 3 search calls, got \(searches.count)")
        #expect(outlines.count >= 1, "Explore should have >= 1 outline call")
        #expect(deps.count >= 1, "Explore should have >= 1 deps call")
    }

    @Test func debugBugHasReReadSuppression() {
        let scenario = BenchmarkScenarios.all.first { $0.id == "debug_bug" }!
        let suppressions = scenario.calls.filter { $0.feature == "reread_suppression" }
        #expect(!suppressions.isEmpty, "Debug a Bug should have at least 1 reread_suppression call")
    }
}
