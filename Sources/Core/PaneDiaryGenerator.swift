import Foundation

/// Pane diary brief composer — round 2 of 3 under the
/// `pane-diaries-cross-session-memory` umbrella.
///
/// Pure function: given the `token_events` rows for a pane-slug's
/// prior session ids (plus an optional last-error string), build a
/// terse brief the next pane-open can inject into MCP instructions.
/// No disk I/O, no DB access — round 3 wires the fetch side.
///
/// Section order (priority: earlier sections survive truncation):
///   1. Header        — `Last time in '<slug>':`
///   2. Last error    — surfaces only when caller passes one
///   3. Last command  — most recent row's `command`
///   4. Files touched — top-3 unique paths from read/edit rows, recency order
///   5. Token cost    — input+output sum across the window
///   6. Recent list   — up to 5 most-recent commands (dropped first on overflow)
///
/// Budget: the full brief must fit in `maxTokens` (default 200).
/// Token count uses `ModelPricing.bytesToTokens` — the senkani-wide
/// estimator (4 bytes/token). Overflow is handled at section
/// granularity: we add sections one at a time and stop when the
/// next candidate would push total bytes over the cap. That gives
/// us the "truncate on command boundary, not mid-word" guarantee —
/// a section either lands whole or is dropped whole.
public enum PaneDiaryGenerator {

    /// Tool names whose `command` column holds a file path — the set
    /// that contributes to the "files touched" section. Mirrors the
    /// filter used in `SessionDatabase.hotFiles` (read-like reads)
    /// plus the obvious write-like tools.
    private static let fileToolNames: Set<String> = [
        "read", "outline_read", "senkani_read",
        "edit", "write", "multiedit",
    ]

    /// Generate a pane diary brief. Returns empty string when the
    /// window is empty (no rows AND no error) — callers should
    /// short-circuit in that case and skip injection entirely.
    ///
    /// - Parameters:
    ///   - rows: token_events rows in any order (we sort internally,
    ///     newest-first, by `timestamp`).
    ///   - paneSlug: the cross-session pane identifier, rendered in
    ///     the header so a reopened pane can confirm its diary came
    ///     from the right slot.
    ///   - lastError: optional caller-supplied error summary. Round 3
    ///     derives this from its fetch layer; the generator stays pure.
    ///   - maxTokens: hard cap. Output will satisfy
    ///     `ModelPricing.bytesToTokens(output.utf8.count) <= maxTokens`.
    public static func generate(
        rows: [SessionDatabase.TimelineEvent],
        paneSlug: String,
        lastError: String? = nil,
        maxTokens: Int = 200
    ) -> String {
        if rows.isEmpty && (lastError?.isEmpty ?? true) { return "" }

        let ordered = rows.sorted { $0.timestamp > $1.timestamp }
        var sections: [String] = []

        sections.append("Last time in '\(paneSlug)':")

        if let err = lastError, !err.isEmpty {
            sections.append("Error: \(truncated(err, max: 140))")
        }

        if let last = ordered.first?.command, !last.isEmpty {
            sections.append("Last: \(truncated(last, max: 120))")
        }

        let files = topFiles(ordered, k: 3)
        if !files.isEmpty {
            let names = files.map { ($0 as NSString).lastPathComponent }
            sections.append("Files: \(names.joined(separator: ", "))")
        }

        let cost = ordered.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
        if cost > 0 {
            sections.append("Cost: \(cost)t")
        }

        let recent = ordered.prefix(5)
            .compactMap { row -> String? in
                guard let cmd = row.command, !cmd.isEmpty else { return nil }
                return truncated(cmd, max: 80)
            }
        if !recent.isEmpty {
            sections.append("Recent: \(recent.joined(separator: "; "))")
        }

        return fitToBudget(sections, maxTokens: maxTokens)
    }

    // MARK: - Budget fit

    /// Concatenate sections with `\n` separators, adding one at a
    /// time. Stop as soon as the next section would overflow the
    /// token cap — the tail sections (least-priority) are dropped
    /// whole, so the output always ends on a section boundary.
    private static func fitToBudget(
        _ sections: [String], maxTokens: Int
    ) -> String {
        guard maxTokens > 0 else { return "" }
        var out = ""
        for section in sections {
            let candidate = out.isEmpty ? section : out + "\n" + section
            let bytes = candidate.utf8.count
            let tokens = ModelPricing.bytesToTokens(bytes)
            if tokens > maxTokens { break }
            out = candidate
        }
        return out
    }

    // MARK: - Files-touched

    /// Top-K unique file paths from read/edit-like rows, kept in
    /// newest-first order. Dedupe-first-wins so a file read twice
    /// only shows up once at its most recent position.
    private static func topFiles(
        _ ordered: [SessionDatabase.TimelineEvent], k: Int
    ) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for row in ordered {
            guard let tool = row.toolName, fileToolNames.contains(tool),
                  let path = row.command, !path.isEmpty,
                  !seen.contains(path) else { continue }
            seen.insert(path)
            out.append(path)
            if out.count >= k { break }
        }
        return out
    }

    // MARK: - String helpers

    /// Truncate with an ellipsis marker when over the char budget.
    /// The budget is a char count, not a token count — the final
    /// section-level budget fit is what enforces the overall cap.
    private static func truncated(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let end = s.index(s.startIndex, offsetBy: max - 1)
        return String(s[..<end]) + "…"
    }
}
