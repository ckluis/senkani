import Testing
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
}
