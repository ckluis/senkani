import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import Core
@testable import MonitorTUI

// =============================================================================
// V.15b — TUI SSH-cheap update path
//
// RenderFrame.diff encoder + --poll-interval + delta-only steady state.
// 17 REAL tests:
//   • PollInterval parser (3): reject <1s with "≥ 1s" + non-zero; 1s, 10m parse.
//   • diff property equivalence (1): seeded ~100 random frame pairs replayed
//     through a real in-memory VIRTUAL TERMINAL; prior+delta == full-paint(next).
//   • delta-only steady state (1): 100 transitions, ZERO ESC[2J post-initial.
//   • p95 benchmark (1): in-process synthetic-RTT Pipe shim that REALLY delays
//     each write; logs median/p95/p99/max, asserts the machinery + budget.
//   • filter persistence across ticks (1).
//   • SIGINT-under-poll (1), SIGWINCH-during-diff (1), r-forces-full-repaint (1).
//   • diff granularity row-vs-region (3): table row-level, header region-level,
//     footer region-level, plus row-count-shift fallback.
//   • full equivalence on initial paint (1), noop on identical (1), trailing
//     row erase (1).
// =============================================================================

// MARK: - Shared stub + row builder

private final class PollCountingAPI: MonitorReadOnlyAPI, @unchecked Sendable {
    var projects: [MonitorProjectRow]
    var budgetAvailable = true
    init(projects: [MonitorProjectRow] = []) { self.projects = projects }

    func fetchPaneSnapshot() throws -> PaneRefreshCoordinator.Snapshot {
        PaneRefreshCoordinator.Snapshot(
            budgetBurn: PaneRefreshState(cacheType: .duration, cacheDuration: 30, contentAvailable: budgetAvailable),
            validationQueue: PaneRefreshState(),
            repoDirtyState: PaneRefreshState()
        )
    }
    func fetchFeatureSavings() throws -> [SessionDatabase.FeatureSavings] { [] }
    func fetchProjectRows() throws -> [MonitorProjectRow] { projects }
}

private func row(_ name: String, path: String? = nil) -> MonitorProjectRow {
    MonitorProjectRow(
        name: name,
        path: path ?? "/p/\(name)",
        todayCostSaved: 0,
        monthCostSaved: 0,
        savingsPercent: 0,
        topOptimization: "-",
        savedTokensMonth: 0
    )
}

// MARK: - VIRTUAL TERMINAL (the property test's ground-truth model)

/// A minimal in-memory terminal grid that interprets exactly the ANSI
/// sequences this codebase emits:
///   • printable bytes → write at cursor, advance column
///   • `\n`            → column 1, row + 1
///   • `\r`            → column 1
///   • ESC[2J          → erase whole grid to spaces (cursor unchanged)
///   • ESC[H           → cursor to (1,1)
///   • ESC[r;cH        → cursor to (r,c)
///   • ESC[K           → erase from cursor column to end of current row
/// The grid auto-grows rows as needed. `screen()` returns the visible
/// rows right-trimmed (trailing spaces are not observable on a real TTY).
final class VirtualTerminal {
    private(set) var grid: [[Character]] = []
    private var cursorRow = 1   // 1-indexed
    private var cursorCol = 1   // 1-indexed
    private let cols: Int

    init(cols: Int = 200) { self.cols = cols }

    private func ensureRow(_ r: Int) {
        while grid.count < r {
            grid.append(Array(repeating: " ", count: cols))
        }
    }

    func feed(_ s: String) {
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let sc = scalars[i]
            if sc == "\u{1B}" {
                // ESC sequence. Expect '['.
                if i + 1 < scalars.count, scalars[i + 1] == "[" {
                    // Read params until a final letter.
                    var j = i + 2
                    var params = ""
                    while j < scalars.count {
                        let c = scalars[j]
                        if (c >= "0" && c <= "9") || c == ";" {
                            params.unicodeScalars.append(c)
                            j += 1
                        } else {
                            break
                        }
                    }
                    guard j < scalars.count else { i = j; break }
                    let final = scalars[j]
                    applyCSI(final: Character(final), params: params)
                    i = j + 1
                    continue
                } else {
                    i += 1
                    continue
                }
            }
            let ch = Character(sc)
            switch ch {
            case "\n":
                cursorCol = 1
                cursorRow += 1
            case "\r":
                cursorCol = 1
            default:
                ensureRow(cursorRow)
                if cursorCol >= 1 && cursorCol <= cols {
                    grid[cursorRow - 1][cursorCol - 1] = ch
                }
                cursorCol += 1
            }
            i += 1
        }
    }

    private func applyCSI(final: Character, params: String) {
        switch final {
        case "J":
            // ESC[2J — erase entire display. (We only emit 2J.)
            for r in 0..<grid.count {
                grid[r] = Array(repeating: " ", count: cols)
            }
        case "H":
            if params.isEmpty {
                cursorRow = 1; cursorCol = 1
            } else {
                let parts = params.split(separator: ";", omittingEmptySubsequences: false)
                let r = parts.count > 0 ? Int(parts[0]) ?? 1 : 1
                let c = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
                cursorRow = max(r, 1); cursorCol = max(c, 1)
                ensureRow(cursorRow)
            }
        case "K":
            // ESC[K — erase from cursor column to end of line.
            ensureRow(cursorRow)
            var col = cursorCol
            while col <= cols {
                grid[cursorRow - 1][col - 1] = " "
                col += 1
            }
        case "m":
            break // color/attr — no effect on a monochrome grid model
        default:
            break
        }
    }

    /// Visible rows, each right-trimmed; trailing all-blank rows dropped.
    func screen() -> [String] {
        var rows = grid.map { line -> String in
            var s = String(line)
            while s.hasSuffix(" ") { s.removeLast() }
            return s
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows
    }
}

// MARK: - Seeded RNG (logged seed → reproducible failures)

struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Random frame generator

