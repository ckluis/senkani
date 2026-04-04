import Foundation

/// Detects and redacts common API keys, tokens, and passwords from text.
public enum SecretDetector {
    /// Known patterns for API keys and secrets.
    static let patterns: [(name: String, regex: NSRegularExpression)] = {
        let defs: [(String, String)] = [
            ("ANTHROPIC_API_KEY", "sk-ant-[a-zA-Z0-9_-]{20,}"),
            ("OPENAI_API_KEY", "sk-[a-zA-Z0-9]{20,}"),
            ("AWS_SECRET_ACCESS_KEY", "(?i)aws[_\\s]?secret[_\\s]?access[_\\s]?key[\\s]*[=:][\\s]*[A-Za-z0-9/+=]{20,}"),
            ("AWS_ACCESS_KEY_ID", "AKIA[0-9A-Z]{16}"),
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
    public static func scan(_ input: String) -> ScanResult {
        var result = input
        var found: [String] = []

        for (name, regex) in patterns {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            if !matches.isEmpty {
                found.append(name)
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "[REDACTED:\(name)]"
                )
            }
        }

        return ScanResult(redacted: result, patterns: found)
    }
}
