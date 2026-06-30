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

    // MARK: - forced-fail-open marker
    //   (hook-relay-forced-failopen-droplog-marker-2026-06-24)

    @Test("forced-fail-open rows count via forcedFailOpenFires + complete the gate-bypass tally")
    func forcedFailOpenCounts() {
        let ts = Self.iso(Self.now)
        let contents = [
            "\(ts)\tread_timeout_failopen_forced\tPreToolUse",  // new distinct reason
            "\(ts)\tread_timeout_failopen_forced\tPreToolUse",
            "\(ts)\tread_timeout\tPreToolUse",                  // LEGACY pre-marker bypass row
            "\(ts)\tread_timeout\tPostToolUse",                 // never-deny passthrough (not a bypass)
            "\(ts)\tread_timeout_failclosed_ask\tPreToolUse",   // fail-closed escalation (not a bypass)
        ].joined(separator: "\n")

        let s = HookRelayDropSummary.summarize(contents: contents, now: Self.now)

        #expect(s.byReason["read_timeout_failopen_forced"] == 2)
        #expect(s.forcedFailOpenFires == 2)
        // Legacy bypass rows (read_timeout + PreToolUse) still counted here.
        #expect(s.preToolUseReadTimeouts == 1)
        // The complete deny-capable gate-bypass tally spans both log formats:
        // 2 forced-fail-open + 1 legacy PreToolUse read_timeout = 3. The
        // never-deny read_timeout and the failclosed_ask are NOT bypasses.
        #expect(s.denyCapableBypasses == 3)
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
        // The two malformed lines are counted (so the doctor surface can tell
        // "no drops" apart from "present but unparseable").
        #expect(s.malformedLines == 2)
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

    // MARK: - re-audit hardening (D1–D4)

    @Test("a FUTURE-dated row counts all-time but NOT recent (skew/tamper must not inflate 24h)")
    func futureDatedRowExcludedFromRecent() {
        let futureTs = Self.iso(Self.now.addingTimeInterval(3_600)) // +1h
        let contents = "\(futureTs)\tread_timeout\tPreToolUse"
        let s = HookRelayDropSummary.summarize(contents: contents, now: Self.now)
        #expect(s.total == 1)
        #expect(s.recentTotal == 0, "a future-dated row must not count as recent")
    }

    @Test("all-malformed non-empty log → total 0 but malformedLines > 0 (NOT the empty/healthy state)")
    func allMalformedDistinguished() {
        let contents = [
            "garbage line one no tabs",
            "another bad line",
            "ts\tonly-two-fields",
        ].joined(separator: "\n")
        let s = HookRelayDropSummary.summarize(contents: contents, now: Self.now)
        #expect(s.total == 0)
        #expect(s.malformedLines == 3)
        #expect(s != HookRelayDropSummary.empty, "must be distinguishable from an empty log")
    }

    @Test("sanitizeForDisplay strips ANSI/control chars and caps length")
    func sanitizeStripsEscapes() {
        let crafted = "\u{1B}[2K\rPreToolUse\u{1B}[32m all clear" // ESC[2K, CR, ESC[32m
        let clean = HookRelayDropSummary.sanitizeForDisplay(crafted)
        #expect(!clean.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
        #expect(clean == "[2KPreToolUse[32m all clear") // printable kept, ESC + CR dropped
        let long = String(repeating: "x", count: 100)
        #expect(HookRelayDropSummary.sanitizeForDisplay(long, maxLength: 10).count == 11) // 10 + "…"
    }

    @Test("recordDrop strips control chars from hook_event_name at write time")
    func recordDropSanitizesWriter() throws {
        let path = NSTemporaryDirectory() + "senkani-drop-writer-\(UUID().uuidString).log"
        defer { try? FileManager.default.removeItem(atPath: path) }
        HookRelay.recordDrop(reason: "read_timeout",
                             hookEvent: "\u{1B}[2K\tPre\nToolUse",
                             at: path, now: Self.now)
        let written = try String(contentsOfFile: path, encoding: .utf8)
        // No raw ESC survived; the crafted \t / \n in the NAME became spaces, so
        // the row stays a single line with exactly 3 tab-separated fields.
        #expect(!written.unicodeScalars.contains { $0.value == 0x1B })
        let line = written.trimmingCharacters(in: .newlines)
        #expect(line.components(separatedBy: "\t").count == 3)
    }

    @Test("load tails an over-cap log: truncated set, partial first line dropped, only the tail counted")
    func loadTailsOverCapLog() throws {
        let ts = Self.iso(Self.now)
        let path = NSTemporaryDirectory() + "senkani-drop-tail-\(UUID().uuidString).log"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let lines = (0..<200).map { _ in "\(ts)\tread_timeout\tPreToolUse" }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let full = HookRelayDropSummary.load(path: path, now: Self.now)
        #expect(full.total == 200)
        #expect(full.truncated == false)

        let tailed = HookRelayDropSummary.load(path: path, now: Self.now, maxBytes: 200)
        #expect(tailed.truncated == true)
        #expect(tailed.total > 0 && tailed.total < 200, "only the tail is counted")
        #expect(tailed.malformedLines == 0, "the partial first line was dropped, not mis-counted")
    }
}