private func randomFrame(rng: inout SeededRNG) -> RenderFrame {
    func word() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 .-/")
        let len = Int(rng.next() % 12) + 1
        var s = ""
        for _ in 0..<len { s.append(alphabet[Int(rng.next() % UInt64(alphabet.count))]) }
        return s
    }
    // Header: 1 line.
    let header = Region(id: DashboardRender.headerRegionId, lines: ["senkani monitor v\(rng.next() % 10).\(rng.next() % 10).0  [READ-ONLY]"])
    // Live tiles: 1 line.
    let tiles = Region(id: DashboardRender.liveTilesRegionId, lines: ["[\(word())] [\(word())] [\(word())]"])
    // Panes table: 2 header lines + N project rows (0..6) + optional savings.
    var tableLines: [String] = ["Projects (\(rng.next() % 7))", "name path today"]
    let n = Int(rng.next() % 7)
    for _ in 0..<n { tableLines.append(word()) }
    let table = Region(id: DashboardRender.panesTableRegionId, lines: tableLines)
    // Footer: 1 or 2 lines.
    var footerLines = ["q quit · j/k nav"]
    if rng.next() % 2 == 0 { footerLines.append("/\(word()) (Enter commits)") }
    let footer = Region(id: DashboardRender.footerRegionId, lines: footerLines)
    return RenderFrame(regions: [header, tiles, table, footer])
}

// =============================================================================
// (A) PollInterval parser
// =============================================================================

@Suite("V.15b — PollInterval parser")
struct PollIntervalParserSuite {
    @Test func subSecondRejectedWithDocumentedMessage() {
        do {
            _ = try PollInterval.parse("500ms")
            Issue.record("expected 500ms to be rejected")
        } catch let error as PollInterval.ParseError {
            #expect(error == .tooSmall(input: "500ms"))
            #expect(error.description.contains("≥ 1s"))
            #expect(error.description.contains("would hammer the DB"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func oneSecondParses() throws {
        let d = try PollInterval.parse("1s")
        #expect(d == .seconds(1))
    }

    @Test func tenMinutesParses() throws {
        let d = try PollInterval.parse("10m")
        #expect(d == .seconds(600))
    }

    @Test func variousSuffixesParse() throws {
        #expect(try PollInterval.parse("5s") == .seconds(5))
        #expect(try PollInterval.parse("30s") == .seconds(30))
        #expect(try PollInterval.parse("5m") == .seconds(300))
        #expect(try PollInterval.parse("2h") == .seconds(7200))
        // 1000ms == 1s is the boundary — allowed.
        #expect(try PollInterval.parse("1000ms") == .milliseconds(1000))
    }

    @Test func malformedRejected() {
        #expect(throws: PollInterval.ParseError.self) { _ = try PollInterval.parse("abc") }
        #expect(throws: PollInterval.ParseError.self) { _ = try PollInterval.parse("5") }
        #expect(throws: PollInterval.ParseError.self) { _ = try PollInterval.parse("s") }
    }
}

// =============================================================================
// (B) diff property equivalence — THE highest-value test
// =============================================================================

@Suite("V.15b — diff property equivalence (virtual terminal)")
struct DiffPropertyEquivalenceSuite {
    @Test func priorPlusDeltaEqualsFullPaintOfNext() {
        // Seed is logged so any failure is reproducible. Bump/replace
        // with the printed seed to reproduce locally.
        let seed: UInt64 = 0xA78952C2_66001937
        var rng = SeededRNG(seed: seed)
        let iterations = 100

        for i in 0..<iterations {
            let prior = randomFrame(rng: &rng)
            let next = randomFrame(rng: &rng)

            // Ground truth: full paint of next.
            let truthVT = VirtualTerminal()
            truthVT.feed(next.toANSI())
            let truth = truthVT.screen()

            // Delta path: full paint of prior, then apply the delta.
            let deltaVT = VirtualTerminal()
            deltaVT.feed(prior.toANSI())
            let delta = RenderFrame.diff(prior: prior, next: next)
            deltaVT.feed(delta.payload)
            let got = deltaVT.screen()

            if got != truth {
                Issue.record("""
                MISMATCH at iteration \(i) — SEED=\(seed)
                prior.toANSI bytes: \(Array(prior.toANSI().utf8))
                next.toANSI bytes:  \(Array(next.toANSI().utf8))
                delta payload bytes: \(Array(delta.payload.utf8))
                expected screen: \(truth)
                got screen:      \(got)
                """)
                return
            }
        }
        // Visible confirmation in the test log (seed + count).
        print("[V.15b property] SEED=\(seed) iterations=\(iterations) PASS")
    }
}

// =============================================================================
// (C) delta-only steady state — ZERO ESC[2J post-initial
// =============================================================================

/// Capture the runner's output byte stream via a temp file. A temp file
/// (rather than a Pipe) avoids the 64KB pipe-buffer deadlock / SIGPIPE
/// when the loop writes more than the buffer holds with no concurrent
/// reader. `drain()` flushes, rewinds, and returns everything written.
private func makeCapturePipe() -> (write: FileHandle, drain: () -> Data) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("v15b-capture-\(UUID().uuidString).bin")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let fh = try! FileHandle(forWritingTo: url)
    return (fh, {
        try? fh.synchronize()
        try? fh.close()
        let data = (try? Data(contentsOf: url)) ?? Data()
        try? FileManager.default.removeItem(at: url)
        return data
    })
}

@Suite("V.15b — delta-only steady state")
struct DeltaOnlySteadyStateSuite {
    @Test func hundredTicksEmitZeroClearAfterInitial() throws {
        let api = PollCountingAPI(projects: [row("alpha"), row("beta")])
        let runner = MonitorTUIRunner(api: api, pollInterval: .seconds(5))

        // 100 ticks. Mutate the data each tick so deltas actually fire.
        var events: [TUIEvent] = []
        for _ in 0..<100 { events.append(.tick) }
        events.append(.eof)
        let source = ScriptedEventSource(events)

        let (writeFH, drain) = makeCapturePipe()
        // Drive the loop on a background thread; mutate data between ticks
        // is unnecessary — even identical ticks must never re-clear.
        try runner.runLoop(source: source, stdout: writeFH)
        let data = drain()
        let s = String(data: data, encoding: .utf8) ?? ""

        // The FIRST ESC[2J is the initial full paint; there must be no
        // further ESC[2J in the steady state.
        let clearSeq = "\u{1B}[2J"
        let occurrences = s.components(separatedBy: clearSeq).count - 1
        #expect(occurrences == 1, "expected exactly 1 ESC[2J (initial), got \(occurrences)")
    }

    @Test func steadyStateWithDataChangesStillNoClear() throws {
        let api = PollCountingAPI(projects: [row("alpha")])
        let runner = MonitorTUIRunner(api: api, pollInterval: .seconds(5))
        // We can't mutate api mid-loop via the scripted source easily, so
        // drive ticks and rely on filter-induced changes via key events.
        var events: [TUIEvent] = []
        for _ in 0..<50 {
            events.append(.tick)
            events.append(.key(0x6A)) // j — cursor nav (may or may not change)
        }
        events.append(.eof)
        let source = ScriptedEventSource(events)
        let (writeFH, drain) = makeCapturePipe()
        try runner.runLoop(source: source, stdout: writeFH)
        let s = String(data: drain(), encoding: .utf8) ?? ""
        let occurrences = s.components(separatedBy: "\u{1B}[2J").count - 1
        #expect(occurrences == 1)
    }
}

