import Testing
import Foundation
@testable import Core

// MARK: - Suite 1: True Positives

@Suite("EntropyScanner — True Positives")
struct EntropyScannerTruePositiveTests {

    @Test func rawBase64BlobDetected() {
        // Truly random base64 blob — all unique chars → H = log2(36) ≈ 5.17 bits/char.
        // (base64 of English text has H ≈ 4.2 — too low; use genuinely random token)
        let token = "Jq7BpFnKs2RmTwVx4ZdYgLhCeUiOaP9D3ME"
        let input = "export SECRET=\(token)"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.contains("HIGH_ENTROPY"),
            "Raw base64 blob should be detected (H=\(EntropyScanner.shannonEntropy(token)))")
        #expect(!result.redacted.contains(token))
        #expect(result.redacted.contains("[REDACTED:HIGH_ENTROPY]"))
    }

    @Test func randomAlphanumericKeyDetected() {
        // 32-char mixed-case alphanumeric — typical random API key body
        let token = "Xk9mP2qR7vN4wL1sT8eJ5uB3cF6hD0yA"
        let input = "api_token: \"\(token)\""
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.contains("HIGH_ENTROPY"),
            "Random alphanumeric key should be detected (H=\(EntropyScanner.shannonEntropy(token)))")
        #expect(!result.redacted.contains(token))
    }

    @Test func randomHexBlobDetected() {
        // 40-char mixed-case hex (not all same case — entropy above threshold)
        let token = "aB3cD9eF1gH7iJ2kL8mN4oP6qR0sT5uV"
        let input = "WEBHOOK_SECRET=\(token)"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.contains("HIGH_ENTROPY"),
            "Mixed-case random key should be detected (H=\(EntropyScanner.shannonEntropy(token)))")
    }

    @Test func jsonValueDetected() {
        // JSON-style "key": "value" — token extractor splits on : and "
        let token = "Tz8vRq2mNk5pWx1sEy7uBj4cLf9dA3hG"
        let input = "{\"database_password\": \"\(token)\"}"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.contains("HIGH_ENTROPY"),
            "JSON credential value should be detected via token extraction")
        #expect(!result.redacted.contains(token))
    }

    @Test func multipleHighEntropyTokensAllRedacted() {
        let t1 = "Xk9mP2qR7vN4wL1sT8eJ5uB3cF6hD0yA"
        let t2 = "Bq7nWs3tZv1xCd8pYm5rGe2fJk4uAh6L"
        let input = "KEY1=\(t1) KEY2=\(t2)"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.contains("HIGH_ENTROPY"))
        #expect(!result.redacted.contains(t1), "First token should be redacted")
        #expect(!result.redacted.contains(t2), "Second token should be redacted")
    }
}

// MARK: - Suite 2: False Positive Prevention

@Suite("EntropyScanner — False Positive Prevention")
struct EntropyScannerFalsePositiveTests {

    @Test func gitSHANotRedacted() {
        // Exactly 40 hex chars — excluded by exact-length rule before entropy check
        let sha = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
        let input = "commit \(sha) fix: something"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.isEmpty, "Git SHA must not be redacted")
        #expect(result.redacted == input)
    }

    @Test func uuidNotRedacted() {
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        let input = "session_id: \(uuid)"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.isEmpty, "UUID must not be redacted")
        #expect(result.redacted == input)
    }

    @Test func filePathNotRedacted() {
        let input = "/Users/alice/.config/senkani/settings.json contains no secrets"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.isEmpty, "Absolute file path must not be redacted")
        #expect(result.redacted == input)
    }

    @Test func httpURLNotRedacted() {
        // URL token starts with https:// — excluded before entropy check
        let input = "fetching https://api.example.com/v1/resource"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.isEmpty, "HTTPS URL must not be redacted")
        #expect(result.redacted == input)
    }

    @Test func normalTextNotRedacted() {
        let input = "Build succeeded. 47 warnings, 0 errors. Output written to ./build/release"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.isEmpty, "Normal build output must not trigger entropy detection")
        #expect(result.redacted == input)
    }

    @Test func npmIntegrityChecksumNotRedacted() {
        // npm/yarn lockfile integrity field — sha512-<base64blob>
        // Excluded by the sha\d+- prefix rule (Jobs red flag addressed)
        let blob = "ZsBU2S3UBerYflAN+mJrpTM5FExNQDU9GTjyUz8Ri7aJLqDlLFl7gCzIbcmIFVOjr0JCPZkW3sBHHjGKvUaWA=="
        let input = "\"integrity\": \"sha512-\(blob)\""
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.isEmpty, "npm sha512 integrity checksum must not be redacted")
        #expect(result.redacted == input)
    }

    @Test func md5DigestNotRedacted() {
        // Exactly 32 all-hex chars — excluded by exact-32-hex rule
        let md5 = "d41d8cd98f00b204e9800998ecf8427e"
        let input = "checksum: \(md5)"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.isEmpty, "MD5 digest (32 hex) must not be redacted")
        #expect(result.redacted == input)
    }

    @Test func sha512DigestNotRedacted() {
        // Exactly 128 all-hex chars — excluded by exact-128-hex rule (cleanup-18c).
        // Without the exclusion, the long-hex-blob short-circuit would flag it.
        let sha512 = "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
        let input = "sha512 checksum: \(sha512)"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.isEmpty, "SHA-512 digest (128 hex) must not be redacted")
        #expect(result.redacted == input)
    }
}

