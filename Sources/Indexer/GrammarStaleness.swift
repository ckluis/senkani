import Foundation

/// Advisory emitted by the `senkani doctor` grammar-staleness check.
/// A grammar is "stale" when upstream has a newer version AND the vendored
/// copy has been sitting at the current version for more than a threshold
/// number of days (30 by default). The threshold keeps routine post-release
/// churn out of `doctor` so it can't false-alarm CI — see
/// `spec/tree_sitter.md:80`.
public enum GrammarStaleness {

    /// Default staleness window in days.
    public static let defaultThresholdDays = 30

    public struct StaleEntry: Sendable, Equatable {
        public let language: String
        public let vendoredVersion: String
        public let latestVersion: String
        public let daysStale: Int

        public init(language: String, vendoredVersion: String, latestVersion: String, daysStale: Int) {
            self.language = language
            self.vendoredVersion = vendoredVersion
            self.latestVersion = latestVersion
            self.daysStale = daysStale
        }
    }

    public enum Advisory: Sendable, Equatable {
        /// No cache on disk (or cache expired). Check skipped — advise the
        /// operator to run `senkani grammars check` to refresh.
        case noUpstreamData
        /// Cache present; no outdated grammars.
        case allFresh
        /// Outdated grammars exist but all were vendored within the
        /// staleness window. Reported as PASS — the upstream churn isn't
        /// worth interrupting for yet.
        case recentUpdatesAvailable(count: Int)
        /// One or more grammars exceed the staleness window. Reported
        /// non-blocking (SKIP, not FAIL) so CI stays green.
        case stale([StaleEntry])
    }

    /// Decide the advisory for the given cached results and reference date.
    /// Pure function — no I/O, no globals, no network. `today` is injected
    /// so tests can pin the date.
    public static func advise(
        cached: [GrammarCheckResult]?,
        today: Date = Date(),
        thresholdDays: Int = defaultThresholdDays
    ) -> Advisory {
        guard let cached, !cached.isEmpty else {
            return .noUpstreamData
        }

        let outdated = cached.filter { $0.isOutdated }
        guard !outdated.isEmpty else {
            return .allFresh
        }

        var stale: [StaleEntry] = []
        for result in outdated {
            guard let latest = result.latestVersion,
                  let vendored = parseVendoredDate(result.grammar.vendoredDate) else { continue }
            let days = Int(today.timeIntervalSince(vendored) / 86_400)
            if days > thresholdDays {
                stale.append(StaleEntry(
                    language: result.grammar.language,
                    vendoredVersion: result.grammar.version,
                    latestVersion: latest,
                    daysStale: days
                ))
            }
        }

        if stale.isEmpty {
            return .recentUpdatesAvailable(count: outdated.count)
        }
        return .stale(stale.sorted { $0.language < $1.language })
    }

    /// Parse `GrammarInfo.vendoredDate` (e.g. "2026-04-10") into a Date at
    /// midnight UTC. Returns nil for unparseable strings.
    static func parseVendoredDate(_ raw: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }
}