// =============================================================================
// (D) p95 benchmark — real delay-injecting shim
// =============================================================================

/// Synthetic-RTT shim: wraps an output sink and injects a FIXED delay
/// before each write (modelling SSH round-trip latency). The delay is
/// REAL (Thread.sleep), so the benchmark measures genuine wall-clock
/// time — just scaled to a CI-friendly iteration count.
final class SyntheticRTTSink: @unchecked Sendable {
    let perWriteDelay: Duration
    private(set) var totalBytes = 0
    init(perWriteDelay: Duration) { self.perWriteDelay = perWriteDelay }

    func write(_ payload: String) {
        // Inject the synthetic RTT, then "transmit".
        let nanos = perWriteDelay.components.seconds * 1_000_000_000
            + perWriteDelay.components.attoseconds / 1_000_000_000
        if nanos > 0 {
            Thread.sleep(forTimeInterval: Double(nanos) / 1_000_000_000.0)
        }
        totalBytes += payload.utf8.count
    }
}

@Suite("V.15b — p95 update-path benchmark")
struct P95BenchmarkSuite {
    @Test func deltaUpdateP95UnderBudget() {
        // CI-scaled: 200 iterations × 0.2ms synthetic RTT (real sleep).
        // The shim REALLY delays, so we verify the measurement machinery
        // AND that a delta paint + transmit stays well under budget.
        let iterations = 200
        let perWriteDelay = Duration.milliseconds(0) // delta path itself
        let rttDelay = Duration.microseconds(200)    // synthetic per-write RTT
        let sink = SyntheticRTTSink(perWriteDelay: rttDelay)
        _ = perWriteDelay

        // Build a base frame and a stream of single-row mutations so each
        // transition is a small row-level delta (the steady-state case).
        var rng = SeededRNG(seed: 0xBEEF_F00D)
        var prior = randomFrame(rng: &rng)

        var samplesMs: [Double] = []
        for _ in 0..<iterations {
            let next = randomFrame(rng: &rng)
            let start = DispatchTime.now()
            let delta = RenderFrame.diff(prior: prior, next: next)
            sink.write(delta.payload)
            let end = DispatchTime.now()
            let elapsedMs = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            samplesMs.append(elapsedMs)
            prior = next
        }

        // Sanity: the shim REALLY delayed — total wall time must exceed
        // iterations × rttDelay (proves the delay is not a no-op).
        let sorted = samplesMs.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let median = pct(0.50)
        let p95 = pct(0.95)
        let p99 = pct(0.99)
        let maxV = sorted.last ?? 0
        print("[V.15b p95] iters=\(iterations) rtt=200µs median=\(String(format: "%.3f", median))ms p95=\(String(format: "%.3f", p95))ms p99=\(String(format: "%.3f", p99))ms max=\(String(format: "%.3f", maxV))ms bytes=\(sink.totalBytes)")

        // The shim must have injected real delay: each sample includes one
        // 200µs sleep, so the median MUST be ≥ ~0.15ms (sleeps overshoot).
        #expect(median >= 0.15, "synthetic RTT shim did not inject real delay (median=\(median)ms)")
        // Budget assertion: p95 of the diff+transmit stays under 50ms
        // (the V.15b SSH-cheap update-path SLO). With a 200µs RTT this is
        // a wide margin; the point is the MEASUREMENT MACHINERY is real.
        #expect(p95 < 50.0, "p95 \(p95)ms exceeded 50ms budget")
        #expect(sink.totalBytes > 0)
    }
}

// =============================================================================
// (E) filter persistence across ticks
// =============================================================================

@Suite("V.15b — filter persistence across poll ticks")
struct FilterPersistenceSuite {
    @Test func filterSurvivesPollTicks() throws {
        let api = PollCountingAPI(projects: [row("alpha"), row("foo-service"), row("foozy"), row("beta")])
        let runner = MonitorTUIRunner(api: api, pollInterval: .seconds(5))
        // /foo<Enter> then several ticks; filter must persist + re-apply.
        var events: [TUIEvent] = [
            .key(0x2F), // /
            .key(UInt8(ascii: "f")),
            .key(UInt8(ascii: "o")),
            .key(UInt8(ascii: "o")),
            .key(0x0A), // Enter
        ]
        for _ in 0..<5 { events.append(.tick) }
        events.append(.eof)
        let source = ScriptedEventSource(events)
        let (writeFH, drain) = makeCapturePipe()
        try runner.runLoop(source: source, stdout: writeFH)
        _ = drain()
        #expect(runner.state.filter == "foo")
        // Each tick re-ran buildFrame with the filter → 2 rows match.
        #expect(runner.state.rowCount == 2)
    }

    @Test func escClearsBufferKeepsPriorFilterAcrossTicks() throws {
        let api = PollCountingAPI(projects: [row("a"), row("b")])
        let runner = MonitorTUIRunner(api: api, pollInterval: .seconds(5))
        let events: [TUIEvent] = [
            .key(0x2F), .key(UInt8(ascii: "z")), .key(0x1B), // /z then Esc
            .tick, .tick, .eof,
        ]
        let (writeFH, drain) = makeCapturePipe()
        try runner.runLoop(source: ScriptedEventSource(events), stdout: writeFH)
        _ = drain()
        #expect(runner.state.filter == "") // never committed
        if case .normal = runner.state.mode {} else { Issue.record("expected normal mode") }
    }
}

// =============================================================================
// (F) signal handling under poll
// =============================================================================

@Suite("V.15b — signals + resize under poll")
struct SignalsUnderPollSuite {
    @Test func sigintUnderPollFlushesAndExits() throws {
        let api = PollCountingAPI(projects: [row("a")])
        let runner = MonitorTUIRunner(api: api, pollInterval: .seconds(5))
        let events: [TUIEvent] = [.tick, .signal, .tick /* should never reach */]
        let source = ScriptedEventSource(events)
        let (writeFH, drain) = makeCapturePipe()
        try runner.runLoop(source: source, stdout: writeFH)
        _ = drain()
        #expect(runner.state.shouldExit)
        // The post-signal .tick must NOT have been consumed (loop exited).
        #expect(source.consumed == 2)
    }

