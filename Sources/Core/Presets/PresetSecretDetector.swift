import Foundation

/// Security gate on preset install. Runs `SecretDetector.scan` over the
/// preset's resolved command (placeholders substituted) and rejects
/// the install if any known-pattern match is found.
///
/// Intent (Schneier's gate): a preset JSON hand-edited by an operator
/// must not smuggle a raw API key into `~/.senkani/schedules/<name>.json`
/// where it would live in cleartext. The detector is the same one used
/// by the shared `SecretDetector` — not a new ruleset.
public enum PresetSecretDetector {

    public enum Verdict: Sendable, Equatable {
        /// No secrets matched — install may proceed.
        case clear
        /// One or more patterns matched — install MUST abort.
        /// `patterns` carries the pattern names (`ANTHROPIC_API_KEY`,
        /// `GITHUB_TOKEN`, …) for error copy.
        case block(patterns: [String])
    }

    /// Scan a resolved command string. Returns `.clear` on pass,
    /// `.block` with matched pattern names on fail. Delegates match
    /// logic to the shared `SecretDetector` enum.
    public static func scan(resolvedCommand: String) -> Verdict {
        let result = SecretDetector.scan(resolvedCommand)
        return result.patterns.isEmpty ? .clear : .block(patterns: result.patterns)
    }

    /// Human-readable message for a `.block` verdict. Used by CLI +
    /// pane-sheet callers so the error copy stays consistent.
    public static func blockMessage(preset: String, patterns: [String]) -> String {
        let kinds = patterns.sorted().joined(separator: ", ")
        return """
        Preset install aborted — secret detector matched pattern(s) [\(kinds)] \
        in preset `\(preset)`'s resolved command. Replace inline secrets with \
        ${ENV_VAR} references and retry.
        """
    }
}
