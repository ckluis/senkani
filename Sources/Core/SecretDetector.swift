import Foundation

/// Detects and redacts common API keys, tokens, and passwords from text.
public enum SecretDetector {
    /// Known patterns for API keys and secrets.
    ///
    /// Ordering note: specific prefixes (ANTHROPIC "sk-ant-", OPENAI_PROJECT
    /// "sk-proj-") come before generic OPENAI "sk-" so the more specific
    /// category wins on overlap. Non-overlapping families are order-
    /// independent.
    ///
    /// F5 (Schneier re-audit 2026-04-16): added Slack, GCP OAuth, Stripe,
    /// npm, HuggingFace, and a dedicated OpenAI project-key pattern. The
    /// generic OPENAI pattern `sk-[a-zA-Z0-9]{20,}` MISSES `sk-proj-...`
    /// because `-` breaks its character class — hence a dedicated entry.
    static let patterns: [(name: String, regex: NSRegularExpression)] = {
        let defs: [(String, String)] = [
            ("ANTHROPIC_API_KEY", "sk-ant-[a-zA-Z0-9_-]{20,}"),
            ("OPENAI_PROJECT_KEY", "sk-proj-[a-zA-Z0-9_-]{20,}"),
            ("OPENAI_API_KEY", "sk-[a-zA-Z0-9]{20,}"),
            ("AWS_SECRET_ACCESS_KEY", "(?i)aws[_\\s]?secret[_\\s]?access[_\\s]?key[\\s]*[=:][\\s]*[A-Za-z0-9/+=]{20,}"),
            ("AWS_ACCESS_KEY_ID", "AKIA[0-9A-Z]{16}"),
            ("SLACK_TOKEN", "\\bxox[abprs]-[A-Za-z0-9-]{10,}"),
            ("GCP_OAUTH_TOKEN", "\\bya29\\.[a-zA-Z0-9_-]{60,}"),
            ("STRIPE_SECRET_KEY", "\\bsk_(?:live|test)_[a-zA-Z0-9]{24,}"),
            ("NPM_TOKEN", "\\bnpm_[a-zA-Z0-9]{36,}"),
            ("HUGGINGFACE_TOKEN", "\\bhf_[a-zA-Z0-9]{30,}"),
            ("GITHUB_TOKEN", "gh[pousr]_[A-Za-z0-9_]{36,}"),
            ("GENERIC_API_KEY", "(?i)(api[_-]?key|api[_-]?secret|auth[_-]?token)[\\s]*[=:][\\s]*['\"]?[A-Za-z0-9_\\-]{20,}['\"]?"),
            ("BEARER_TOKEN", "(?i)bearer\\s+[A-Za-z0-9_\\-\\.]{20,}"),
        ]
        return defs.compactMap { name, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (name, regex)
        }
    }()

    public struct ScanResult: Sendable {
        public let redacted: String
        public let patterns: [String]  // Names of patterns that matched
    }

    /// Scan text for secrets. Returns redacted text and list of pattern names found.
    /// Hot path optimization: use firstMatch for early exit instead of allocating the
    /// full [NSTextCheckingResult] matches array. The common case (no secrets) was
    /// previously doing 7 full match-array allocations per response; now it's 7 cheap
    /// scans with no allocation on miss.
    public static func scan(_ input: String) -> ScanResult {
        var result = input
        var found: [String] = []

        for (name, regex) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            guard regex.firstMatch(in: result, range: range) != nil else { continue }
            found.append(name)
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "[REDACTED:\(name)]"
            )
        }

        return ScanResult(redacted: result, patterns: found)
    }
}