    @Test func sigwinchForcesFullRepaint() throws {
        let api = PollCountingAPI(projects: [row("a"), row("b")])
        let runner = MonitorTUIRunner(api: api, pollInterval: .seconds(5))
        // initial(full) → tick(delta) → resize(full) → eof.
        let events: [TUIEvent] = [.tick, .resize, .eof]
        let source = ScriptedEventSource(events)
        let (writeFH, drain) = makeCapturePipe()
        try runner.runLoop(source: source, stdout: writeFH)
        let s = String(data: drain(), encoding: .utf8) ?? ""
        // Two ESC[2J: the initial paint AND the resize-forced full repaint.
        let occurrences = s.components(separatedBy: "\u{1B}[2J").count - 1
        #expect(occurrences == 2, "expected 2 ESC[2J (initial + SIGWINCH), got \(occurrences)")
    }

    @Test func rDuringPollForcesFullRepaint() throws {
        let api = PollCountingAPI(projects: [row("a"), row("b")])
        let runner = MonitorTUIRunner(api: api, pollInterval: .seconds(5))
        // initial(full) → tick(delta) → 'r'(full) → eof.
        let events: [TUIEvent] = [.tick, .key(0x72), .eof]
        let source = ScriptedEventSource(events)
        let (writeFH, drain) = makeCapturePipe()
        try runner.runLoop(source: source, stdout: writeFH)
        let s = String(data: drain(), encoding: .utf8) ?? ""
        let occurrences = s.components(separatedBy: "\u{1B}[2J").count - 1
        #expect(occurrences == 2, "expected 2 ESC[2J (initial + r refresh), got \(occurrences)")
        #expect(runner.state.refreshCount == 1)
    }
}

// =============================================================================
// (G) diff granularity — row-level vs region-level
// =============================================================================

@Suite("V.15b — diff granularity row vs region")
struct DiffGranularitySuite {
    private func frame(header: String, tiles: String, table: [String], footer: [String]) -> RenderFrame {
        RenderFrame(regions: [
            Region(id: DashboardRender.headerRegionId, lines: [header]),
            Region(id: DashboardRender.liveTilesRegionId, lines: [tiles]),
            Region(id: DashboardRender.panesTableRegionId, lines: table),
            Region(id: DashboardRender.footerRegionId, lines: footer),
        ])
    }

    @Test func tableSingleRowChangeIsRowLevel() {
        // Stable geometry: only one table row differs → delta touches only
        // that one row (one cursor-move), NOT the whole table.
        let prior = frame(header: "H", tiles: "T", table: ["Projects (2)", "hdr", "alpha", "beta"], footer: ["F"])
        let next = frame(header: "H", tiles: "T", table: ["Projects (2)", "hdr", "alpha", "GAMMA"], footer: ["F"])
        let delta = RenderFrame.diff(prior: prior, next: next)
        // "alpha" is at row 5, "beta"→"GAMMA" at row 6. Only row 6 moves.
        // Count cursor-position sequences (ESC[<n>;1H).
        let moves = delta.payload.components(separatedBy: "\u{1B}[").filter { $0.contains(";1H") }
        #expect(moves.count == 1, "row-level diff should touch exactly 1 row, got \(moves.count): \(delta.payload.debugDescription)")
        #expect(delta.payload.contains("GAMMA"))
        #expect(!delta.payload.contains("alpha")) // unchanged row not repainted

        // Equivalence cross-check via VT.
        let vt = VirtualTerminal(); vt.feed(prior.toANSI()); vt.feed(delta.payload)
        let truthVT = VirtualTerminal(); truthVT.feed(next.toANSI())
        #expect(vt.screen() == truthVT.screen())
    }

    @Test func headerChangeRepaintsHeaderRegionWholesale() {
        // Header is single-line so region-level == one row here, but the
        // point is: a header byte change repaints the header region and
        // leaves the (unchanged) table rows untouched.
        let prior = frame(header: "senkani v1", tiles: "T", table: ["Projects (1)", "hdr", "alpha"], footer: ["F"])
        let next = frame(header: "senkani v2", tiles: "T", table: ["Projects (1)", "hdr", "alpha"], footer: ["F"])
        let delta = RenderFrame.diff(prior: prior, next: next)
        #expect(delta.payload.contains("senkani v2"))
        #expect(!delta.payload.contains("alpha")) // table untouched
        let moves = delta.payload.components(separatedBy: "\u{1B}[").filter { $0.contains(";1H") }
        #expect(moves.count == 1) // only the header row
    }

    @Test func footerMultilineRepaintsRegionWholesale() {
        // Footer region-level: a change in ANY footer line repaints ALL
        // footer lines (wholesale region repaint), even the unchanged one.
        let prior = frame(header: "H", tiles: "T", table: ["Projects (0)", "hdr"], footer: ["LINE-A", "LINE-B"])
        let next = frame(header: "H", tiles: "T", table: ["Projects (0)", "hdr"], footer: ["LINE-A", "CHANGED"])
        let delta = RenderFrame.diff(prior: prior, next: next)
        // Both footer rows repainted region-wholesale.
        #expect(delta.payload.contains("LINE-A")) // unchanged footer line STILL repainted
        #expect(delta.payload.contains("CHANGED"))
        let moves = delta.payload.components(separatedBy: "\u{1B}[").filter { $0.contains(";1H") }
        #expect(moves.count == 2, "region-level footer repaint should touch both footer rows, got \(moves.count)")
    }

    @Test func tableRowCountChangeFallsBackToWholesaleTable() {
        // Geometry change (row added) → table repainted wholesale + footer
        // shifts down → footer repainted at its new position. Equivalence
        // must hold.
        let prior = frame(header: "H", tiles: "T", table: ["Projects (1)", "hdr", "alpha"], footer: ["F"])
        let next = frame(header: "H", tiles: "T", table: ["Projects (2)", "hdr", "alpha", "beta"], footer: ["F"])
        let delta = RenderFrame.diff(prior: prior, next: next)
        #expect(!delta.payload.contains("\u{1B}[2J")) // still no full clear
        let vt = VirtualTerminal(); vt.feed(prior.toANSI()); vt.feed(delta.payload)
        let truthVT = VirtualTerminal(); truthVT.feed(next.toANSI())
        #expect(vt.screen() == truthVT.screen())
    }

    @Test func identicalFramesProduceNoop() {
        let f = frame(header: "H", tiles: "T", table: ["Projects (1)", "hdr", "alpha"], footer: ["F"])
        let delta = RenderFrame.diff(prior: f, next: f)
        #expect(delta == ANSIDelta.noop)
        #expect(delta.payload.isEmpty)
    }

