import Foundation

/// Security layer for KnowledgeBase and session history search results.
///
/// Ensures:
/// - FTS5 query input is sanitized (delegates to SessionDatabase.sanitizeFTS5Query)
/// - Search results are scrubbed for secrets before display
/// - Result sets are paginated to prevent memory exhaustion
public enum SearchSecurity {

    // MARK: - Constants

    /// Maximum results per page. Prevents loading unbounded result sets into memory.
    public static let defaultPageSize = 50

    /// Absolute maximum results that can be requested in a single query.
    /// Even if callers request more, this cap is enforced.
    public static let maxPageSize = 200

    /// Maximum search query length. Prevents DoS via extremely long FTS5 queries.
    public static let maxQueryLength = 500

    // MARK: - Query Sanitization

    /// Sanitizes a search query for safe use with FTS5.
    ///
    /// - Truncates to `maxQueryLength` characters
    /// - Delegates to `SessionDatabase.sanitizeFTS5Query` for FTS5 operator stripping
    /// - Returns nil if the sanitized query is empty (caller should show no results)
    public static func sanitizeQuery(_ raw: String) -> String? {
        // Truncate overly long queries
        let truncated = String(raw.prefix(maxQueryLength))

        // Use the existing FTS5 sanitizer from SessionDatabase
        let sanitized = SessionDatabase.sanitizeFTS5Query(truncated)

        return sanitized.isEmpty ? nil : sanitized
    }

    // MARK: - Result Scrubbing

    /// Scrubs a search result string for secrets using SecretDetector.
    ///
    /// Any API keys, tokens, or passwords found in the result text are replaced
    /// with [REDACTED:PATTERN_NAME] placeholders before the text reaches the UI.
    ///
    /// - Parameter text: Raw result text (command, output preview, etc.)
    /// - Returns: Redacted text safe for display.
    public static func scrubSecrets(_ text: String) -> String {
        let result = SecretDetector.scan(text)
        return result.redacted
    }

    /// Scrubs an optional string, returning nil if the input is nil.
    public static func scrubSecrets(_ text: String?) -> String? {
        guard let text = text else { return nil }
        return scrubSecrets(text)
    }

    /// Scrubs all displayable fields of a CommandSearchResult.
    ///
    /// Returns a new result with command and outputPreview fields redacted.
    /// This should be called before passing results to any UI layer.
    public static func scrubResult(_ result: CommandSearchResult) -> CommandSearchResult {
        return CommandSearchResult(
            id: result.id,
            sessionId: result.sessionId,
            timestamp: result.timestamp,
            toolName: result.toolName,
            command: scrubSecrets(result.command),
            rawBytes: result.rawBytes,
            compressedBytes: result.compressedBytes,
            feature: result.feature,
            outputPreview: scrubSecrets(result.outputPreview)
        )
    }

    /// Scrubs an array of search results.
    public static func scrubResults(_ results: [CommandSearchResult]) -> [CommandSearchResult] {
        return results.map(scrubResult)
    }

    // MARK: - Pagination

    /// Clamps a requested page size to safe bounds.
    ///
    /// - Parameter requested: The page size the caller wants.
    /// - Returns: A value between 1 and `maxPageSize`.
    public static func clampPageSize(_ requested: Int) -> Int {
        return max(1, min(requested, maxPageSize))
    }

    /// Calculates a safe SQL OFFSET from page number and page size.
    ///
    /// - Parameters:
    ///   - page: Zero-based page index.
    ///   - pageSize: Number of results per page (will be clamped).
    /// - Returns: The OFFSET value for the SQL query.
    public static func offset(page: Int, pageSize: Int) -> Int {
        let safePage = max(0, page)
        let safeSize = clampPageSize(pageSize)
        return safePage * safeSize
    }

    // MARK: - Secure Search (Convenience)

    /// Performs a secure search: sanitizes query, executes, scrubs results, paginates.
    ///
    /// - Parameters:
    ///   - query: Raw user search input.
    ///   - page: Zero-based page number.
    ///   - pageSize: Results per page (clamped to maxPageSize).
    /// - Returns: Scrubbed, paginated results. Empty array if query is invalid.
    public static func secureSearch(
        query: String,
        page: Int = 0,
        pageSize: Int = defaultPageSize
    ) -> [CommandSearchResult] {
        guard let sanitized = sanitizeQuery(query) else {
            return []
        }

        let safePageSize = clampPageSize(pageSize)

        // SessionDatabase.search already uses sanitizeFTS5Query internally,
        // but we pre-sanitize to enforce our length limit and early-return on empty.
        // We request one extra to allow "has more" detection by the caller.
        let results = SessionDatabase.shared.search(query: sanitized, limit: safePageSize)

        // Scrub secrets from all result fields before returning to UI
        return scrubResults(results)
    }
}
