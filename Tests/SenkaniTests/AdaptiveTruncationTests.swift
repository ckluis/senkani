import Testing
import Foundation
@testable import Core

@Suite("Adaptive Truncation")
struct AdaptiveTruncationTests {

    @Test func above50PercentGives1MB() {
        let bytes = AdaptiveTruncation.maxBytes(forBudgetRemaining: 0.6)
        #expect(bytes == 1_048_576, "Above 50% should give 1MB, got \(bytes)")
    }

    @Test func between25And50Gives512KB() {
        let bytes = AdaptiveTruncation.maxBytes(forBudgetRemaining: 0.35)
        #expect(bytes == 524_288, "25-50% should give 512KB, got \(bytes)")
    }

    @Test func between10And25Gives256KB() {
        let bytes = AdaptiveTruncation.maxBytes(forBudgetRemaining: 0.15)
        #expect(bytes == 262_144, "10-25% should give 256KB, got \(bytes)")
    }

    @Test func below10Gives64KB() {
        let bytes = AdaptiveTruncation.maxBytes(forBudgetRemaining: 0.05)
        #expect(bytes == 65_536, "Below 10% should give 64KB minimum, got \(bytes)")
    }

    @Test func sandboxThresholdScales() {
        #expect(AdaptiveTruncation.sandboxThreshold(forBudgetRemaining: 0.8) == 20)
        #expect(AdaptiveTruncation.sandboxThreshold(forBudgetRemaining: 0.35) == 10)
        #expect(AdaptiveTruncation.sandboxThreshold(forBudgetRemaining: 0.05) == 5)
    }

    @Test func unlimitedBudgetGivesMaximum() {
        let bytes = AdaptiveTruncation.maxBytes(forBudgetRemaining: 1.0)
        #expect(bytes == 1_048_576, "Unlimited should give 1MB")
    }
}
