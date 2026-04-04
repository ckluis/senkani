import SwiftUI
import Core

/// Knowledge base search view — FTS5 search across session history.
///
/// SECURITY NOTES (for agents extending this view):
/// - All search queries MUST go through SearchSecurity.sanitizeQuery() before FTS5
/// - All results MUST go through SearchSecurity.scrubResults() before display
/// - Results are paginated via SearchSecurity to prevent memory exhaustion
/// - Never display raw outputPreview without secret scrubbing
struct KnowledgeBaseView: View {
    @State private var searchText = ""
    @State private var results: [CommandSearchResult] = []
    @State private var currentPage = 0
    @State private var isSearching = false

    private let pageSize = SearchSecurity.defaultPageSize

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .font(.system(size: 12))

                TextField("Search session history...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                    .onSubmit { performSearch() }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        results = []
                        currentPage = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SenkaniTheme.paneShell)

            Divider()
                .overlay(SenkaniTheme.inactiveBorder)

            // Results
            if results.isEmpty && !searchText.isEmpty && !isSearching {
                emptyState
            } else if results.isEmpty {
                placeholderState
            } else {
                resultsList
            }
        }
        .background(SenkaniTheme.paneBody)
    }

    // MARK: - Search

    /// Performs a secure, paginated search.
    /// Query is sanitized and results are scrubbed for secrets before display.
    private func performSearch() {
        currentPage = 0
        isSearching = true

        // SECURITY: All queries go through SearchSecurity which:
        // 1. Truncates to max length
        // 2. Strips FTS5 operators via SessionDatabase.sanitizeFTS5Query
        // 3. Returns nil for empty/invalid queries
        let scrubbed = SearchSecurity.secureSearch(
            query: searchText,
            page: currentPage,
            pageSize: pageSize
        )
        results = scrubbed
        isSearching = false
    }

    /// Loads the next page of results.
    private func loadNextPage() {
        currentPage += 1
        let nextPage = SearchSecurity.secureSearch(
            query: searchText,
            page: currentPage,
            pageSize: pageSize
        )
        results.append(contentsOf: nextPage)
    }

    // MARK: - Subviews

    private var placeholderState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Text("Search Your AI History")
                .font(.headline)
                .foregroundStyle(SenkaniTheme.textPrimary)
            Text("Search across all session commands and outputs")
                .font(.caption)
                .foregroundStyle(SenkaniTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Text("No results")
                .font(.subheadline)
                .foregroundStyle(SenkaniTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(results) { result in
                    resultRow(result)
                }

                // "Load more" button for pagination
                if results.count >= (currentPage + 1) * pageSize {
                    Button("Load more...") {
                        loadNextPage()
                    }
                    .font(.caption)
                    .foregroundStyle(SenkaniTheme.accentAnalytics)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private func resultRow(_ result: CommandSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(result.toolName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.accentTerminal)

                Spacer()

                Text(result.timestamp, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }

            // SECURITY: command and outputPreview have already been scrubbed
            // by SearchSecurity.scrubResults() — secrets are replaced with
            // [REDACTED:PATTERN_NAME] placeholders before reaching this view.
            if let command = result.command {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                    .lineLimit(2)
            }

            if let preview = result.outputPreview {
                Text(preview)
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(SenkaniTheme.paneShell.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
