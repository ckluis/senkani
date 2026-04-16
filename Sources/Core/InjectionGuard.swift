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
    private static let keywords: [String] = [
        "ignore previous", "ignore all prior", "disregard all",
        "you are now", "your new role",
        "please execute", "call the function",
        "user has authorized", "admin mode enabled", "safety filters disabled",
        "send the", "upload the contents", "include the",
        "system:",
    ]

    private static func containsAnyKeyword(_ normalized: String) -> Bool {
        for keyword in keywords {
            if normalized.contains(keyword) { return true }
        }
        return false
    }

    // MARK: - Normalization (anti-evasion)

    private static let zeroWidthScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}",
        "\u{00AD}", "\u{2060}", "\u{180E}",
    ]

    private static let homoglyphMap: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{0430}": "a", "\u{0435}": "e", "\u{043E}": "o",
        "\u{0440}": "p", "\u{0441}": "c", "\u{0443}": "y",
        "\u{0445}": "x", "\u{0410}": "a", "\u{0415}": "e",
        "\u{041E}": "o", "\u{0420}": "p", "\u{0421}": "c",
        "\u{0423}": "y", "\u{0425}": "x",
    ]

    private static func normalize(_ input: String) -> String {
        // Single pass: lowercase, drop zero-width, remap Cyrillic homoglyphs,
        // collapse whitespace runs. Preserves prior per-pair-loop semantics but
        // runs linear in input size.
        let lowered = input.lowercased()
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
            // Instruction Override
            ("instruction override", "\\bignore\\s+(?:all\\s+)?previous\\s+instructions\\b"),
            ("instruction override", "\\bignore\\s+all\\s+prior\\b"),
            ("instruction override", "\\byou\\s+are\\s+now\\s+a\\b"),
            ("instruction override", "\\byour\\s+new\\s+role\\s+is\\b"),
            ("instruction override", "\\bdisregard\\s+all\\s+prior\\b"),
            ("instruction override", "(?m)^\\s*system\\s*:"),

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
