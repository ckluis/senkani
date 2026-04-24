import Testing
@testable import Core
import Foundation

@Suite("PresetSecretDetector — blocks inline-secret installs")
struct PresetSecretDetectorTests {

    @Test("Clean command produces a .clear verdict")
    func cleanCommandClears() {
        let verdict = PresetSecretDetector.scan(
            resolvedCommand: "senkani brief --for today --out /tmp/brief.md"
        )
        #expect(verdict == .clear)
    }

    @Test("Anthropic API key in the command surfaces a .block verdict")
    func anthropicKeyBlocks() {
        let key = "sk-ant-abcdefghijklmnop1234567890"
        let verdict = PresetSecretDetector.scan(
            resolvedCommand: "curl -H \"x-api-key: \(key)\" https://api.anthropic.com/v1/messages"
        )
        guard case .block(let patterns) = verdict else {
            Issue.record("Expected .block verdict but got \(verdict)")
            return
        }
        #expect(patterns.contains("ANTHROPIC_API_KEY"))
    }

    @Test("GitHub token in the command surfaces a .block verdict")
    func githubTokenBlocks() {
        let token = "ghp_abcdefghijklmnopqrstuvwxyz1234567890"
        let verdict = PresetSecretDetector.scan(
            resolvedCommand: "curl -H \"Authorization: token \(token)\""
        )
        guard case .block(let patterns) = verdict else {
            Issue.record("Expected .block verdict but got \(verdict)")
            return
        }
        #expect(patterns.contains("GITHUB_TOKEN"))
    }

    @Test("Env-indirection placeholders remain clear")
    func envIndirectionClears() {
        let verdict = PresetSecretDetector.scan(
            resolvedCommand: "curl -H \"Authorization: Bearer ${SENKANI_TOKEN}\""
        )
        #expect(verdict == .clear)
    }
}
