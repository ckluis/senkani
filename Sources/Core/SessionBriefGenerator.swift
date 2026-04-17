import Foundation

/// Generates a session continuity brief from prior session data.
/// Pure function — takes data, returns string. No DB access, no side effects.
/// Every fact in the output is traceable to a `LastSessionActivity` field.
public enum SessionBriefGenerator {

    /// Generate a session continuity brief.
    /// Returns empty string if no prior session data exists AND no
    /// applied context docs. (Context docs alone can seed a brief even
    /// on a fresh install — the agent benefits from priming even if
    /// there's no "last session" to resume.)
    /// Output is guaranteed to be <= maxTokens (estimated at 4 chars/token).
    ///
    /// H+2b: `appliedContextDocs` (top-N recent, already `.applied`)
    /// contribute a "Learned context:" section at the bottom of the
    /// brief with its own sub-budget. Each doc contributes only a
    /// one-line summary (title + first 140 chars of body) so a large
    /// doc can't dominate. Full bodies live on disk at
    /// `.senkani/context/<title>.md` — the agent can `senkani_read`
    /// them on demand if it wants the full context.
    public static func generate(
        lastActivity: SessionDatabase.LastSessionActivity?,
        changedFilesSinceLastSession: [String] = [],
        appliedContextDocs: [LearnedContextDoc] = [],
        maxTokens: Int = 170
    ) -> String {
        // Early-out: empty when there's nothing of either kind to show.
        if lastActivity == nil && appliedContextDocs.isEmpty { return "" }

        let maxChars = maxTokens * 4

        var result = ""
        if let activity = lastActivity {
            let section1 = buildSessionResume(activity)
            let section2 = buildChangedFiles(changedFilesSinceLastSession)
            let section3 = buildFocusHint(activity)

            result = section1

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
        }

        // H+2b — append learned context section if there's budget.
        // Each line is capped at 160 chars; we keep adding while the
        // total stays under budget, so a small brief can show more docs.
        if !appliedContextDocs.isEmpty, result.count < maxChars {
            let contextSection = buildContextSection(
                docs: appliedContextDocs,
                remainingChars: maxChars - result.count - 20 // 20 chars slack for separator
            )
            if !contextSection.isEmpty {
                let separator = result.isEmpty ? "" : " "
                let candidate = result + separator + contextSection
                if candidate.count <= maxChars {
                    result = candidate
                }
            }
        }

        // Final truncation if still over budget
        if result.count > maxChars {
            result = String(result.prefix(maxChars - 3)) + "..."
        }

        return result
    }

    /// Section 4 (H+2b): "Learned: title — first line of body" per applied
    /// doc, packed until `remainingChars` is exhausted. Docs assumed
    /// pre-sorted most-recent-first.
    static func buildContextSection(
        docs: [LearnedContextDoc],
        remainingChars: Int
    ) -> String {
        guard remainingChars > 20, !docs.isEmpty else { return "" }
        let lineMax = 160
        var lines: [String] = []
        var used = 0
        for doc in docs {
            let firstLine = extractFirstContentLine(doc.body)
            let entry = firstLine.isEmpty
                ? "\(doc.title)"
                : "\(doc.title) — \(firstLine)"
            let clipped = String(entry.prefix(lineMax))
            // +2 for the ", " separator between entries.
            let cost = clipped.count + (lines.isEmpty ? 0 : 2)
            if used + cost > remainingChars { break }
            lines.append(clipped)
            used += cost
        }
        guard !lines.isEmpty else { return "" }
        return "Learned: " + lines.joined(separator: ", ") + "."
    }

    /// Extract the first non-empty non-heading line from a markdown body.
    /// Keeps the brief line terse — an applied doc's one-sentence summary
    /// lives at the top of its body by convention.
    private static func extractFirstContentLine(_ body: String) -> String {
        for rawLine in body.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") { continue }  // skip headings
            if line.hasPrefix("<!--") { continue } // skip HTML comments
            return line
        }
        return ""
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
