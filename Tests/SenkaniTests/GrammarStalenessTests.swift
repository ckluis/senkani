import Testing
import Foundation
@testable import Indexer

@Suite("GrammarStaleness — Advisory")
struct GrammarStalenessAdvisoryTests {

    // MARK: - Helpers

    private let swiftInfo = GrammarInfo(
        language: "swift",
        version: "0.7.1",
        repo: "alex-pinkus/tree-sitter-swift",
        vendoredDate: "2026-01-10",
        targetName: "TreeSitterSwiftParser"
    )

    private let pythonInfo = GrammarInfo(
        language: "python",
        version: "0.23.6",
        repo: "tree-sitter/tree-sitter-python",
        vendoredDate: "2026-04-01",
        targetName: "TreeSitterPythonParser"
    )

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - Core advisory cases

    @Test("offline path: nil cache → noUpstreamData")
    func offlinePathReturnsNoData() {
        let advisory = GrammarStaleness.advise(cached: nil, today: date(2026, 4, 19))
        #expect(advisory == .noUpstreamData)
    }

    @Test("empty cache → noUpstreamData (treat empty same as missing)")
    func emptyCacheReturnsNoData() {
        let advisory = GrammarStaleness.advise(cached: [], today: date(2026, 4, 19))
        #expect(advisory == .noUpstreamData)
    }

    @Test("fresh fixture: cache with no outdated grammars → allFresh")
    func freshFixtureAllUpToDate() {
        let cached = [
            GrammarCheckResult(grammar: swiftInfo, latestVersion: "0.7.1", isOutdated: false, error: nil),
            GrammarCheckResult(grammar: pythonInfo, latestVersion: "0.23.6", isOutdated: false, error: nil),
        ]
        let advisory = GrammarStaleness.advise(cached: cached, today: date(2026, 4, 19))
        #expect(advisory == .allFresh)
    }

    @Test("stale fixture: outdated grammar vendored >30 days ago → stale")
    func staleFixtureReportsDaysAndVersions() {
        // swiftInfo vendoredDate: 2026-01-10; today 2026-04-19 → 99 days.
        let cached = [
            GrammarCheckResult(grammar: swiftInfo, latestVersion: "0.8.0", isOutdated: true, error: nil),
        ]
        let advisory = GrammarStaleness.advise(cached: cached, today: date(2026, 4, 19))
        guard case let .stale(entries) = advisory else {
            Issue.record("expected .stale, got \(advisory)")
            return
        }
        #expect(entries.count == 1)
        #expect(entries[0].language == "swift")
        #expect(entries[0].vendoredVersion == "0.7.1")
        #expect(entries[0].latestVersion == "0.8.0")
        #expect(entries[0].daysStale == 99)
    }

    @Test("recent update: outdated grammar vendored <30 days ago → recentUpdatesAvailable")
    func recentUpdateWithinWindowDoesNotWarn() {
        // pythonInfo vendoredDate: 2026-04-01; today 2026-04-19 → 18 days.
        let cached = [
            GrammarCheckResult(grammar: pythonInfo, latestVersion: "0.24.0", isOutdated: true, error: nil),
        ]
        let advisory = GrammarStaleness.advise(cached: cached, today: date(2026, 4, 19))
        #expect(advisory == .recentUpdatesAvailable(count: 1))
    }

    @Test("exact 30-day boundary is NOT stale (must exceed, not equal)")
    func thirtyDayBoundaryIsNotStale() {
        // vendored 2026-03-20, today 2026-04-19 → exactly 30 days.
        let info = GrammarInfo(
            language: "rust",
            version: "0.24.2",
            repo: "tree-sitter/tree-sitter-rust",
            vendoredDate: "2026-03-20",
            targetName: "TreeSitterRustParser"
        )
        let cached = [
            GrammarCheckResult(grammar: info, latestVersion: "0.25.0", isOutdated: true, error: nil),
        ]
        let advisory = GrammarStaleness.advise(cached: cached, today: date(2026, 4, 19))
        #expect(advisory == .recentUpdatesAvailable(count: 1))
    }

