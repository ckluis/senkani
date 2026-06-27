import Testing
import Foundation
@testable import HookRelay

/// Read-side summarizer for `hook-relay-drop-log-doctor-surface-2026-06-22`.
///
/// `HookRelayDropSummary.summarize` rolls the carve-1 drop log
/// (`<iso8601>\t<reason>\t<hook_event_name>` per line) into the rollup the
/// `senkani doctor` surface renders. These tests pin the parse contract:
/// malformed-line tolerance, the 24h recent window with an injected `now`,
/// unparseable-timestamp handling, and the absent-file → all-zero load.
@Suite("HookRelay drop summary (doctor surface)")
struct HookRelayDropSummaryTests {

    /// Fixed clock so window math is deterministic. `now` is the reference
    /// "present"; window timestamps are built relative to it.
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Bare (no-fractional-seconds) ISO-8601, matching what the writer emits.
    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - empty / whitespace

    @Test("empty contents → all-zero summary")
    func emptyContents() {
        let s = HookRelayDropSummary.summarize(contents: "", now: Self.now)
        #expect(s == HookRelayDropSummary.empty)
        #expect(s.total == 0)
        #expect(s.preToolUseReadTimeouts == 0)
        #expect(s.failClosedFires == 0)
    }

    @Test("whitespace-only contents → all-zero summary")
    func whitespaceContents() {
        let s = HookRelayDropSummary.summarize(contents: "   \n\n  \t \n", now: Self.now)
        #expect(s == HookRelayDropSummary.empty)
        #expect(s.total == 0)
        #expect(s.recentTotal == 0)
    }

    // MARK: - well-formed mixed fixture

    @Test("mixed-reason fixture → correct totals, by-reason, by-event, derived counts")
    func mixedFixture() {
        let ts = Self.iso(Self.now)
        let contents = [
            "\(ts)\tread_timeout\tPreToolUse",
            "\(ts)\tread_timeout\tPreToolUse",
            "\(ts)\tread_timeout_failclosed_ask\tPreToolUse",
            "\(ts)\tconnect_timeout\tPostToolUse",
            "\(ts)\tread_timeout\tPostToolUse",
        ].joined(separator: "\n")

        let s = HookRelayDropSummary.summarize(contents: contents, now: Self.now)

        #expect(s.total == 5)
        #expect(s.byReason["read_timeout"] == 3)
        #expect(s.byReason["read_timeout_failclosed_ask"] == 1)
        #expect(s.byReason["connect_timeout"] == 1)
        #expect(s.byHookEvent["PreToolUse"] == 3)
        #expect(s.byHookEvent["PostToolUse"] == 2)
        // PreToolUse read_timeout ONLY (excludes the PreToolUse failclosed_ask
        // and the PostToolUse read_timeout).
        #expect(s.preToolUseReadTimeouts == 2)
        #expect(s.failClosedFires == 1)
    }

    // MARK: - malformed lines are skipped, not fatal

    @Test("malformed lines (no tabs / 2 fields) are SKIPPED; neighbors still counted")
    func malformedSkipped() {
        let ts = Self.iso(Self.now)
        let contents = [
            "\(ts)\tread_timeout\tPreToolUse",   // well-formed
            "this line has no tabs at all",       // malformed → skip
            "\(ts)\tread_timeout",                // only 2 fields → skip
            "\(ts)\tconnect_timeout\tPostToolUse", // well-formed
        ].joined(separator: "\n")

        let s = HookRelayDropSummary.summarize(contents: contents, now: Self.now)

        // Only the two well-formed lines count — the malformed ones did not
        // abort the parse.
        #expect(s.total == 2)
        #expect(s.byReason["read_timeout"] == 1)
        #expect(s.byReason["connect_timeout"] == 1)
        #expect(s.preToolUseReadTimeouts == 1)
    }

