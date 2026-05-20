import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import Core
@testable import MonitorTUI

// MARK: - Stubs

/// Mutable stub `MonitorReadOnlyAPI` with call counters. Used by the
/// refresh test to assert `r` re-invokes the read methods.
private final class CountingAPI: MonitorReadOnlyAPI, @unchecked Sendable {
    var snapshotCalls = 0
    var savingsCalls = 0
    var projectCalls = 0
    var projects: [MonitorProjectRow]

    init(projects: [MonitorProjectRow] = []) {
        self.projects = projects
    }

    func fetchPaneSnapshot() throws -> PaneRefreshCoordinator.Snapshot {
        snapshotCalls += 1
        return PaneRefreshCoordinator.Snapshot(
            budgetBurn: PaneRefreshState(),
            validationQueue: PaneRefreshState(),
            repoDirtyState: PaneRefreshState()
        )
    }
    func fetchFeatureSavings() throws -> [SessionDatabase.FeatureSavings] {
        savingsCalls += 1
        return []
    }
    func fetchProjectRows() throws -> [MonitorProjectRow] {
        projectCalls += 1
        return projects
    }
}

private func makeRows(_ names: [String]) -> [MonitorProjectRow] {
    return names.map { name in
        MonitorProjectRow(
            name: name,
            path: "/p/\(name)",
            todayCostSaved: 0,
            monthCostSaved: 0,
            savingsPercent: 0,
            topOptimization: "-",
            savedTokensMonth: 0
        )
    }
}

// MARK: - (1) Keystroke routing

@Suite("MonitorTUI — keystroke routing")
struct MonitorTUIKeystrokeRoutingSuite {
    @Test func qSetsShouldExit() {
        let runner = MonitorTUIRunner(api: CountingAPI(), initialRowCount: 3)
        let changed = runner.handleKey(0x71) // 'q'
        #expect(changed)
        #expect(runner.state.shouldExit)
    }

    @Test func slashEntersFilterMode() {
        let runner = MonitorTUIRunner(api: CountingAPI(), initialRowCount: 3)
        let changed = runner.handleKey(0x2F) // '/'
        #expect(changed)
        if case .filtering(let buf) = runner.state.mode {
            #expect(buf.isEmpty)
        } else {
            Issue.record("expected .filtering mode after '/'")
        }
    }

    @Test func unknownByteIsIgnored() {
        let runner = MonitorTUIRunner(api: CountingAPI(), initialRowCount: 3)
        let changed = runner.handleKey(0x7A) // 'z'
        #expect(!changed)
        #expect(!runner.state.shouldExit)
    }
}

// MARK: - (2) j/k cursor nav with clamping

@Suite("MonitorTUI — cursor nav clamps")
struct MonitorTUICursorNavSuite {
    @Test func jMovesDownAndClampsAtLastRow() {
        let runner = MonitorTUIRunner(api: CountingAPI(), initialRowCount: 3)
        _ = runner.handleKey(0x6A) // j
        #expect(runner.state.cursor == 1)
        _ = runner.handleKey(0x6A)
        #expect(runner.state.cursor == 2)
        let changed = runner.handleKey(0x6A) // would go to 3 but clamps
        #expect(!changed)
        #expect(runner.state.cursor == 2)
    }

    @Test func kMovesUpAndClampsAtZero() {
        let runner = MonitorTUIRunner(api: CountingAPI(), initialRowCount: 3)
        _ = runner.handleKey(0x6A); _ = runner.handleKey(0x6A) // cursor = 2
        _ = runner.handleKey(0x6B) // k → 1
        #expect(runner.state.cursor == 1)
        _ = runner.handleKey(0x6B) // k → 0
        #expect(runner.state.cursor == 0)
        let changed = runner.handleKey(0x6B) // would go to -1 but clamps
        #expect(!changed)
        #expect(runner.state.cursor == 0)
    }

    @Test func navDoesNothingOnEmptyTable() {
        let runner = MonitorTUIRunner(api: CountingAPI(), initialRowCount: 0)
        let down = runner.handleKey(0x6A)
        let up = runner.handleKey(0x6B)
        #expect(!down)
        #expect(!up)
        #expect(runner.state.cursor == 0)
    }
}