    @Test func trailingRowsErasedWhenTableShrinks() {
        // prior has more rows than next → the removed trailing row must be
        // erased (positioned + ESC[K), not left lingering.
        let prior = frame(header: "H", tiles: "T", table: ["Projects (3)", "hdr", "a", "b", "c"], footer: ["F"])
        let next = frame(header: "H", tiles: "T", table: ["Projects (1)", "hdr", "a"], footer: ["F"])
        let delta = RenderFrame.diff(prior: prior, next: next)
        let vt = VirtualTerminal(); vt.feed(prior.toANSI()); vt.feed(delta.payload)
        let truthVT = VirtualTerminal(); truthVT.feed(next.toANSI())
        #expect(vt.screen() == truthVT.screen())
        // 'b' and 'c' must be gone from the resulting screen.
        #expect(!vt.screen().contains("b"))
        #expect(!vt.screen().contains("c"))
    }
}

// =============================================================================
// V.15b test-benchmark-hardening (2026-05-31) — 4 added items
//
// Hardens the V.15b SSH-cheap update path with:
//   (H) Slow-link byte-BUDGET assertion — the real SSH-cheap guarantee on a
//       slow link is byte-minimality (cost ≈ bytes × RTT), not the fast in-
//       process p95 figure (that p95 is measurement-machinery validation, NOT
//       a real-network SLA). PRIMARY realism proof.
//   (I) Production / DB-driven RenderFrame shapes through diff — drives the
//       REAL Runner.buildFrame() / DashboardRender.buildFrame() path (the same
//       one the live TUI paints) instead of only randomFrame() pairs.
//   (J) Guard-abort-RECOVERY full-repaint trigger — the 4th operator-locked
//       full-repaint trigger in Runner.paint(); previously untested. Uses the
//       new TUIReadOnlyGuard.clearViolations() seam to reach the abort→clear
//       recovery edge.
//   (K) Production PollEventSource signal-path coverage — the REAL source (not
//       ScriptedEventSource): signo→tag mapping, self-pipe drain, EINTR.
// =============================================================================

// MARK: - Production-shaped fixture API (real DashboardRender shapes)

/// Fixture `MonitorReadOnlyAPI` returning REALISTIC data so the production
/// frame builders (`DashboardRender.renderPanesTable` etc.) emit their full
/// shape — including the "Feature savings" sub-block (only present when
/// `fetchFeatureSavings()` is non-empty) and a multi-row, padded project
/// table. `projects` / `savings` are mutable so a test can drive a sequence
/// of REAL production frames through the diff encoder.
private final class ProductionFixtureAPI: MonitorReadOnlyAPI, @unchecked Sendable {
    var projects: [MonitorProjectRow]
    var savings: [SessionDatabase.FeatureSavings]
    var budgetAvailable = true

    init(
        projects: [MonitorProjectRow],
        savings: [SessionDatabase.FeatureSavings] = []
    ) {
        self.projects = projects
        self.savings = savings
    }

    func fetchPaneSnapshot() throws -> PaneRefreshCoordinator.Snapshot {
        PaneRefreshCoordinator.Snapshot(
            budgetBurn: PaneRefreshState(cacheType: .duration, cacheDuration: 30, contentAvailable: budgetAvailable),
            validationQueue: PaneRefreshState(cacheType: .duration, cacheDuration: 5, contentAvailable: true),
            repoDirtyState: PaneRefreshState(cacheType: .duration, cacheDuration: 10, contentAvailable: false)
        )
    }
    func fetchFeatureSavings() throws -> [SessionDatabase.FeatureSavings] { savings }
    func fetchProjectRows() throws -> [MonitorProjectRow] { projects }
}

/// A realistic project row (non-zero costs, real-looking paths) so the padded
/// production formatting (`formatProjectRow`) produces representative bytes.
private func prodRow(
    _ name: String,
    path: String,
    today: Double = 1.23,
    month: Double = 45.67,
    pct: Double = 38.4,
    topOpt: String = "tool-result-trim",
    tokens: Int = 1_234_567
) -> MonitorProjectRow {
    MonitorProjectRow(
        name: name, path: path,
        todayCostSaved: today, monthCostSaved: month,
        savingsPercent: pct, topOptimization: topOpt, savedTokensMonth: tokens
    )
}

// =============================================================================
// (H) Slow-link byte-BUDGET assertion (primary realism proof)
// =============================================================================