    @Test("a line with ≥3 fields plus extra trailing tab-fields still parses on the first 3")
    func extraFieldsTolerated() {
        let ts = Self.iso(Self.now)
        let contents = "\(ts)\tread_timeout\tPreToolUse\textra\tfields"
        let s = HookRelayDropSummary.summarize(contents: contents, now: Self.now)
        #expect(s.total == 1)
        #expect(s.byReason["read_timeout"] == 1)
        #expect(s.byHookEvent["PreToolUse"] == 1)
        #expect(s.preToolUseReadTimeouts == 1)
    }

    // MARK: - 24h recent window

    @Test("recent window counts only rows within recentWindow of now; unparseable counts all-time only")
    func recentWindow() {
        // One row 1h ago (recent), one row 48h ago (outside the 24h window),
        // one row with an unparseable timestamp (all-time only).
        let recentTs = Self.iso(Self.now.addingTimeInterval(-3_600))      // -1h
        let oldTs = Self.iso(Self.now.addingTimeInterval(-48 * 3_600))    // -48h
        let contents = [
            "\(recentTs)\tread_timeout\tPreToolUse",
            "\(oldTs)\tread_timeout\tPreToolUse",
            "not-a-timestamp\tconnect_timeout\tPostToolUse",
        ].joined(separator: "\n")

        let s = HookRelayDropSummary.summarize(contents: contents, now: Self.now)

        // All three count all-time.
        #expect(s.total == 3)
        #expect(s.byReason["read_timeout"] == 2)
        #expect(s.byReason["connect_timeout"] == 1)

        // Only the -1h row is in the 24h window. The -48h row parses but is
        // outside; the unparseable row is excluded from recent regardless.
        #expect(s.recentTotal == 1)
        #expect(s.recentByReason["read_timeout"] == 1)
        #expect(s.recentByReason["connect_timeout"] == nil)
    }

    @Test("a row exactly at the window boundary is included (<=)")
    func windowBoundaryInclusive() {
        let boundaryTs = Self.iso(Self.now.addingTimeInterval(-86_400)) // exactly 24h ago
        let contents = "\(boundaryTs)\tread_timeout\tPreToolUse"
        let s = HookRelayDropSummary.summarize(contents: contents, now: Self.now)
        #expect(s.recentTotal == 1)
    }

    @Test("fractional-seconds ISO-8601 timestamps still parse into the window")
    func fractionalSecondsParse() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fracTs = f.string(from: Self.now.addingTimeInterval(-60)) // -1m
        let contents = "\(fracTs)\tread_timeout\tPreToolUse"
        let s = HookRelayDropSummary.summarize(contents: contents, now: Self.now)
        #expect(s.total == 1)
        #expect(s.recentTotal == 1)
    }

    // MARK: - load() on a missing file

    @Test("load on a non-existent path → all-zero summary (no throw)")
    func loadMissingFile() {
        let missing = NSTemporaryDirectory() + "senkani-no-such-drop-log-\(UUID().uuidString).log"
        let s = HookRelayDropSummary.load(path: missing, now: Self.now)
        #expect(s == HookRelayDropSummary.empty)
        #expect(s.total == 0)
    }

    @Test("load on a real file round-trips through summarize")
    func loadRealFile() throws {
        let ts = Self.iso(Self.now)
        let path = NSTemporaryDirectory() + "senkani-drop-summary-\(UUID().uuidString).log"
        let contents = [
            "\(ts)\tread_timeout\tPreToolUse",
            "\(ts)\tconnect_timeout\tPostToolUse",
        ].joined(separator: "\n") + "\n"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let s = HookRelayDropSummary.load(path: path, now: Self.now)
        #expect(s.total == 2)
        #expect(s.preToolUseReadTimeouts == 1)
        #expect(s.recentTotal == 2)
    }

    @Test("defaultDropLogPath() surfaces the writer's path without loosening it")
    func defaultPathAccessor() {
        let p = HookRelayDropSummary.defaultDropLogPath()
        #expect(p.hasSuffix("/.senkani/hook-relay-drops.log"))
    }
}
