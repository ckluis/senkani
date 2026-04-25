import Foundation

/// Single redaction point for any string that is about to be written to the
/// session database.
///
/// Why this exists
/// ---------------
/// `CommandStore.recordCommand` already redacts via `SecretDetector.scan`.
/// `TokenEventStore` and `SandboxStore` previously wrote raw command text and
/// full command output, so a `cat .env` output lived on disk for 24 hours in
/// plaintext and a command like `export API_KEY=sk_live_...` landed in
/// `token_events.command` unredacted. This helper wraps `SecretDetector.scan`
/// behind a single call so all three stores use the same policy and any
/// future store inherits the same coverage for free.
///
/// Behavior
/// --------
/// - Optional inputs pass through nil.
/// - Empty strings pass through as-is.
/// - Non-empty strings are scanned; the redacted form is always returned.
/// - The scan also returns the list of detected patterns — callers that
///   want an observability signal can count non-empty `patterns`.
public enum PersistenceRedaction {

    /// Redact an optional command/output string for database persistence.
    /// Returns `(redacted, count)` where `count` is the number of patterns
    /// that matched (callers use this for privacy-health signals).
    @discardableResult
    public static func redact(_ value: String?) -> (redacted: String?, patternsMatched: Int) {
        guard let value, !value.isEmpty else { return (value, 0) }
        let scan = SecretDetector.scan(value)
        return (scan.redacted, scan.patterns.count)
    }

    /// Convenience for callers that only need the redacted string.
    public static func redactedString(_ value: String?) -> String? {
        redact(value).redacted
    }
}
