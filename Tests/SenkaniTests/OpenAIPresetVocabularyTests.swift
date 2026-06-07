import Testing
import Foundation
@testable import Core
@testable import CLI

/// `process-gap-v13a-3-preset-vocabulary-…` (2026-05-27) — the
/// `senkani vault add openai-key --preset` flag has ONE vocabulary: the
/// `ModelPreset` raw values (`auto`/`build`/`research`/`quick`/`local`).
/// Provider names (`openai`/`anthropic`) are rejected at provision time
/// rather than silently degrading to `.auto` at serve time. The lenient
/// serve-time `.auto` fallback survives as a safety net for genuinely
/// out-of-vocabulary stored strings (legacy records, hand-edited vault
/// files), so a stale record never crashes the listener.
@Suite("OpenAI vault --preset vocabulary (process-gap v13a-3)")
struct OpenAIPresetVocabularyTests {

    private static func request(model: String = "gpt-4o", prompt: String = "hi") -> ChatCompletionRequest {
        ChatCompletionRequest(model: model, messages: [.init(role: "user", content: prompt)])
    }

    // MARK: - 1. valid ModelPreset value provisions + routes to its tier

    @Test("a valid ModelPreset --preset provisions and routes to its tier (not .auto)")
    func validPresetRoutesToTier() throws {
        let normalized = try OpenAIKeyProvisioner.validatePreset("quick")
        #expect(normalized == "quick")

        let provisioned = OpenAIKeyProvisioner.provision(
            preset: normalized, scope: ["chat"], rateLimit: 60,
            expiresAt: nil, label: "ci", now: Date()
        )
        // The stored record carries the normalized preset, and routing
        // resolves the operator-chosen tier — NOT the difficulty-scored
        // `.auto` fallback.
        #expect(provisioned.record.preset == "quick")
        let routing = OpenAIChatHandler.route(request: Self.request(), recordPreset: provisioned.record.preset)
        #expect(routing.presetUsed == .quick)
        #expect(routing.resolvedTier == .quick)

        // A Research key routes to the frontier tier, proving the preset —
        // not the request model — drives the decision.
        let research = try OpenAIKeyProvisioner.validatePreset("research")
        let researchRouting = OpenAIChatHandler.route(request: Self.request(), recordPreset: research)
        #expect(researchRouting.presetUsed == .research)
        #expect(researchRouting.resolvedTier == .frontier)
    }

    // MARK: - case-insensitive normalization

    @Test("--preset is normalized to lowercase before storage")
    func presetNormalizedLowercase() throws {
        #expect(try OpenAIKeyProvisioner.validatePreset("QUICK") == "quick")
        #expect(try OpenAIKeyProvisioner.validatePreset("Research") == "research")
        #expect(try OpenAIKeyProvisioner.validatePreset("AUTO") == "auto")
    }

    // MARK: - 2. provider name (and other junk) rejected with the valid-cases list

    @Test("a non-ModelPreset --preset is rejected with the valid-cases list")
    func providerNameRejected() {
        for bad in ["openai", "anthropic", "", "gpt-4o", "balanced"] {
            #expect(throws: OpenAIKeyProvisioner.InvalidPreset.self) {
                _ = try OpenAIKeyProvisioner.validatePreset(bad)
            }
        }

        // The error echoes the rejected value AND names every valid case.
        do {
            _ = try OpenAIKeyProvisioner.validatePreset("openai")
            Issue.record("expected InvalidPreset to throw for 'openai'")
        } catch let err as OpenAIKeyProvisioner.InvalidPreset {
            #expect(err.provided == "openai")
            let msg = err.description
            #expect(msg.contains("openai"))
            for preset in ModelPreset.allCases {
                #expect(msg.contains(preset.rawValue))
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - 3. .auto fallback preserved for genuinely-unknown stored presets

    @Test("the serve-time .auto fallback survives for out-of-vocabulary stored presets")
    func autoFallbackPreserved() {
        // Simulates a legacy record provisioned before validation landed, or
        // a hand-edited vault file. The serve-time handler must NOT crash and
        // must degrade to `.auto` — the safety net the validation does not
        // remove.
        #expect(OpenAIChatHandler.preset(forRecordPreset: "openai") == .auto)
        #expect(OpenAIChatHandler.preset(forRecordPreset: "anthropic") == .auto)
        #expect(OpenAIChatHandler.preset(forRecordPreset: "totally-bogus") == .auto)

        let routing = OpenAIChatHandler.route(request: Self.request(), recordPreset: "openai")
        #expect(routing.presetUsed == .auto)
    }

    // MARK: - 4. --help text matches the chosen vocabulary

    @Test("--preset help lists the ModelPreset vocabulary, not provider names")
    func helpTextMatchesVocabulary() {
        let help = VaultAdd.helpMessage()
        // Every valid case appears in the rendered help.
        for preset in ModelPreset.allCases {
            #expect(help.contains(preset.rawValue))
        }
        // The old provider-name phrasing is gone.
        #expect(!help.contains("e.g. openai, anthropic"))
        #expect(!help.lowercased().contains("anthropic"))
    }
}