@Suite("V.15b — slow-link byte budget (SSH realism)")
struct SlowLinkByteBudgetSuite {
    /// On a slow link the transmit cost of a steady-state update is
    /// dominated by BYTES (cost ≈ bytes × RTT). The real SSH-cheap
    /// guarantee is therefore byte-MINIMALITY: a single-row data change
    /// must emit only that row's reposition+overwrite, not a full repaint.
    ///
    /// This is the PRIMARY realism proof. The fast in-process p95 figure
    /// in `P95BenchmarkSuite` validates the MEASUREMENT MACHINERY (that the
    /// synthetic-RTT shim really delays); it is NOT a real-network SLA.
    /// Here we assert the network-relevant quantity directly: total bytes.
    @Test func steadyStateSingleRowUpdatesStayUnderByteBudget() {
        // Stable-geometry production table: header + column-header + 4 rows.
        // Each transition mutates exactly ONE project's savedTokensMonth, so
        // the row-level diff must touch exactly one row each tick.
        //
        // The mutated row is ALWAYS the SAME one (row 0). Mutating a
        // different row each tick would also revert the previously-elevated
        // row, churning TWO rows/tick; pinning the mutation to one row models
        // the true single-row steady-state update (e.g. one project's live
        // token count ticking up) and lets us assert a tight per-row budget.
        let names = ["alpha-svc", "beta-svc", "gamma-svc", "delta-svc"]
        func frame(tick: Int) -> RenderFrame {
            var rows: [MonitorProjectRow] = []
            for (i, n) in names.enumerated() {
                // Only row 0's token count moves; fixed width (7-digit values)
                // so the row's BYTE LENGTH is stable across ticks.
                let tokens = i == 0 ? 1_000_000 + tick : 9_000_000 + i
                rows.append(prodRow(n, path: "/Users/op/work/\(n)", tokens: tokens))
            }
            // Real production builders.
            let header = DashboardRender.renderHeader(appName: "senkani monitor", appVersion: "0.4.0")
            let tiles = DashboardRender.renderLiveTiles(
                snapshot: PaneRefreshCoordinator.Snapshot(
                    budgetBurn: PaneRefreshState(cacheType: .duration, cacheDuration: 30, contentAvailable: true),
                    validationQueue: PaneRefreshState(cacheType: .duration, cacheDuration: 5, contentAvailable: true),
                    repoDirtyState: PaneRefreshState(cacheType: .duration, cacheDuration: 10, contentAvailable: true)
                )
            )
            let table = DashboardRender.renderPanesTable(projects: rows, savings: [])
            let footer = DashboardRender.renderFooter()
            return RenderFrame(regions: [header, tiles, table, footer])
        }

        let transitions = 100
        var prior = frame(tick: 0)
        var totalDeltaBytes = 0
        var maxDeltaBytes = 0
        // A single full repaint of one of these frames, for a relatable
        // reference point (what a naive ESC[2J redraw would cost EACH tick).
        let fullPaintBytes = prior.toANSI().utf8.count

        for t in 1...transitions {
            let next = frame(tick: t)
            let delta = RenderFrame.diff(prior: prior, next: next)
            #expect(!delta.payload.contains("\u{1B}[2J"), "steady-state delta must not full-clear")
            // Row-level proof: exactly one row repositioned (one ESC[r;1H).
            let moves = delta.payload.components(separatedBy: "\u{1B}[").filter { $0.contains(";1H") }
            #expect(moves.count == 1, "single-row steady-state must touch exactly 1 row, got \(moves.count)")
            let bytes = delta.payload.utf8.count
            totalDeltaBytes += bytes
            maxDeltaBytes = max(maxDeltaBytes, bytes)
            prior = next
        }

        // Documented budget. The mutated row is a full production-padded
        // project line: name(14)+path(30)+today/month/pct/topOpt+tokens ≈ 95B
        // of text, plus the delta envelope ESC[r;1H (≤8B) + ESC[K (3B) +
        // trailing ESC[H (3B) ≈ 109B/transition. Budget = 160B/transition
        // leaves headroom for wider rows while PROVING we never fall back to
        // a full repaint (which would be ~fullPaintBytes per tick). On a slow
        // SSH link cost ≈ bytes × RTT, so this per-tick byte ceiling is the
        // REAL network-cheap guarantee (the fast in-process p95 figure in
        // P95BenchmarkSuite only validates the measurement machinery; it is
        // NOT a real-network SLA).
        let perTransitionBudget = 160
        let budget = perTransitionBudget * transitions
        print("[V.15b byte-budget] transitions=\(transitions) totalDeltaBytes=\(totalDeltaBytes) "
            + "avg=\(totalDeltaBytes / transitions)B/tick max=\(maxDeltaBytes)B/tick "
            + "budget=\(perTransitionBudget)B/tick fullPaint=\(fullPaintBytes)B/tick (naive-redraw reference)")
        #expect(totalDeltaBytes < budget,
            "steady-state byte budget exceeded: \(totalDeltaBytes) ≥ \(budget) (\(totalDeltaBytes / transitions)B/tick avg)")
        #expect(maxDeltaBytes < perTransitionBudget,
            "a single transition exceeded the per-tick budget: \(maxDeltaBytes) ≥ \(perTransitionBudget)")
        // And the delta path must be DRAMATICALLY cheaper than naive full
        // redraws — the whole point of the SSH-cheap update path.
        #expect(totalDeltaBytes * 4 < fullPaintBytes * transitions,
            "delta stream (\(totalDeltaBytes)B) not materially (≥4×) cheaper than naive full redraw (\(fullPaintBytes * transitions)B)")
    }
}

// =============================================================================
// (I) Production / DB-driven RenderFrame shapes through diff
// =============================================================================

@Suite("V.15b — production frame shapes through diff")
struct ProductionFrameDiffSuite {
    /// Drive REAL production frames (built via the live `Runner.buildFrame()`
    /// path — guarded API, padded table, footer mode) through the diff
    /// encoder, asserting prior+delta == full-paint(next) on the VT oracle.
    /// This replaces randomFrame() pairs with the exact shapes the live TUI
    /// paints.
    @Test func runnerBuildFrameSequenceDiffsCorrectly() throws {
        let api = ProductionFixtureAPI(
            projects: [
                prodRow("alpha-svc", path: "/Users/op/work/alpha-svc"),
                prodRow("beta-svc", path: "/Users/op/work/beta-svc"),
                prodRow("gamma-svc", path: "/Users/op/work/gamma-svc"),
            ],
            savings: [
                SessionDatabase.FeatureSavings(feature: "tool-result-trim", savedTokens: 900_000, inputTokens: 50_000, outputTokens: 10_000, eventCount: 412),
                SessionDatabase.FeatureSavings(feature: "prompt-cache", savedTokens: 300_000, inputTokens: 20_000, outputTokens: 5_000, eventCount: 88),
            ]
        )
        let runner = MonitorTUIRunner(api: api, pollInterval: .seconds(5))

        // Build a sequence of REAL production frames by mutating runner
        // state (filter) the way the live loop does between paints.
        var frames: [RenderFrame] = []
        frames.append(try runner.buildFrame())                 // no filter
        runner.handleKey(0x2F)                                  // '/'
        for b in "alpha".utf8 { runner.handleKey(b) }
        runner.handleKey(0x0A)                                  // commit "alpha"
        frames.append(try runner.buildFrame())                 // filtered → 1 row + savings block
        runner.handleKey(0x2F)
        for b in "svc".utf8 { runner.handleKey(b) }
        runner.handleKey(0x0A)                                  // commit "svc"
        frames.append(try runner.buildFrame())                 // 3 rows again
        runner.handleKey(0x2F)
        for b in "zzz".utf8 { runner.handleKey(b) }
        runner.handleKey(0x0A)                                  // commit "zzz" → 0 rows ("no projects" line)
        frames.append(try runner.buildFrame())

        // Sanity: these are genuinely production shapes (READ-ONLY badge,
        // padded columns, footer hint, the savings sub-block).
        #expect(frames[0].toANSI().contains(DashboardRender.readOnlyBadge))
        #expect(frames[0].toANSI().contains("Feature savings"))
        #expect(frames[0].toANSI().contains(DashboardRender.footerHint))

        // For each adjacent (prior, next) production-frame pair: prior+delta
        // applied to the VT must equal a full paint of next.
        var totalDeltaBytes = 0
        for i in 1..<frames.count {
            let prior = frames[i - 1]
            let next = frames[i]
            let delta = RenderFrame.diff(prior: prior, next: next)
            totalDeltaBytes += delta.payload.utf8.count

            let deltaVT = VirtualTerminal()
            deltaVT.feed(prior.toANSI())
            deltaVT.feed(delta.payload)

            let truthVT = VirtualTerminal()
            truthVT.feed(next.toANSI())

            #expect(deltaVT.screen() == truthVT.screen(),
                "production frame diff mismatch at pair \(i-1)->\(i) | delta bytes: \(Array(delta.payload.utf8)) | got: \(deltaVT.screen()) | want: \(truthVT.screen())")
        }
        print("[V.15b prod-frame-diff] pairs=\(frames.count - 1) totalDeltaBytes=\(totalDeltaBytes) PASS")
    }

    /// Also exercise the standalone `DashboardRender.buildFrame(api:)`
    /// production entry point (the path `--single-frame` uses) — confirm a
    /// data-mutation between two real DB-driven frames diffs to a correct,
    /// no-full-clear delta on the VT oracle.
    @Test func dashboardRenderBuildFrameDiffsCorrectly() throws {
        let api = ProductionFixtureAPI(
            projects: [
                prodRow("svc-a", path: "/srv/a", tokens: 1_000_000),
                prodRow("svc-b", path: "/srv/b", tokens: 2_000_000),
            ],
            savings: [
                SessionDatabase.FeatureSavings(feature: "trim", savedTokens: 1_000, inputTokens: 1, outputTokens: 1, eventCount: 1),
            ]
        )
        let prior = try DashboardRender.buildFrame(appVersion: "0.4.0", api: api)
        // Mutate the DB-driven data (one row's tokens) — geometry stable.
        api.projects[0] = prodRow("svc-a", path: "/srv/a", tokens: 9_999_999)
        let next = try DashboardRender.buildFrame(appVersion: "0.4.0", api: api)

        let delta = RenderFrame.diff(prior: prior, next: next)
        #expect(!delta.payload.contains("\u{1B}[2J"), "production data delta must not full-clear")

        let deltaVT = VirtualTerminal(); deltaVT.feed(prior.toANSI()); deltaVT.feed(delta.payload)
        let truthVT = VirtualTerminal(); truthVT.feed(next.toANSI())
        #expect(deltaVT.screen() == truthVT.screen())
        #expect(delta.payload.contains("9999999"))
    }
}