// MARK: - Suite 3: Entropy Calibration

@Suite("EntropyScanner — Entropy Calibration")
struct EntropyScannerCalibrationTests {

    @Test func gitSHAEntropyBelowThreshold() {
        // 40-char hex — 16 unique chars, roughly uniform → H ≈ 3.9–4.05
        let sha = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
        let h = EntropyScanner.shannonEntropy(sha)
        #expect(h < EntropyScanner.entropyThreshold,
            "Git SHA entropy \(h) should be below threshold \(EntropyScanner.entropyThreshold)")
    }

    @Test func randomKeyEntropyAboveThreshold() {
        // 32-char mixed-case alphanumeric → H ≈ 4.8–5.4
        let token = "Xk9mP2qR7vN4wL1sT8eJ5uB3cF6hD0yA"
        let h = EntropyScanner.shannonEntropy(token)
        #expect(h >= EntropyScanner.entropyThreshold,
            "Random key entropy \(h) should meet threshold \(EntropyScanner.entropyThreshold)")
    }

    @Test func pureHexBlobBelowEntropyButCaughtByLengthBand() {
        // 66-char pure hex — entropy peaks at log2(16) = 4.0, below the 4.5
        // floor. The pure-hex length-band short-circuit (cleanup-18c) catches
        // it without lowering the entropy threshold.
        let token = "6664feedabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123"
        let h = EntropyScanner.shannonEntropy(token)
        #expect(h < EntropyScanner.entropyThreshold,
            "Pure-hex entropy \(h) should sit below threshold \(EntropyScanner.entropyThreshold)")
        #expect(EntropyScanner.isLongHexBlob(token),
            "66-char pure hex should match the long-hex-blob short-circuit")
        let input = "HEX_SECRET=\(token)"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.contains("HIGH_ENTROPY"),
            "Pure-hex blob should be redacted via the length-band short-circuit")
        #expect(!result.redacted.contains(token))
    }

    @Test func pureHexBlobAtKnownDigestLengthsExcluded() {
        // 32, 40, 64, 128 hex are well-known digest sizes (MD5, SHA-1, SHA-256,
        // SHA-512). The long-hex-blob rule must not fire on these — `isExcluded`
        // filters them upstream.
        let md5    = String(repeating: "ab", count: 16)   // 32
        let sha1   = String(repeating: "ab", count: 20)   // 40
        let sha256 = String(repeating: "ab", count: 32)   // 64
        let sha512 = String(repeating: "ab", count: 64)   // 128
        for digest in [md5, sha1, sha256, sha512] {
            let result = EntropyScanner.scan("digest: \(digest)")
            #expect(result.patterns.isEmpty,
                "Hex digest of length \(digest.count) must not be redacted")
        }
    }
}

// MARK: - Suite 4: Real API Key Formats
// Tests that verify the entropy threshold holds for actual credential formats, not just
// synthetic random strings. These catch threshold regressions that synthetic tests miss.

@Suite("EntropyScanner — Real API Key Formats")
struct EntropyScannerRealKeyTests {

