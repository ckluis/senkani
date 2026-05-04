import Testing
import Foundation
@testable import Core

/// Drift detector. `ModelPricing.swift` keeps named static-let constants
/// (e.g. `.claudeOpus4`) for back-compat with call sites that reference
/// a specific model by name; ``CostLedger.entries`` is the source of
/// truth. These tests assert byte-for-byte equality between the two so
/// any future drift fails CI before reaching production cost displays.
@Suite("ModelPricing ↔ CostLedger byte-for-byte parity")
struct ModelPricingLedgerParityTests {

    @Test func eachStaticConstantMatchesItsLedgerEntry() {
        let pairs: [(ModelPricing, String)] = [
            (.claudeOpus4, "claude-opus-4"),
            (.claudeSonnet4, "claude-sonnet-4"),
            (.claudeHaiku35, "claude-haiku-3.5"),
            (.gpt4o, "gpt-4o"),
            (.gpt4oMini, "gpt-4o-mini"),
            (.o3, "o3"),
            (.gemini25Pro, "gemini-2.5-pro"),
            (.gemini25Flash, "gemini-2.5-flash"),
        ]
        for (constant, modelId) in pairs {
            guard let entry = CostLedger.rate(model: modelId) else {
                Issue.record("missing ledger entry for \(modelId)")
                continue
            }
            #expect(constant.modelId == entry.modelId)
            #expect(constant.displayName == entry.displayName)
            #expect(constant.inputPerMillion == entry.inputPerMillion)
            #expect(constant.outputPerMillion == entry.outputPerMillion)
            #expect(constant.cachedInputPerMillion == entry.cachedInputPerMillion)
        }
    }

    @Test func allModelsIsDerivedFromCurrentLedgerVersion() {
        let derived = ModelPricing.allModels.map(\.modelId).sorted()
        let expected = CostLedger.entries(forVersion: CostLedger.currentVersion)
            .map(\.modelId).sorted()
        #expect(derived == expected)
    }

    @Test func findDelegatesToLedger() {
        // Substring match path: ledger has "claude-haiku-3.5"; full
        // model id includes a date suffix. Both paths must resolve to
        // the same entry.
        let viaPricing = ModelPricing.find("claude-haiku-3.5-20241022")
        let viaLedger = CostLedger.rate(model: "claude-haiku-3.5-20241022")
        #expect(viaPricing.modelId == viaLedger?.modelId)
        #expect(viaPricing.inputPerMillion == viaLedger?.inputPerMillion)
    }

    @Test func findFallsBackToSonnetForUnknownModels() {
        let unknown = ModelPricing.find("definitely-not-a-real-model-xyz")
        #expect(unknown.modelId == ModelPricing.claudeSonnet4.modelId)
    }

    @Test func ledgerHasDisplayNameForEveryEntry() {
        for entry in CostLedger.entries {
            #expect(!entry.displayName.isEmpty,
                    "ledger entry \(entry.modelId) is missing displayName")
        }
    }
}
