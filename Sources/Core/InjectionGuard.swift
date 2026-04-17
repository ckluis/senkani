import Foundation

/// Scans MCP tool responses for embedded prompt injection attacks.
/// Two-phase scanning: fast keyword reject (<200μs), full regex only on match (<1ms).
/// Follows SecretDetector's API pattern. Advisory only — sanitizes, never blocks.
public enum InjectionGuard {

    /// Result of an injection scan.
    public struct ScanResult: Sendable {
        /// Text with injection attempts replaced by `[INJECTION BLOCKED: category]` markers.
        public let sanitized: String
        /// Categories of detected injection attempts (empty if clean).
        public let detections: [String]
    }

    // MARK: - Public API

    /// Scan text for prompt injection patterns.
    /// Returns input unchanged if no injections detected (zero-copy fast path).
    public static func scan(_ input: String) -> ScanResult {
        // Phase 1: Fast keyword reject
        let normalized = normalize(input)
        guard containsAnyKeyword(normalized) else {
            return ScanResult(sanitized: input, detections: [])
        }

        // Phase 2: Full regex scan
        var result = input
        var detections: [String] = []

        for pattern in compiledPatterns {
            let range = NSRange(result.startIndex..., in: result)
            if pattern.regex.firstMatch(in: result, range: range) != nil {
                // Also check the normalized version for obfuscated attacks
                let normRange = NSRange(normalized.startIndex..., in: normalized)
                let matchesNormalized = pattern.regex.firstMatch(in: normalized, range: normRange) != nil
                let matchesDirect = true  // already matched above

                if matchesDirect || matchesNormalized {
                    result = pattern.regex.stringByReplacingMatches(
                        in: result,
                        range: NSRange(result.startIndex..., in: result),
                        withTemplate: "[INJECTION BLOCKED: \(pattern.category)]"
                    )
                    if !detections.contains(pattern.category) {
                        detections.append(pattern.category)
                    }
                }
            } else {
                // Try the normalized version (catches obfuscated attacks)
                let normRange = NSRange(normalized.startIndex..., in: normalized)
                if pattern.regex.firstMatch(in: normalized, range: normRange) != nil {
                    // Found in normalized but not direct — the original has obfuscation
                    // Replace based on the normalized match positions mapped back
                    // Simplified: just flag it and note the category
                    detections.append(pattern.category)
                    // We can't easily map normalized positions back, so append a warning
                    result += "\n[INJECTION BLOCKED: obfuscated \(pattern.category) detected]"
                }
            }
        }

        return ScanResult(sanitized: result, detections: detections)
    }

    // MARK: - Fast Keyword Check

    /// Keywords that MUST appear for any pattern to match.
    /// If none are present, skip regex entirely.
    ///
    /// F3 (Schneier re-audit 2026-04-16): added Phase-1 triggers for the
    /// five Latin-script European languages the multilingual `instruction
    /// override` patterns cover. Each keyword is specific enough to avoid
    /// firing on benign English text (e.g. "ignora las" wouldn't appear in
    /// English prose; "ignore les" is French-distinct).
    private static let keywords: [String] = [
        // English
        "ignore previous", "ignore all prior", "disregard all",
        "you are now", "your new role",
        "please execute", "call the function",
        "user has authorized", "admin mode enabled", "safety filters disabled",
        "send the", "upload the contents", "include the",
        "system:",
        // Multilingual instruction-override Phase-1 triggers. Keyed on the
        // noun-phrase ("X anteriores|precedenti|précédentes|…") rather than
        // the verb-phrase — quantifiers like "todas", "toutes", "alle" often
        // split the verb from its object, so a verb-level substring would
        // miss real attack payloads. These noun phrases are specific to the
        // override context; benign Spanish/Italian/etc. tech docs rarely
        // chain "instructions + anteriores" together.
        "instrucciones anteriores", "instrucciones previas",    // Spanish
        "instructions précédentes", "instructions precedentes", // French (± accent)
        "vorherigen anweisungen", "vorigen anweisungen",        // German
        "instruções anteriores", "instrucoes anteriores",       // Portuguese (± cedilla)
        "istruzioni precedenti",                                // Italian
    ]

