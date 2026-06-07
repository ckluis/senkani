import Testing
import Foundation
@testable import Core

// Decoder resilience for `BudgetConfig` loaded from `~/.senkani/budget.json`.
//
// Auto-synthesized `Codable` on a struct treats every non-Optional stored
// property as a required JSON key, ignoring Swift-side default values. A
// `budget.json` that sets `perSessionLimitCents` but omits `softLimitPercent`
// would otherwise fail `keyNotFound`, fall through to `loadFromEnv()`, and
// never fire `OnboardingMilestoneStore.record(.firstBudgetSet)`. The explicit
// `init(from:)` uses `decodeIfPresent ?? default` for every non-Optional
// property; partial-schema files now decode cleanly with property defaults.
//
// Origin: onboarding-milestone-5-budget-decoder-partial-schema-2026-05-13.
struct BudgetConfigPartialSchemaTests {

    @Test("Partial-schema JSON (no softLimitPercent) decodes with default 0.8")
    func partialSchemaDecodesWithDefault() throws {
        let json = #"{"perSessionLimitCents":500}"#
        let data = Data(json.utf8)
        let cfg = try JSONDecoder().decode(BudgetConfig.self, from: data)

        #expect(cfg.perSessionLimitCents == 500)
        #expect(cfg.dailyLimitCents == nil)
        #expect(cfg.weeklyLimitCents == nil)
        #expect(cfg.softLimitPercent == 0.8,
                "Missing softLimitPercent must fall back to the 0.8 default.")
    }

    @Test("Partial-schema decode preserves isNonDefault so firstBudgetSet would fire")
    func partialSchemaIsNonDefault() throws {
        let json = #"{"perSessionLimitCents":500}"#
        let data = Data(json.utf8)
        let cfg = try JSONDecoder().decode(BudgetConfig.self, from: data)

        #expect(cfg.isNonDefault,
                "A budget.json that sets a real limit must read as non-default.")
    }

    @Test("Empty-object JSON decodes to all-default config (not isNonDefault)")
    func emptyObjectDecodesToDefaults() throws {
        let data = Data("{}".utf8)
        let cfg = try JSONDecoder().decode(BudgetConfig.self, from: data)

        #expect(cfg.perSessionLimitCents == nil)
        #expect(cfg.dailyLimitCents == nil)
        #expect(cfg.weeklyLimitCents == nil)
        #expect(cfg.softLimitPercent == 0.8)
        #expect(!cfg.isNonDefault)
    }

    @Test("Encode then decode round-trips a non-default config")
    func roundTripPreservesValues() throws {
        let original = BudgetConfig(
            perSessionLimitCents: 250,
            dailyLimitCents: 1000,
            weeklyLimitCents: 5000,
            softLimitPercent: 0.75)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BudgetConfig.self, from: data)

        #expect(decoded.perSessionLimitCents == 250)
        #expect(decoded.dailyLimitCents == 1000)
        #expect(decoded.weeklyLimitCents == 5000)
        #expect(decoded.softLimitPercent == 0.75)
    }

    @Test("Encoder omits nil limits but always emits softLimitPercent")
    func encoderOmitsNilLimits() throws {
        let cfg = BudgetConfig(perSessionLimitCents: 500)
        let data = try JSONEncoder().encode(cfg)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(obj?["perSessionLimitCents"] as? Int == 500)
        #expect(obj?["dailyLimitCents"] == nil,
                "nil dailyLimitCents must be omitted from JSON.")
        #expect(obj?["weeklyLimitCents"] == nil)
        #expect(obj?["softLimitPercent"] as? Double == 0.8)
    }

    @Test("loadFromDisk fires firstBudgetSet for partial-schema budget.json")
    func loadFromDiskFiresMilestoneOnPartialSchema() throws {
        let home = NSTemporaryDirectory()
            + "senkani-budget-partial-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let path = home + "/budget.json"
        try Data(#"{"perSessionLimitCents":500}"#.utf8)
            .write(to: URL(fileURLWithPath: path))

        OnboardingMilestoneStore.withTestHome(home) {
            let cfg = BudgetConfig.loadFromDisk(path: path)
            #expect(cfg.perSessionLimitCents == 500,
                    "Partial-schema file must decode, not fall back to env.")
            #expect(cfg.softLimitPercent == 0.8,
                    "Missing softLimitPercent must default to 0.8 on disk-load path.")
            #expect(cfg.isNonDefault)
            #expect(OnboardingMilestoneStore.isCompleted(
                .firstBudgetSet, home: home),
                "A partial-schema budget.json with a real limit must fire .firstBudgetSet.")
        }
    }
}