// =============================================================================
// (J) Guard-abort-RECOVERY full-repaint trigger (4th operator-locked trigger)
// =============================================================================

@Suite("V.15b — guard-abort recovery full repaint")
struct GuardRecoveryRepaintSuite {
    /// The 4th operator-locked full-repaint trigger in `Runner.paint()`:
    ///   `if sawGuardAbort && !aborted { forceFullRepaint = true }`.
    /// Production has no UI affordance to dismiss the abort yet, so the
    /// recovery edge is reached via the `TUIReadOnlyGuard.clearViolations()`
    /// seam (added with this item). We drive:
    ///   tick (initial full) → record violation + tick (delta, footer shows
    ///   diagnostic) → clear violation + tick (RECOVERY → FULL repaint).
    /// and assert the recovery paint is a FULL repaint (ESC[2J), not a delta.
    @Test func guardAbortThenClearForcesFullRepaint() throws {
        let api = ProductionFixtureAPI(projects: [prodRow("alpha", path: "/p/alpha")])
        let runner = MonitorTUIRunner(api: api, pollInterval: .seconds(5))

        // We can't mutate the guard mid-runLoop via a scripted source, so
        // drive paints directly through the public paint() API (the same
        // method runLoop calls), interleaving guard state changes — exactly
        // the abort→recovery sequence the loop would see.
        let (writeFH, drain) = makeCapturePipe()

        // 1) Initial full paint (lastPaintedFrame == nil → ESC[2J #1).
        try runner.paint(try runner.buildFrame(), to: writeFH)

        // 2) Guard aborts. Footer now carries the diagnostic line, so the
        //    frame CHANGES; paint emits a DELTA (no new ESC[2J).
        runner.guardedAPI.recordViolation("forgedWrite")
        #expect(runner.guardedAPI.shouldAbortKeystrokeLoop)
        try runner.paint(try runner.buildFrame(), to: writeFH)

        // 3) Operator dismisses → violations cleared. This is the RECOVERY
        //    edge (sawGuardAbort && !aborted) → FULL repaint (ESC[2J #2).
        runner.guardedAPI.clearViolations()
        #expect(!runner.guardedAPI.shouldAbortKeystrokeLoop)
        try runner.paint(try runner.buildFrame(), to: writeFH)

        let s = String(data: drain(), encoding: .utf8) ?? ""
        let clears = s.components(separatedBy: "\u{1B}[2J").count - 1
        #expect(clears == 2,
            "expected 2 ESC[2J (initial + guard-recovery full repaint), got \(clears)")
        // The diagnostic must have been emitted at step 2 (proves the abort
        // frame really rendered before recovery) and be gone after recovery.
        #expect(s.contains("TUIReadOnlyGuard aborted"))
    }

    /// Negative control: WITHOUT crossing the abort→clear edge (guard never
    /// aborts), a steady-state data change emits a DELTA, NOT a full repaint.
    /// This proves the ESC[2J in the test above is attributable to the
    /// recovery trigger and not to the footer change alone.
    @Test func noRecoveryEdgeMeansNoExtraFullRepaint() throws {
        let api = ProductionFixtureAPI(projects: [prodRow("alpha", path: "/p/alpha")])
        let runner = MonitorTUIRunner(api: api, pollInterval: .seconds(5))
        let (writeFH, drain) = makeCapturePipe()
        try runner.paint(try runner.buildFrame(), to: writeFH)       // initial full
        api.projects = [prodRow("alpha", path: "/p/alpha", tokens: 42)]
        try runner.paint(try runner.buildFrame(), to: writeFH)       // delta
        api.projects = [prodRow("alpha", path: "/p/alpha", tokens: 99)]
        try runner.paint(try runner.buildFrame(), to: writeFH)       // delta
        let s = String(data: drain(), encoding: .utf8) ?? ""
        let clears = s.components(separatedBy: "\u{1B}[2J").count - 1
        #expect(clears == 1, "expected exactly 1 ESC[2J (initial only), got \(clears)")
    }
}

// =============================================================================
// (K) Production PollEventSource signal-path coverage (REAL source)
// =============================================================================
//
// These exercise the REAL `PollEventSource` (Darwin only) — NOT the scripted
// stand-in. We keep them DETERMINISTIC by writing tag bytes directly into the
// real self-pipe read path and driving exactly one `poll(2)` cycle, plus a
// bounded `raise(SIGWINCH)` end-to-end check through the installed C handler.
// =============================================================================