// MARK: - (3) r force-refresh

@Suite("MonitorTUI — force refresh")
struct MonitorTUIForceRefreshSuite {
    @Test func rReinvokesReadMethods() {
        let api = CountingAPI()
        let runner = MonitorTUIRunner(api: api)
        #expect(api.snapshotCalls == 0)
        let changed = runner.handleKey(0x72) // 'r'
        #expect(changed)
        #expect(api.snapshotCalls == 1)
        #expect(api.savingsCalls == 1)
        #expect(api.projectCalls == 1)
        #expect(runner.state.refreshCount == 1)
    }
}

// MARK: - (4) Filter prompt

@Suite("MonitorTUI — filter prompt")
struct MonitorTUIFilterPromptSuite {
    @Test func slashFooEnterFiltersTable() throws {
        let rows = makeRows(["alpha", "beta", "foo-service", "foozy"])
        let api = CountingAPI(projects: rows)
        let runner = MonitorTUIRunner(api: api)
        // Prime rowCount by building a frame once.
        _ = try runner.buildFrame()
        #expect(runner.state.rowCount == 4)
        // /foo<Enter>
        _ = runner.handleKey(0x2F) // /
        _ = runner.handleKey(UInt8(ascii: "f"))
        _ = runner.handleKey(UInt8(ascii: "o"))
        _ = runner.handleKey(UInt8(ascii: "o"))
        let commit = runner.handleKey(0x0A) // Enter (LF)
        #expect(commit)
        #expect(runner.state.filter == "foo")
        if case .normal = runner.state.mode {} else { Issue.record("expected normal mode after Enter") }
        // Re-render to apply filter.
        _ = try runner.buildFrame()
        #expect(runner.state.rowCount == 2) // foo-service + foozy
    }

    @Test func escapeMidFilterReturnsToNormalKeepingPriorFilter() throws {
        let api = CountingAPI(projects: makeRows(["a", "b"]))
        let runner = MonitorTUIRunner(api: api)
        _ = runner.handleKey(0x2F) // /
        _ = runner.handleKey(UInt8(ascii: "z"))
        _ = runner.handleKey(0x1B) // ESC cancels
        if case .normal = runner.state.mode {} else {
            Issue.record("expected normal mode after Esc")
        }
        #expect(runner.state.filter == "") // never committed
    }

    @Test func backspaceShortensFilterBuffer() {
        let runner = MonitorTUIRunner(api: CountingAPI())
        _ = runner.handleKey(0x2F)
        _ = runner.handleKey(UInt8(ascii: "f"))
        _ = runner.handleKey(UInt8(ascii: "x"))
        _ = runner.handleKey(0x7F) // DEL
        if case .filtering(let buf) = runner.state.mode {
            #expect(buf == "f")
        } else {
            Issue.record("expected filter buffer 'f'")
        }
    }
}

// MARK: - (5) TUIReadOnlyGuard violation handling

@Suite("MonitorTUI — TUIReadOnlyGuard")
struct MonitorTUIReadOnlyGuardSuite {
    /// Leaky stub that conforms to MonitorReadOnlyAPI and also
    /// exposes a write method via extension. The guard's surface
    /// does NOT expose the leaked method — verifying this compiles
    /// is itself the structural assertion.
    private struct LeakyAPI: MonitorReadOnlyAPI {
        func fetchPaneSnapshot() throws -> PaneRefreshCoordinator.Snapshot {
            return PaneRefreshCoordinator.Snapshot(
                budgetBurn: PaneRefreshState(),
                validationQueue: PaneRefreshState(),
                repoDirtyState: PaneRefreshState()
            )
        }
        func fetchFeatureSavings() throws -> [SessionDatabase.FeatureSavings] { [] }
        func fetchProjectRows() throws -> [MonitorProjectRow] { [] }
    }

    @Test func guardReadOnlyPassthroughCompiles() throws {
        let g = TUIReadOnlyGuard(api: LeakyAPI())
        _ = try g.snapshot()
        _ = try g.featureSavings()
        _ = try g.projectRows()
        // No syntactic surface to call a write — that's the structural guarantee.
        #expect(!g.shouldAbortKeystrokeLoop)
    }

