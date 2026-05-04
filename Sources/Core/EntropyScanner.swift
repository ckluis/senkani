import Foundation

/// Detects unnamed high-entropy secrets (raw base64/hex blobs, random API keys)
/// by computing Shannon entropy on candidate tokens.
///
/// Runs alongside SecretDetector in Stage 2 of FilterPipeline — after named-pattern
/// detection, sharing the `.secrets` feature gate.
///
/// Calibration: H ≥ 4.5 bits/char, token ≥ 20 chars, ≥85% base64/hex charset.
/// Git SHAs (~4.0), UUIDs (~3.8), and MD5/SHA-256/SHA-512 digests (~3.95) fall
/// below the threshold or are excluded by exact-length rules before entropy is
/// computed. Pure-hex tokens of length ≥ 40 that are not a known digest size
/// short-circuit to HIGH_ENTROPY — pure hex peaks at log₂(16) = 4.0 bits/char
/// and would otherwise sit just below the 4.5 floor (cleanup-18c).
public enum EntropyScanner {

    // MARK: - Thresholds (package-internal for test calibration)

    /// Minimum token length. Below 20 chars entropy is statistically meaningless.
    static let minTokenLength = 20

    /// Shannon entropy threshold in bits per character.
    /// Sits above git SHAs (~4.0) and below real secrets (4.8+).
    static let entropyThreshold: Double = 4.5

    /// Minimum fraction of characters in the base64/hex credential charset.
    /// Prevents flagging high-entropy prose or camelCase identifiers.
    static let credentialCharsetRatio: Double = 0.85

    // MARK: - Public API

    public struct ScanResult: Sendable {
        public let redacted: String
        public let patterns: [String]   // ["HIGH_ENTROPY"] or []
    }

    /// Scan text for high-entropy credential-like tokens.
    /// Returns input unchanged (zero-allocation fast path) when no long tokens exist.
    public static func scan(_ input: String) -> ScanResult {
        guard containsLongToken(input) else {
            return ScanResult(redacted: input, patterns: [])
        }
        let tokens = extractTokens(input)
        var result = input
        var found = false
        for token in tokens {
            guard token.count >= minTokenLength else { continue }
            guard !isExcluded(token) else { continue }
            guard isCredentialCharset(token) else { continue }
            guard isLongHexBlob(token) || shannonEntropy(token) >= entropyThreshold else { continue }
            // Literal replacement — token was extracted from the string directly,
            // so exact match is correct and avoids regex metacharacter escaping.
            result = result.replacingOccurrences(of: token, with: "[REDACTED:HIGH_ENTROPY]")
            found = true
        }
        return ScanResult(redacted: result, patterns: found ? ["HIGH_ENTROPY"] : [])
    }

    // MARK: - Fast pre-check

    /// Returns true if the input contains any run of ≥20 non-whitespace characters.
    /// Single O(n) scan over unicode scalars — zero allocation on the common (clean) path.
    private static func containsLongToken(_ input: String) -> Bool {
        var run = 0
        for scalar in input.unicodeScalars {
            if scalar.value == 0x20 || scalar.value == 0x09
                || scalar.value == 0x0A || scalar.value == 0x0D {
                run = 0
            } else {
                run += 1
                if run >= minTokenLength { return true }
            }
        }
        return false
    }

    // MARK: - Token extraction