    @Test func awsAccessKeyDetected() {
        // AWS access key: AKIA prefix (4 fixed) + 16 random uppercase alphanumeric
        // The full 20-char token has enough variance to exceed the 4.5 bits/char threshold.
        let token = "AKIAIOSFODNN7EXAMPLE"
        let input = "AWS_ACCESS_KEY_ID=\(token)"
        let result = EntropyScanner.scan(input)
        // Either detected by entropy or the token is caught by named SecretDetector upstream.
        // We assert via pipeline to cover both paths.
        let config = FeatureConfig(filter: false, secrets: true, indexer: false, terse: false)
        let pipelineResult = FilterPipeline(config: config).process(command: "env", output: input)
        #expect(pipelineResult.wasFiltered || result.patterns.contains("HIGH_ENTROPY"),
            "AWS AKIA key should be redacted by pipeline (entropy or named pattern)")
    }

    @Test func githubPATRandomSuffixEntropyAboveThreshold() {
        // GitHub fine-grained PAT random tail — 50+ chars, mixed case alphanumeric.
        // Tests that the random suffix alone exceeds the entropy threshold.
        let randomTail = "ghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ123456"
        let h = EntropyScanner.shannonEntropy(randomTail)
        #expect(h >= EntropyScanner.entropyThreshold,
            "GitHub PAT random suffix entropy \(h) must exceed threshold \(EntropyScanner.entropyThreshold)")
    }

    @Test func anthropicKeyDetectedByPipeline() {
        // Anthropic API key: sk-ant-api03- prefix + random base64url body
        let token = "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890abcdefghi"
        let input = "ANTHROPIC_API_KEY=\(token)"
        let config = FeatureConfig(filter: false, secrets: true, indexer: false, terse: false)
        let result = FilterPipeline(config: config).process(command: "env", output: input)
        #expect(result.wasFiltered,
            "Anthropic API key should be redacted (named pattern or entropy detection)")
        #expect(!result.output.contains(token))
    }

    @Test func openAIKeyDetectedByPipeline() {
        // OpenAI project key: sk-proj- prefix + random base64url body
        let token = "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz12345"
        let input = "OPENAI_API_KEY=\(token)"
        let config = FeatureConfig(filter: false, secrets: true, indexer: false, terse: false)
        let result = FilterPipeline(config: config).process(command: "env", output: input)
        #expect(result.wasFiltered,
            "OpenAI API key should be redacted (named pattern or entropy detection)")
        #expect(!result.output.contains(token))
    }

    @Test func shortAPIKeyPrefixAloneDoesNotTrigger() {
        // "AKIA" alone (4 chars) is below the minimum length gate — should not be redacted
        let input = "The AKIA prefix alone is not a key"
        let result = EntropyScanner.scan(input)
        #expect(result.patterns.isEmpty,
            "Short prefix-only token must not trigger entropy detection")
    }
}

// MARK: - Suite 5: Pipeline Integration

@Suite("EntropyScanner — Pipeline Integration")
struct EntropyScannerPipelineIntegrationTests {

    @Test func pipelineAppendsHighEntropyToSecretsFound() {
        let config = FeatureConfig(filter: false, secrets: true, indexer: false, terse: false)
        let pipeline = FilterPipeline(config: config)
        let token = "Xk9mP2qR7vN4wL1sT8eJ5uB3cF6hD0yA"
        let result = pipeline.process(command: "cat .env", output: "SECRET=\(token)")
        #expect(result.secretsFound.contains("HIGH_ENTROPY"),
            "Pipeline secretsFound must include HIGH_ENTROPY")
        #expect(!result.output.contains(token),
            "Pipeline output must not contain the raw token")
        #expect(result.wasFiltered)
    }

    @Test func pipelineSkipsEntropyWhenSecretsDisabled() {
        let config = FeatureConfig(filter: false, secrets: false, indexer: false, terse: false)
        let pipeline = FilterPipeline(config: config)
        let token = "Xk9mP2qR7vN4wL1sT8eJ5uB3cF6hD0yA"
        let result = pipeline.process(command: "cat .env", output: "SECRET=\(token)")
        #expect(result.secretsFound.isEmpty,
            "EntropyScanner must not run when .secrets is disabled")
        #expect(result.output.contains(token),
            "Token must pass through unchanged when secrets is off")
    }
}