    /// Precompiled single-regex alternation across all keywords. One O(n)
    /// scan subsumes what used to be N independent `String.contains` calls.
    /// N=23 keywords × 1 MB input was ~500 ms; single compiled alternation
    /// is ~25 ms on the same input.
    nonisolated(unsafe) private static let keywordRegex: NSRegularExpression = {
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = escaped.joined(separator: "|")
        // Force-unwrap is safe: the only possible failure is a malformed pattern,
        // and every element came through `escapedPattern(for:)`.
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func containsAnyKeyword(_ normalized: String) -> Bool {
        let range = NSRange(normalized.startIndex..., in: normalized)
        return keywordRegex.firstMatch(in: normalized, range: range) != nil
    }

    // MARK: - Normalization (anti-evasion)

    private static let zeroWidthScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}",
        "\u{00AD}", "\u{2060}", "\u{180E}",
    ]

    /// Confusable-script → Latin map. Only lowercase entries — `normalize()`
    /// lowercases before lookup.
    ///
    /// F4 (Schneier re-audit 2026-04-16): Fullwidth Latin and Mathematical
    /// Alphanumeric Symbols are folded to basic Latin by NFKC (in normalize()),
    /// so no explicit entries needed. Cyrillic and Greek aren't NFKC-
    /// equivalents of Latin — they need this explicit map.
    private static let homoglyphMap: [Unicode.Scalar: Unicode.Scalar] = [
        // Cyrillic lowercase (and uppercase — Swift lowercases Cyrillic too).
        "\u{0430}": "a", "\u{0435}": "e", "\u{043E}": "o",
        "\u{0440}": "p", "\u{0441}": "c", "\u{0443}": "y",
        "\u{0445}": "x", "\u{0410}": "a", "\u{0415}": "e",
        "\u{041E}": "o", "\u{0420}": "p", "\u{0421}": "c",
        "\u{0423}": "y", "\u{0425}": "x",
        // Greek lowercase — closely-confusable letters only. Uppercase Greek
        // lowercases to these via Swift's default Unicode lowercase mapping
        // (e.g. Α U+0391 → α U+03B1), so uppercase entries aren't needed.
        "\u{03B1}": "a", // α alpha
        "\u{03B5}": "e", // ε epsilon
        "\u{03BF}": "o", // ο omicron
        "\u{03C1}": "p", // ρ rho
        "\u{03C7}": "x", // χ chi
        "\u{03B9}": "i", // ι iota
        "\u{03BA}": "k", // κ kappa
        "\u{03BD}": "v", // ν nu (close)
        "\u{03BC}": "u", // μ mu (close)
        "\u{03C4}": "t", // τ tau (close)
    ]

    private static func normalize(_ input: String) -> String {
        // F4: NFKC compatibility mapping folds Fullwidth Latin (ａｂｃ → abc),
        // Mathematical Alphanumeric Symbols (𝗂𝗀𝗇𝗈𝗋𝖾 → ignore), ligatures,
        // and other compatibility variants to basic Latin. Cyrillic and
        // Greek are DIFFERENT scripts (not compat variants) and go through
        // the homoglyphMap below.
        //
        // Fast path: ASCII-only inputs skip NFKC entirely. Typical tool
        // output is ASCII, and NFKC on 1 MB roughly doubled the normalize
        // cost (0.3s → 0.6s). Byte-level ASCII check is ~10× cheaper than
        // NFKC, so guarding it keeps the English hot path fast without
        // losing coverage for non-ASCII inputs.
        let isASCII = input.utf8.allSatisfy { $0 < 0x80 }
        let normalizedInput = isASCII ? input : input.precomposedStringWithCompatibilityMapping
        let lowered = normalizedInput.lowercased()

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(lowered.unicodeScalars.count)

        var lastWasSpace = false
        for scalar in lowered.unicodeScalars {
            if zeroWidthScalars.contains(scalar) { continue }
            let mapped = homoglyphMap[scalar] ?? scalar
            if mapped == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            scalars.append(mapped)
        }
        return String(scalars)
    }

    // MARK: - Pattern Table

    private struct Pattern {
        let category: String
        let regex: NSRegularExpression
    }

    nonisolated(unsafe) private static let compiledPatterns: [Pattern] = {
        let defs: [(String, String)] = [
            // Instruction Override — English
            ("instruction override", "\\bignore\\s+(?:all\\s+)?previous\\s+instructions\\b"),
            ("instruction override", "\\bignore\\s+all\\s+prior\\b"),
            ("instruction override", "\\byou\\s+are\\s+now\\s+a\\b"),
            ("instruction override", "\\byour\\s+new\\s+role\\s+is\\b"),
            ("instruction override", "\\bdisregard\\s+all\\s+prior\\b"),
            ("instruction override", "(?m)^\\s*system\\s*:"),

            // F3 — Multilingual instruction override (Latin-script
            // Romance/Germanic). Each pattern is anchored to a distinctive
            // trigram ("ignora las", "ignorez les", …) that doesn't appear
            // in benign English text, so FP risk is low.
            // Spanish:  "ignora [todas] las/los instrucciones anteriores|previas"
            ("instruction override", "\\bignora\\s+(?:todas?\\s+)?(?:las|los)\\s+instrucc?iones\\s+(?:anteriores|previas)\\b"),
            // French:   "ignorez/ignore [toutes] les instructions précédentes"
            ("instruction override", "\\bignore[rz]?\\s+(?:toutes\\s+)?les\\s+instructions\\s+pr[eé]c[eé]dentes\\b"),
            // German:   "ignoriere [alle] vorherigen/vorigen anweisungen"
            ("instruction override", "\\bignorier(?:e|en)?\\s+(?:alle\\s+)?(?:vorherigen|vorigen)\\s+anweisungen\\b"),
            // Portuguese: "ignore/ignora [todas] as instruções/instrucoes anteriores"
            ("instruction override", "\\bignor[ae]\\s+(?:todas?\\s+)?as\\s+instru[cç][õo]es\\s+anteriores\\b"),
            // Italian:  "ignora [tutte] le istruzioni precedenti"
            ("instruction override", "\\bignora\\s+(?:tutte\\s+)?le\\s+istruzioni\\s+precedenti\\b"),

            // Tool Call Injection
            ("tool call injection", "\\bplease\\s+execute\\s*:"),
            ("tool call injection", "\\bcall\\s+the\\s+function\\b"),

            // Context Manipulation
            ("context manipulation", "\\bthe\\s+user\\s+has\\s+authorized\\b"),
            ("context manipulation", "\\badmin\\s+mode\\s+enabled\\b"),
            ("context manipulation", "\\bsafety\\s+filters?\\s+disabled\\b"),

            // Exfiltration
            ("exfiltration", "\\bsend\\s+the\\s+.*?\\bkey\\s+to\\b"),
            ("exfiltration", "\\bupload\\s+the\\s+contents?\\s+to\\b"),
        ]

        return defs.compactMap { (category, pattern) in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return nil
            }
            return Pattern(category: category, regex: regex)
        }
    }()
}