    /// Split on whitespace and common key-value delimiters to isolate credential values.
    /// Handles `SECRET=value`, `"key": "value"`, `key: 'value'`, and URL query
    /// strings `?key=value&key=value` — the `&` and `?` splits keep query-parameter
    /// values evaluated independently so a high-entropy `X-Goog-Signature=...`
    /// value isn't shielded by the URL-prefix exclusion that fires on the host
    /// portion. Short benign params (e.g. `?utm_source=email`) still fall below
    /// the 20-char minimum + 4.5 entropy floor.
    ///
    /// `.whitespacesAndNewlines` (not `.whitespaces`) so a value followed by a
    /// trailing newline (`SECRET=value\n`) extracts as a clean token rather
    /// than `value\n`. The trailing newline previously survived the split and
    /// broke strict charset checks like the pure-hex length-band rule.
    private static func extractTokens(_ input: String) -> [String] {
        input.components(separatedBy: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "=&?:\"'")))
            .filter { !$0.isEmpty }
    }

    // MARK: - Exclusion rules

    /// Returns true if the token should be skipped regardless of entropy.
    private static func isExcluded(_ token: String) -> Bool {
        // All-numeric (port numbers, timestamps, version strings)
        if token.allSatisfy({ $0.isNumber }) { return true }

        // All-lowercase letters/hyphens/underscores — slug, identifier, or readable word
        if token == token.lowercased()
            && token.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }) { return true }

        // Git SHA: exactly 40 hex chars
        if token.count == 40 && token.allSatisfy({ $0.isHexDigit }) { return true }

        // MD5 (32 hex), SHA-256 (64 hex), and SHA-512 (128 hex) digests —
        // common in build/test output and lockfiles.
        if (token.count == 32 || token.count == 64 || token.count == 128)
            && token.allSatisfy({ $0.isHexDigit }) { return true }

        // UUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (with or without braces)
        if isUUID(token) { return true }

        // File paths
        if token.hasPrefix("/") || token.hasPrefix("./") || token.hasPrefix("~/") { return true }

        // URLs
        if token.hasPrefix("http://") || token.hasPrefix("https://") { return true }

        // npm/yarn/pnpm integrity checksums: "sha512-<base64>", "sha256-<base64>", "md5-<hex>"
        // These appear in lockfiles as "integrity": "sha512-abc123..."
        if token.range(of: #"^sha\d+-|^md5-"#, options: .regularExpression) != nil { return true }

        return false
    }

    nonisolated(unsafe) private static let uuidRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?$"#
        )
    }()

    private static func isUUID(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..., in: token)
        return uuidRegex.firstMatch(in: token, range: range) != nil
    }

    // MARK: - Charset filter

    /// Base64 + hex + URL-safe base64 character set. O(1) membership via bitset.
    private static let credentialChars: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "+/=-")
        return cs
    }()

    /// Returns true if ≥85% of characters belong to the credential charset.
    private static func isCredentialCharset(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let cred = token.unicodeScalars.filter { credentialChars.contains($0) }.count
        return Double(cred) / Double(token.unicodeScalars.count) >= credentialCharsetRatio
    }

    // MARK: - Long hex blob short-circuit

    /// Returns true for pure-hex tokens of length ≥ 40 chars. Pure hex peaks at
    /// log₂(16) = 4.0 bits/char and would otherwise sit just below the 4.5
    /// entropy floor — credential-shaped (HMAC outputs, hex-encoded random
    /// keys) but missed by entropy alone. Known digest sizes (32, 40, 64, 128)
    /// are filtered upstream by `isExcluded`, so this rule only fires on the
    /// unambiguous "long hex blob that isn't a digest" case (cleanup-18c).
    static func isLongHexBlob(_ token: String) -> Bool {
        token.count >= 40 && token.allSatisfy { $0.isHexDigit }
    }

    // MARK: - Shannon entropy

    /// H = -Σ p(c) · log₂(p(c)) over the unicode scalars of token.
    /// Package-internal (not private) so tests can call it directly to pin calibration.
    static func shannonEntropy(_ token: String) -> Double {
        guard token.count > 1 else { return 0.0 }
        var freq: [Unicode.Scalar: Int] = [:]
        for scalar in token.unicodeScalars { freq[scalar, default: 0] += 1 }
        let total = Double(token.unicodeScalars.count)
        return freq.values.reduce(0.0) { acc, count in
            let p = Double(count) / total
            return acc - p * log2(p)
        }
    }
}