    @Test("31 days = stale (first day past the boundary)")
    func thirtyOneDaysIsStale() {
        let info = GrammarInfo(
            language: "rust",
            version: "0.24.2",
            repo: "tree-sitter/tree-sitter-rust",
            vendoredDate: "2026-03-19",
            targetName: "TreeSitterRustParser"
        )
        let cached = [
            GrammarCheckResult(grammar: info, latestVersion: "0.25.0", isOutdated: true, error: nil),
        ]
        let advisory = GrammarStaleness.advise(cached: cached, today: date(2026, 4, 19))
        guard case let .stale(entries) = advisory else {
            Issue.record("expected .stale, got \(advisory)")
            return
        }
        #expect(entries.count == 1)
        #expect(entries[0].daysStale == 31)
    }

    @Test("mixed: stale and fresh in same cache → stale-only list, sorted")
    func mixedCacheListsOnlyStaleSortedByLanguage() {
        let swiftOld = GrammarInfo(
            language: "swift",
            version: "0.7.1",
            repo: "alex-pinkus/tree-sitter-swift",
            vendoredDate: "2026-02-01",
            targetName: "TreeSitterSwiftParser"
        )
        let rubyOld = GrammarInfo(
            language: "ruby",
            version: "0.23.0",
            repo: "tree-sitter/tree-sitter-ruby",
            vendoredDate: "2026-02-15",
            targetName: "TreeSitterRubyParser"
        )
        let cached = [
            GrammarCheckResult(grammar: swiftOld, latestVersion: "0.8.0", isOutdated: true, error: nil),
            GrammarCheckResult(grammar: rubyOld, latestVersion: "0.23.5", isOutdated: true, error: nil),
            GrammarCheckResult(grammar: pythonInfo, latestVersion: "0.24.0", isOutdated: true, error: nil),
        ]
        let advisory = GrammarStaleness.advise(cached: cached, today: date(2026, 4, 19))
        guard case let .stale(entries) = advisory else {
            Issue.record("expected .stale, got \(advisory)")
            return
        }
        #expect(entries.count == 2)
        #expect(entries.map(\.language) == ["ruby", "swift"],
                "entries should be sorted alphabetically by language")
    }

    @Test("outdated grammar without latestVersion is skipped (defensive)")
    func outdatedMissingLatestIsSkipped() {
        // isOutdated=true but latestVersion=nil shouldn't crash — rare
        // but possible if cache ever stored a degenerate entry.
        let cached = [
            GrammarCheckResult(grammar: swiftInfo, latestVersion: nil, isOutdated: true, error: nil),
        ]
        let advisory = GrammarStaleness.advise(cached: cached, today: date(2026, 4, 19))
        // Filter passed as outdated=1 but staleness loop skips — recent updates fallback.
        #expect(advisory == .recentUpdatesAvailable(count: 1))
    }

    @Test("custom threshold: 7-day window flags vendoredDate 10 days ago")
    func customThresholdParameter() {
        let info = GrammarInfo(
            language: "go",
            version: "0.25.0",
            repo: "tree-sitter/tree-sitter-go",
            vendoredDate: "2026-04-09",
            targetName: "TreeSitterGoParser"
        )
        let cached = [
            GrammarCheckResult(grammar: info, latestVersion: "0.26.0", isOutdated: true, error: nil),
        ]
        let advisory = GrammarStaleness.advise(
            cached: cached,
            today: date(2026, 4, 19),
            thresholdDays: 7
        )
        guard case let .stale(entries) = advisory else {
            Issue.record("expected .stale, got \(advisory)")
            return
        }
        #expect(entries.first?.daysStale == 10)
    }
}

@Suite("GrammarStaleness — Date parsing")
struct GrammarStalenessDateParsingTests {

    @Test("parses well-formed ISO date")
    func parsesIsoDate() {
        let date = GrammarStaleness.parseVendoredDate("2026-04-10")
        #expect(date != nil)
    }

    @Test("rejects malformed strings without crashing")
    func rejectsMalformed() {
        #expect(GrammarStaleness.parseVendoredDate("not-a-date") == nil)
        #expect(GrammarStaleness.parseVendoredDate("") == nil)
        #expect(GrammarStaleness.parseVendoredDate("2026-04") == nil)
        #expect(GrammarStaleness.parseVendoredDate("2026/04/10") == nil)
    }
}
