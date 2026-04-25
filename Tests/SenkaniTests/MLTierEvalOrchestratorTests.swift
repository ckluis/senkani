import Testing
import Foundation
@testable import Core
@testable import MCPServer

@Suite("MLTierEvalOrchestrator")
struct MLTierEvalOrchestratorTests {

    // MARK: - plan(...) — pure function

    @Test func planSkipsTiersAboveAvailableRAM() {
        let info16 = ModelInfo(
            id: "gemma4-26b-apex",
            name: "Gemma 4 26B MoE (APEX Mini)",
            repoId: "mudler/gemma-4-26B",
            expectedSizeBytes: 12_200_000_000,
            requiredRAM: 16,
            status: .verified
        )
        let plans = MLTierEvalOrchestrator.plan(
            tierIds: ["gemma4-26b-apex"],
            availableRAMGB: 8,
            infoFor: { id in id == info16.id ? info16 : nil }
        )
        guard case .skip(let id, let name, let reason) = plans.first else {
            Issue.record("expected .skip, got \(String(describing: plans.first))")
            return
        }
        #expect(id == "gemma4-26b-apex")
        #expect(name == "Gemma 4 26B MoE (APEX Mini)")
        #expect(reason.contains("insufficient RAM"))
        #expect(reason.contains("8 GB"))
        #expect(reason.contains("16 GB"))
    }

    @Test func planEvaluatesInstalledTiersThatFit() {
        let info = ModelInfo(
            id: "gemma4-e4b",
            name: "Gemma 4 E4B (Q4)",
            repoId: "unsloth/gemma-4-E4B-it-UD-MLX-4bit",
            expectedSizeBytes: 2_500_000_000,
            requiredRAM: 8,
            status: .verified
        )
        let plans = MLTierEvalOrchestrator.plan(
            tierIds: ["gemma4-e4b"],
            availableRAMGB: 16,
            infoFor: { id in id == info.id ? info : nil }
        )
        guard case .evaluate(let id, let name, let repoId) = plans.first else {
            Issue.record("expected .evaluate, got \(String(describing: plans.first))")
            return
        }
        #expect(id == "gemma4-e4b")
        #expect(name == "Gemma 4 E4B (Q4)")
        #expect(repoId == "unsloth/gemma-4-E4B-it-UD-MLX-4bit")
    }

    @Test func planSkipsNotInstalledTiers() {
        // .available means registered but not yet downloaded — must not
        // try to load. The reason names the actual status so the user
        // knows what to fix.
        let info = ModelInfo(
            id: "gemma4-e2b",
            name: "Gemma 4 E2B (Q4)",
            repoId: "unsloth/gemma-4-E2B-it-GGUF",
            expectedSizeBytes: 1_500_000_000,
            requiredRAM: 4,
            status: .available
        )
        let plans = MLTierEvalOrchestrator.plan(
            tierIds: ["gemma4-e2b"],
            availableRAMGB: 16,
            infoFor: { id in id == info.id ? info : nil }
        )
        guard case .skip(_, _, let reason) = plans.first else {
            Issue.record("expected .skip, got \(String(describing: plans.first))")
            return
        }
        #expect(reason.contains("not installed"))
        #expect(reason.contains("available"))
        #expect(reason.contains("Models pane"))
    }

    @Test func planTreatsDownloadedAsInstalled() {
        // Downloaded but not yet verified should still be eval-eligible.
        // Verification is integrity, not quality — quality is what we're
        // about to measure.
        let info = ModelInfo(
            id: "gemma4-e4b",
            name: "Gemma 4 E4B (Q4)",
            repoId: "unsloth/gemma-4-E4B-it-UD-MLX-4bit",
            expectedSizeBytes: 2_500_000_000,
            requiredRAM: 8,
            status: .downloaded
        )
        let plans = MLTierEvalOrchestrator.plan(
            tierIds: ["gemma4-e4b"],
            availableRAMGB: 16,
            infoFor: { id in id == info.id ? info : nil }
        )
        guard case .evaluate = plans.first else {
            Issue.record("expected .evaluate for .downloaded, got \(String(describing: plans.first))")
            return
        }
    }

    @Test func planRejectsUnknownTierIds() {
        let plans = MLTierEvalOrchestrator.plan(
            tierIds: ["never-registered-id"],
            availableRAMGB: 64,
            infoFor: { _ in nil }
        )
        guard case .skip(let id, _, let reason) = plans.first else {
            Issue.record("expected .skip, got \(String(describing: plans.first))")
            return
        }
        #expect(id == "never-registered-id")
        #expect(reason.contains("not in registry"))
    }

    @Test func planSkipsBrokenAndErrorTiers() {
        // Non-installable statuses (.broken, .error, .downloading,
        // .verifying) must NOT be evaluated. This pins the explicit
        // allowlist behavior so a future ModelStatus case doesn't
        // accidentally become eval-eligible.
        let cases: [ModelStatus] = [.broken, .error, .downloading, .verifying]
        for status in cases {
            let info = ModelInfo(
                id: "test", name: "Test", repoId: "x/y",
                expectedSizeBytes: 1, requiredRAM: 1, status: status
            )
            let plans = MLTierEvalOrchestrator.plan(
                tierIds: ["test"],
                availableRAMGB: 16,
                infoFor: { _ in info }
            )
            guard case .skip(_, _, let reason) = plans.first else {
                Issue.record("expected .skip for status \(status), got \(String(describing: plans.first))")
                continue
            }
            #expect(reason.contains(status.rawValue),
                    "skip reason for \(status) should name the status")
        }
    }
}
