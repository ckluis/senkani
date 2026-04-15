import Foundation

/// Generates a session continuity brief from prior session data.
/// Pure function — takes data, returns string. No DB access, no side effects.
/// Every fact in the output is traceable to a `LastSessionActivity` field.
public enum SessionBriefGenerator {

    /// Generate a session continuity brief.
    /// Returns empty string if no prior session data exists.
    /// Output is guaranteed to be <= maxTokens (estimated at 4 chars/token).
    public static func generate(
        lastActivity: SessionDatabase.LastSessionActivity?,
        changedFilesSinceLastSession: [String] = [],
        maxTokens: Int = 170
    ) -> String {
        guard let activity = lastActivity else { return "" }

        let section1 = buildSessionResume(activity)
        let section2 = buildChangedFiles(changedFilesSinceLastSession)
        let section3 = buildFocusHint(activity)

        // Assemble with token budget enforcement
        let maxChars = maxTokens * 4
        var result = section1

        if !section3.isEmpty {
            let candidate = result + " " + section3
            if candidate.count <= maxChars {
                result = candidate
            }
        }

        if !section2.isEmpty {
            let candidate = result + " " + section2
            if candidate.count <= maxChars {
                result = candidate
            }
        }

        // Final truncation if still over budget
        if result.count > maxChars {
            result = String(result.prefix(maxChars - 3)) + "..."
        }

        return result
    }

    // MARK: - Section Builders

    /// Section 1: Session resume (~50 tokens)
    private static func buildSessionResume(_ activity: SessionDatabase.LastSessionActivity) -> String {
        let duration = formatDuration(activity.durationSeconds)
        let savings = activity.totalRawTokens > 0
            ? Int(Double(activity.totalSavedTokens) / Double(activity.totalRawTokens) * 100)
            : 0

        var parts: [String] = []
        parts.append("Last session: \(duration), \(activity.commandCount) tool calls, \(savings)% savings.")

        // Hot files (filenames only — Shannon: max info per token)
        let filenames = activity.topHotFiles.prefix(3).map { ($0 as NSString).lastPathComponent }
        if !filenames.isEmpty {
            parts.append("Hot files: \(filenames.joined(separator: ", ")).")
        }

        // Last command (truncated)
        if let cmd = activity.lastCommand {
            let truncated = cmd.count > 60 ? String(cmd.prefix(57)) + "..." : cmd
            parts.append("Last: \(truncated)")
        }

        return parts.joined(separator: " ")
    }

    /// Section 2: Changed files since last session (~30 tokens, optional)
    private static func buildChangedFiles(_ files: [String]) -> String {
        guard !files.isEmpty else { return "" }
        let names = files.prefix(5).map { ($0 as NSString).lastPathComponent }
        return "Changed since last session: \(names.joined(separator: ", "))."
    }

    /// Section 3: Focus hint (~20 tokens, optional)
    private static func buildFocusHint(_ activity: SessionDatabase.LastSessionActivity) -> String {
        guard !activity.recentSearchQueries.isEmpty else { return "" }
        let queries = activity.recentSearchQueries.prefix(2).map { q in
            let trimmed = q.count > 30 ? String(q.prefix(27)) + "..." : q
            return "'\(trimmed)'"
        }
        return "Recent searches: \(queries.joined(separator: ", "))."
    }

    // MARK: - Changed File Detection

    /// Check which files have been modified since a given date.
    /// Uses stat() — O(N) where N = file count, each stat is ~1 microsecond.
    public static func filesChangedSince(
        files: [String],
        since: Date,
        projectRoot: String
    ) -> [String] {
        files.filter { filePath in
            let fullPath = filePath.hasPrefix("/") ? filePath : projectRoot + "/" + filePath
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                  let mtime = attrs[.modificationDate] as? Date else {
                return false  // file deleted or inaccessible — exclude
            }
            return mtime > since
        }
    }

    // MARK: - Helpers

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }
}
