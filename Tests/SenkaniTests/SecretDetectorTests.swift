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

    // MARK: - F5 (Schneier re-audit) — expanded secret families

    @Test func openaiProjectKeyRedacted() {
        // sk-proj-... is NOT caught by the generic OPENAI_API_KEY pattern
        // (`-` breaks its [a-zA-Z0-9]{20,} character class). Dedicated pattern.
        let input = "OPENAI_PROJECT=sk-proj-abcdef0123456789abcdef0123456789"
        let result = SecretDetector.scan(input)
        #expect(result.patterns.contains("OPENAI_PROJECT_KEY"),
                "sk-proj-... must match OPENAI_PROJECT_KEY, got \(result.patterns)")
        #expect(!result.redacted.contains("sk-proj-abcdef"),
                "raw key must not leak through")
    }

    @Test func slackBotTokenRedacted() {
        // GitHub push-protection pattern-matches complete Slack tokens in
        // source text even when they're test fixtures. Build via concat at
        // runtime so the literal never appears in the commit.
        let prefix = "xox" + "b-"
        let body   = "1234567890-0987654321-abcdefghijklmnopqrstuvwx"
        let input = "SLACK=\(prefix)\(body)"
        let result = SecretDetector.scan(input)
        #expect(result.patterns.contains("SLACK_TOKEN"))
        #expect(!result.redacted.contains(body))
    }

    @Test func slackUserTokenRedacted() {
        let prefix = "xox" + "p-"
        let body   = "ABC123DEF456GHI789JKL012"
        let input = "token: \(prefix)\(body)"
        let result = SecretDetector.scan(input)
        #expect(result.patterns.contains("SLACK_TOKEN"))
    }

    @Test func gcpOAuthTokenRedacted() {
        // Google OAuth access tokens are 60+ char base64url-like after ya29.
        let tail = String(repeating: "a0AfH6SMBx", count: 7) + "xyz"
        let input = "Authorization: Bearer ya29.\(tail)"
        let result = SecretDetector.scan(input)
        #expect(result.patterns.contains("GCP_OAUTH_TOKEN"),
                "ya29.<60+ chars> must match, got \(result.patterns)")
    }

    @Test func stripeLiveKeyRedacted() {
        // Split to dodge GitHub's push-protection Stripe scanner. Our regex
        // matches the concatenated result, GitHub scans the literal source.
        let prefix = "sk" + "_live_"
        let body   = "abcdef0123456789abcdef0123"
        let input = "STRIPE=\(prefix)\(body)"
        let result = SecretDetector.scan(input)
        #expect(result.patterns.contains("STRIPE_SECRET_KEY"))
        #expect(!result.redacted.contains(body))
    }

    @Test func stripeTestKeyRedacted() {
        // Test keys are lower-severity but still secret.
        let prefix = "sk" + "_test_"
        let body   = "abcdef0123456789abcdef0123"
        let input = "STRIPE=\(prefix)\(body)"
        let result = SecretDetector.scan(input)
        #expect(result.patterns.contains("STRIPE_SECRET_KEY"))
    }

    @Test func npmTokenRedacted() {
        let input = "//registry.npmjs.org/:_authToken=npm_" + String(repeating: "A", count: 36)
        let result = SecretDetector.scan(input)
        #expect(result.patterns.contains("NPM_TOKEN"))
    }

    @Test func huggingFaceTokenRedacted() {
        let input = "HF_TOKEN=hf_" + String(repeating: "a", count: 30)
        let result = SecretDetector.scan(input)
        #expect(result.patterns.contains("HUGGINGFACE_TOKEN"))
    }

    // MARK: - FP guards for new patterns

    @Test func benignTextWithShortPrefixesNotFlagged() {
        // Short fragments that START with the prefixes but don't meet the
        // minimum-length threshold should not match.
        let input = "hf_x npm_y ya29.z xoxp-short sk_live_z"  // all too short
        let result = SecretDetector.scan(input)
        #expect(result.patterns.isEmpty,
                "short sub-threshold fragments must not match, got \(result.patterns)")
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
