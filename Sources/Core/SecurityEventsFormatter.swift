import Foundation

/// Shared formatter for the `event_counters` rows populated at each
/// security-defense site (injection detection, SSRF block, handshake
/// rejection, command redaction, retention prune, migration applied).
///
/// Called from:
///   - `senkani stats --security` (CLI dashboard)
///   - `senkani_session action:"stats"` (MCP tool output)
///
/// Design decisions (Luminary wave 2026-04-17):
///   - **Cavoukian**: `project_root` always flows through
///     `ProjectSecurity.redactPath` — `/Users/<name>` never reaches the
///     operator's screen verbatim.
///   - **Gelman**: when a `totalCommands` denominator is available, show
///     an inline rate `count/total (pct%)` for every counter under
///     `security.*` — counts alone mislead.
///   - **Tufte**: columns aligned, no emoji, one blank line between
///     scopes; monospace-friendly.
///   - **Jobs**: default terse summary ("0 SSRF blocks in the last
///     week"); `verbose=true` expands per-row.
public enum SecurityEventsFormatter {

    public struct Options: Sendable {
        public let verbose: Bool
        /// Denominator for rate computation (Gelman). Pass `nil` to skip rates.
        public let totalCommands: Int?
        /// Project the operator is asking about, so per-project rows show up
        /// alongside process-global ones. Pass empty string for global only.
        public let projectRoot: String

        public init(verbose: Bool = false, totalCommands: Int? = nil, projectRoot: String = "") {
            self.verbose = verbose
            self.totalCommands = totalCommands
            self.projectRoot = projectRoot
        }
    }

    /// Entry point — queries `SessionDatabase.shared` for both project and
    /// global rows, composes the output, returns the string. Returns an
    /// empty string when there are no rows (keeps "nothing fired yet"
    /// dashboards quiet).
    public static func format(_ options: Options = .init()) -> String {
        let db = SessionDatabase.shared
        let projectRows = db.eventCounts(projectRoot: options.projectRoot)
        let globalRows = db.eventCounts(projectRoot: "")
        return render(projectRows: projectRows, globalRows: globalRows, options: options)
    }

    /// Pure render — separated so tests can inject rows without touching
    /// the singleton DB.
    public static func render(
        projectRows: [SessionDatabase.EventCountRow],
        globalRows: [SessionDatabase.EventCountRow],
        options: Options
    ) -> String {
        if projectRows.isEmpty && globalRows.isEmpty {
            return ""
        }

        var lines: [String] = []
        lines.append("Security events")

        if options.verbose {
            renderVerbose(rows: projectRows, scope: "project", into: &lines, options: options)
            renderVerbose(rows: globalRows, scope: "global",  into: &lines, options: options)
        } else {
            renderTerse(rows: projectRows + globalRows, into: &lines, options: options)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Terse

    private static func renderTerse(
        rows: [SessionDatabase.EventCountRow],
        into lines: inout [String],
        options: Options
    ) {
        // Sum counts by event_type across scopes — the default view hides
        // scope unless it matters (i.e., unless the same event appears in
        // both).
        var totals: [String: Int] = [:]
        for r in rows { totals[r.eventType, default: 0] += r.count }

        // Stable ordering: security.* first, then retention.*, then others.
        let sorted = totals.keys.sorted(by: sortKey)
        for type in sorted {
            let count = totals[type] ?? 0
            let rate = rateSuffix(for: type, count: count, totalCommands: options.totalCommands)
            lines.append("  \(type)  \(count)\(rate)")
        }
    }

    // MARK: - Verbose

    private static func renderVerbose(
        rows: [SessionDatabase.EventCountRow],
        scope: String,
        into lines: inout [String],
        options: Options
    ) {
        guard !rows.isEmpty else { return }
        if lines.count > 1 { lines.append("") }
        lines.append("  [\(scope)]")
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short

        let sorted = rows.sorted { a, b in sortKey(a.eventType, b.eventType) }
        for r in sorted {
            let rate = rateSuffix(for: r.eventType, count: r.count, totalCommands: options.totalCommands)
            let projectLabel: String
            if scope == "project" && !r.projectRoot.isEmpty {
                // Cavoukian: redact.
                projectLabel = "  project=\(ProjectSecurity.redactPath(r.projectRoot))"
            } else {
                projectLabel = ""
            }
            lines.append("    \(r.eventType)  count=\(r.count)\(rate)  last=\(df.string(from: r.lastSeenAt))\(projectLabel)")
        }
    }

    // MARK: - Helpers

    /// `security.*` first, `retention.*` second, then alphabetical.
    private static func sortKey(_ a: String, _ b: String) -> Bool {
        func group(_ s: String) -> Int {
            if s.hasPrefix("security.") { return 0 }
            if s.hasPrefix("retention.") { return 1 }
            if s.hasPrefix("schema.") { return 2 }
            return 3
        }
        let ga = group(a), gb = group(b)
        if ga != gb { return ga < gb }
        return a < b
    }

    /// Gelman: for `security.*` events, attach a rate when a denominator
    /// exists. No rate for `retention.*` / `schema.*` — those aren't per-
    /// command ratios.
    private static func rateSuffix(for eventType: String, count: Int, totalCommands: Int?) -> String {
        guard eventType.hasPrefix("security."),
              let total = totalCommands, total > 0 else {
            return ""
        }
        let pct = Double(count) / Double(total) * 100
        return "  (\(count)/\(total) = \(String(format: "%.2f", pct))%)"
    }
}
