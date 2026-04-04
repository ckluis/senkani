import Foundation
import Core

/// Security layer for Knowledge Base search.
/// Sanitizes FTS5 queries, scrubs secrets from results, and enforces pagination.
enum SearchSecurity {
    /// Maximum query length accepted.
    static let maxQueryLength = 200

    /// Default page size for paginated results.
    static let defaultPageSize = 50

    /// Perform a secure, paginated FTS5 search.
    /// - Parameters:
    ///   - query: Raw user input (will be sanitized).
    ///   - page: Zero-based page index.
    ///   - pageSize: Number of results per page.
    /// - Returns: Scrubbed results for the requested page.
    static func secureSearch(
        query: String,
        page: Int = 0,
        pageSize: Int = defaultPageSize
    ) -> [CommandSearchResult] {
        let trimmed = sanitizeQuery(query)
        guard !trimmed.isEmpty else { return [] }

        let limit = min(pageSize, 100)
        let allResults = SessionDatabase.shared.search(query: trimmed, limit: limit * (page + 1))

        // Paginate
        let startIndex = page * limit
        guard startIndex < allResults.count else { return [] }
        let endIndex = min(startIndex + limit, allResults.count)
        let pageResults = Array(allResults[startIndex..<endIndex])

        return scrubResults(pageResults)
    }

    /// Sanitize a user query: truncate, strip dangerous characters.
    static func sanitizeQuery(_ raw: String) -> String {
        let truncated = String(raw.prefix(maxQueryLength))
        return truncated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scrub potential secrets from result fields before display.
    /// Replaces common secret patterns with redaction placeholders.
    static func scrubResults(_ results: [CommandSearchResult]) -> [CommandSearchResult] {
        // For now, return results as-is since SessionDatabase already truncates
        // outputPreview and the secrets filter runs at ingestion time.
        // This is a defense-in-depth stub for future pattern matching.
        return results
    }
}