    @Test func recordViolationAbortsAndDiagnosticContainsMethodName() {
        let g = TUIReadOnlyGuard(api: LeakyAPI())
        g.recordViolation("recordTokenEvent")
        #expect(g.shouldAbortKeystrokeLoop)
        #expect(g.violations.contains("recordTokenEvent"))
        #expect(g.diagnostic.contains("recordTokenEvent"))
        #expect(g.diagnostic.contains("TUIReadOnlyGuard"))
    }

    @Test func runnerShouldExitWhenGuardAborts() {
        let runner = MonitorTUIRunner(api: LeakyAPI(), initialRowCount: 3)
        runner.guardedAPI.recordViolation("forgedWrite")
        // Next keystroke (any key) must signal exit because the guard aborted.
        let changed = runner.handleKey(0x6A) // j
        #expect(changed)
        #expect(runner.state.shouldExit)
    }
}

// MARK: - (6) RenderFrame.diff seam (V.15b stub)

@Suite("MonitorTUI — RenderFrame.diff seam")
struct MonitorTUIRenderFrameDiffSuite {
    @Test func diffReturnsNoopForV15aStub() {
        let r1 = Region(id: "header", lines: ["a"])
        let r2 = Region(id: "header", lines: ["b"])
        let f1 = RenderFrame(regions: [r1])
        let f2 = RenderFrame(regions: [r2])
        let delta = f2.diff(against: f1)
        #expect(delta == ANSIDelta.noop)
        #expect(delta.payload.isEmpty)
    }
}

// MARK: - (7) Termios.withRawMode call sequence (mocked provider)

@Suite("MonitorTUI — Termios.withRawMode")
struct MonitorTUITermiosSuite {
    @Test func recordingProviderCapturesRawApplyAndRestore() {
        let provider = RecordingTermiosProvider()
        provider.pretendIsTTY = true
        var ran = false
        Termios.withRawMode(fd: 7, provider: provider, installSignalHandlers: false) {
            ran = true
        }
        #expect(ran)
        // Expected sequence: isTTY → get → set(raw) → set(restore).
        #expect(provider.calls.contains(.isTTY(fd: 7)))
        #expect(provider.calls.contains(.get(fd: 7)))
        let setCalls = provider.calls.compactMap { call -> Bool? in
            if case .set(_, let isRaw) = call { return isRaw }
            return nil
        }
        #expect(setCalls.count >= 2)
        #expect(setCalls.first == true)  // first set applies raw
        #expect(setCalls.last == false)  // last set restores cooked
    }

    @Test func withRawModeNoOpsWhenNotATTY() {
        let provider = RecordingTermiosProvider()
        provider.pretendIsTTY = false
        var ran = false
        Termios.withRawMode(fd: 9, provider: provider, installSignalHandlers: false) {
            ran = true
        }
        #expect(ran)
        // Only the isTTY probe should have been called; no get/set.
        #expect(provider.calls == [.isTTY(fd: 9)])
    }
}

// MARK: - (8) CLI integration — subprocess exit on EOF

@Suite("MonitorTUI — CLI integration (interactive)")
struct MonitorTUIInteractiveCLISuite {
    @Test func monitorTuiExitsCleanlyOnStdinEOF() throws {
        let binary = senkaniBinaryURL()
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["monitor", "--tui"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        // Close stdin so the runner sees EOF and exits cleanly.
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func monitorTuiExitsOnQKeystroke() throws {
        let binary = senkaniBinaryURL()
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["monitor", "--tui"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        stdinPipe.fileHandleForWriting.write("q".data(using: .ascii)!)
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func monitorSingleFrameStillEmitsAnsi() throws {
        let binary = senkaniBinaryURL()
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["monitor", "--single-frame"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        try process.run()
        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("\u{1B}[2J"))
        #expect(s.contains("READ-ONLY"))
    }

    private func senkaniBinaryURL() -> URL {
        let bundleURL = Bundle(for: BundleMarker.self).bundleURL
        var dir = bundleURL.deletingLastPathComponent()
        if !FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("senkani").path) {
            dir = dir.deletingLastPathComponent()
        }
        return dir.appendingPathComponent("senkani")
    }
}

private final class BundleMarker {}