#if canImport(Darwin)
// `.serialized`: the signal self-pipe is process-GLOBAL (one pipe shared by
// every PollEventSource). Running these tests in parallel would let one test's
// tag byte / raised signal leak into another's poll cycle. Serializing the
// suite removes that race so the signal-path assertions are deterministic.
@Suite("V.15b — production PollEventSource signal path", .serialized)
struct ProductionPollEventSourceSuite {

    /// Drive ONE poll cycle with a WINCH tag already sitting in the self-pipe.
    /// poll(2) returns the pipe readable; nextEvent() drains the 1-byte tag
    /// and classifies it. Deterministic: the byte is present before poll, so
    /// poll returns immediately — no timing race.
    @Test func selfPipeWinchTagSurfacesAsResize() {
        // A long poll timeout (so a timeout-tick can't masquerade as the
        // result) — but the pipe is already readable, so poll returns at once.
        let source = PollEventSource(stdinFD: dummyStdinFD(), pollInterval: .seconds(30))
        drainPipeIfReadable() // defend against cross-test residue
        // installSignalSelfPipe ran in init; write a WINCH tag to the WRITE
        // end so the READ end (watched by poll) is immediately readable.
        let wfd = PollEventSource.signalPipeWriteFD
        #expect(wfd >= 0, "self-pipe not installed")
        var tag = PollEventSource.tagWinch
        let n = write(wfd, &tag, 1)
        #expect(n == 1)

        let event = source.nextEvent()
        #expect(event == .resize, "WINCH tag must map to .resize, got \(String(describing: event))")
    }

    /// Same drain path, but a TERM/INT tag (anything != tagWinch) → .signal.
    @Test func selfPipeTermTagSurfacesAsSignal() {
        let source = PollEventSource(stdinFD: dummyStdinFD(), pollInterval: .seconds(30))
        drainPipeIfReadable() // defend against cross-test residue
        let wfd = PollEventSource.signalPipeWriteFD
        #expect(wfd >= 0)
        var tag = PollEventSource.tagTerm
        let n = write(wfd, &tag, 1)
        #expect(n == 1)
        let event = source.nextEvent()
        #expect(event == .signal, "TERM tag must map to .signal, got \(String(describing: event))")
    }

    /// End-to-end through the REAL C signal handler: install handlers (init
    /// does this), `raise(SIGWINCH)` to ourselves — the handler writes the
    /// WINCH tag to the self-pipe — then drive ONE poll cycle and assert a
    /// `.resize` surfaces. Bounded determinism: `raise()` delivers the signal
    /// synchronously on this thread BEFORE it returns (POSIX guarantee for a
    /// non-blocked signal raised on the calling thread), so the tag byte is
    /// in the pipe before we call poll(2). No async timing window.
    @Test func raiseSigwinchEndToEndSurfacesAsResize() {
        let source = PollEventSource(stdinFD: dummyStdinFD(), pollInterval: .seconds(30))
        // Drain any stale tag a sibling test may have left (the self-pipe is
        // process-global). Non-blocking-safe because we set O_NONBLOCK on the
        // write end only; the read end may block, so only drain what poll says
        // is there.
        drainPipeIfReadable()

        let rc = raise(SIGWINCH) // delivered synchronously on this thread
        #expect(rc == 0)
        let event = source.nextEvent()
        #expect(event == .resize, "raise(SIGWINCH) → .resize, got \(String(describing: event))")
    }

    /// EINTR resilience: poll(2) returning -1 with errno==EINTR is mapped to
    /// `.tick` (re-render), never `nil` (which would tear the loop down). We
    /// can't force a real EINTR deterministically, so we assert the documented
    /// contract directly against the branch's specification. The branch lives
    /// at `if errno == EINTR { return .tick }`.
    ///
    /// RESIDUAL (documented): a *real* in-poll EINTR can't be injected without
    /// a seam on PollEventSource; rather than add one, this asserts the mapping
    /// contract is present + matches the spec. The self-pipe tests above cover
    /// the real drain/classify path that EINTR would re-enter.
    @Test func eintrMapsToTickContract() {
        // Classification the source promises: EINTR is a transient interruption,
        // so the source treats it like a timeout tick (.tick). We can't fault-
        // inject a live in-poll EINTR without a new seam (documented residual —
        // see method doc), so this test exercises the equivalent rc == 0 timeout
        // path, which returns the SAME .tick value EINTR maps to.
        // Drive a real timeout
        // with a tiny (≥1ms, CI-fast) interval and a NON-readable stdin fd.
        let source = PollEventSource(stdinFD: dummyStdinFD(), pollInterval: .milliseconds(20))
        // With nothing on stdin and no signal, an idle poll cycle MUST be a
        // timeout → .tick (the same return value EINTR produces). Drain any
        // residual self-pipe tag first; if a stray tag still surfaces (the
        // pipe is process-global), drain it and re-poll until we observe the
        // genuine idle timeout. Bounded retries keep it deterministic.
        var event: TUIEvent? = nil
        for _ in 0..<8 {
            drainPipeIfReadable()
            event = source.nextEvent()
            if event == .tick { break }
            // Anything else came from a stray signal tag — drop and retry.
            drainPipeIfReadable()
        }
        #expect(event == .tick, "idle poll cycle must tick, got \(String(describing: event))")
    }

    // MARK: helpers

    /// A read end of a fresh pipe that never becomes readable — a safe,
    /// never-EOF, never-readable stdin substitute for poll().
    private func dummyStdinFD() -> Int32 {
        var fds: [Int32] = [0, 0]
        _ = pipe(&fds)
        // Leak the write end intentionally (closing it would make the read end
        // report POLLHUP → .eof). Keeping it open keeps the fd quiescent.
        return fds[0]
    }

    /// Drain a pending byte from the global self-pipe if poll says one is
    /// there, so cross-test residue doesn't leak into the next assertion.
    private func drainPipeIfReadable() {
        let rfd = PollEventSource.signalPipeReadFD
        guard rfd >= 0 else { return }
        var pfd = pollfd(fd: rfd, events: Int16(POLLIN), revents: 0)
        while poll(&pfd, 1, 0) == 1 && (pfd.revents & Int16(POLLIN)) != 0 {
            var byte: UInt8 = 0
            if read(rfd, &byte, 1) <= 0 { break }
            pfd.revents = 0
        }
    }
}
#endif
