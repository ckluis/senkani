import Testing
import Foundation
@testable import Core

@Suite("SecretDetector") struct SecretDetectorTests {
    @Test func anthropicKey() {
        let input = "export ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
        let result = SecretDetector.scan(input)
        #expect(!result.patterns.isEmpty)
        #expect(result.redacted.contains("[REDACTED:"))
        #expect(!result.redacted.contains("sk-ant-"))
    }

    @Test func openaiKey() {
        let input = "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz1234"
        let result = SecretDetector.scan(input)
        #expect(!result.patterns.isEmpty)
        #expect(!result.redacted.contains("sk-proj-"))
    }

    @Test func awsKeyId() {
        let input = "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"
        let result = SecretDetector.scan(input)
        #expect(result.patterns.contains("AWS_ACCESS_KEY_ID"))
    }

    @Test func githubToken() {
        let input = "token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn"
        let result = SecretDetector.scan(input)
        #expect(result.patterns.contains("GITHUB_TOKEN"))
    }

    @Test func cleanText() {
        let input = "Hello world. git status. npm install."
        let result = SecretDetector.scan(input)
        #expect(result.patterns.isEmpty)
        #expect(result.redacted == input)
    }

    @Test func emptyString() {
        let result = SecretDetector.scan("")
        #expect(result.patterns.isEmpty)
        #expect(result.redacted == "")
    }

    @Test func bearerToken() {
        let input = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abcdef"
        let result = SecretDetector.scan(input)
        #expect(result.patterns.contains("BEARER_TOKEN"))
    }

    @Test func genericApiKey() {
        let input = "api_key = 'super_secret_key_1234567890abcdef'"
        let result = SecretDetector.scan(input)
        #expect(!result.patterns.isEmpty)
    }

    /// Ensure ANTHROPIC patterns matches before OPENAI — keys of the form sk-ant-...
    /// must not be tagged as OPENAI_API_KEY. (Pattern order is load-bearing since OPENAI's
    /// regex `sk-[a-zA-Z0-9]{20,}` would otherwise match sk-ant-... too.)
    @Test func anthropicPatternMatchesBeforeOpenAI() {
        let input = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
        let result = SecretDetector.scan(input)
        #expect(result.patterns.first == "ANTHROPIC_API_KEY",
                "ANTHROPIC must be tagged first (ordering dependency), got \(result.patterns)")
    }

    /// No-match hot path: 1 MB input with no secrets should complete quickly.
    /// Prior to the firstMatch short-circuit, each pattern allocated a full
    /// [NSTextCheckingResult] array regardless of whether any match existed.
    @Test func noSecretsIn1MBInputIsFast() {
        let chunk = "Hello world. The quick brown fox. git status. npm install. "
        var input = ""
        input.reserveCapacity(1_048_576)
        while input.utf8.count < 1_048_576 { input += chunk }

        let start = Date()
        let result = SecretDetector.scan(input)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.patterns.isEmpty, "Benign input must not trigger detections")
        // Generous bound for CI variance; pre-fix baseline was much slower.
        #expect(elapsed < 1.0, "No-match 1 MB scan should complete in <1s, took \(elapsed)s")
    }
}
