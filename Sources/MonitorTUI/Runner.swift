import Foundation
import Core
#if canImport(Darwin)
import Darwin
#endif

/// Event-loop driver for `senkani monitor --tui`. Reads one byte at
/// a time from stdin, dispatches via the keybinding map, re-renders
/// when state changes, exits cleanly on `q` / EOF / signal.
///
/// V.15a-2 substrate. V.15b layers cheap-update delta painting on
/// top via `RenderFrame.diff(against:)`.
public final class MonitorTUIRunner {
    public enum Mode: Equatable {
        case normal
        case filtering(buffer: String)
    }

    public struct State: Equatable {
        public var cursor: Int
        public var rowCount: Int
        public var filter: String
        public var mode: Mode
        public var shouldExit: Bool
        public var refreshCount: Int

        public init(
            cursor: Int = 0,
            rowCount: Int = 0,
            filter: String = "",
            mode: Mode = .normal,
            shouldExit: Bool = false,
            refreshCount: Int = 0
        ) {
            self.cursor = cursor
            self.rowCount = rowCount
            self.filter = filter
            self.mode = mode
            self.shouldExit = shouldExit
            self.refreshCount = refreshCount
        }
    }

    public let guardedAPI: TUIReadOnlyGuard
    public private(set) var state: State
    public let appVersion: String
    public let pollInterval: Duration

    /// The frame most recently PAINTED to the terminal. `nil` before the
    /// first paint. Subsequent paints diff against this so the steady
    /// state never re-emits `ESC[2J`.
    public private(set) var lastPaintedFrame: RenderFrame?

    /// Set whenever the next paint MUST be a full clear-and-paint rather
    /// than a delta. The four operator-locked triggers: (a) initial
    /// frame [lastPaintedFrame == nil covers it], (b) `r` keystroke,
    /// (c) SIGWINCH resize, (d) TUIReadOnlyGuard recovery from a logged
    /// abort.
    private var forceFullRepaint = false

    /// True once we have observed the guard in the aborted state; used
    /// to detect the recovery edge (abort → clear) so we full-repaint
    /// when the operator dismisses the diagnostic.
    private var sawGuardAbort = false

    public init(
        api: MonitorReadOnlyAPI,
        appVersion: String = "0.4.0",
        initialRowCount: Int = 0,
        pollInterval: Duration = PollInterval.default
    ) {
        self.guardedAPI = TUIReadOnlyGuard(api: api)
        self.appVersion = appVersion
        self.pollInterval = pollInterval
        self.state = State(rowCount: initialRowCount)
    }

    /// Process one input byte. Returns true if state changed (caller
    /// should re-render).
    @discardableResult
    public func handleKey(_ byte: UInt8) -> Bool {
        if guardedAPI.shouldAbortKeystrokeLoop {
            state.shouldExit = true
            return true
        }
        switch state.mode {
        case .filtering(let buffer):
            return handleFilterByte(byte, buffer: buffer)
        case .normal:
            return handleNormalByte(byte)
        }
    }

    private func handleNormalByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x71: // 'q'
            state.shouldExit = true
            return true
        case 0x6A: // 'j'
            let next = min(state.cursor + 1, max(state.rowCount - 1, 0))
            if next != state.cursor {
                state.cursor = next
                return true
            }
            return false
        case 0x6B: // 'k'
            let next = max(state.cursor - 1, 0)
            if next != state.cursor {
                state.cursor = next
                return true
            }
            return false
        case 0x72: // 'r'
            state.refreshCount += 1
            // `r` is an operator-locked FULL-repaint trigger.
            forceFullRepaint = true
            // Force a re-query via the guard; ignore results — the
            // value of `r` is the refresh tick, not the data carry.
            _ = try? guardedAPI.snapshot()
            _ = try? guardedAPI.featureSavings()
            _ = try? guardedAPI.projectRows()
            return true
        case 0x2F: // '/'
            state.mode = .filtering(buffer: "")
            return true
        default:
            return false
        }
    }

    private func handleFilterByte(_ byte: UInt8, buffer: String) -> Bool {
        switch byte {
        case 0x0D, 0x0A: // CR / LF — commit
            state.filter = buffer
            state.mode = .normal
            state.cursor = 0
            return true
        case 0x1B: // ESC — cancel
            state.mode = .normal
            // Filter stays at its previous value (the cancel only
            // throws away the in-progress buffer).
            return true
        case 0x7F: // DEL / backspace
            var next = buffer
            if !next.isEmpty { next.removeLast() }
            state.mode = .filtering(buffer: next)
            return true
        default:
            if byte >= 0x20 && byte < 0x7F {
                let next = buffer + String(UnicodeScalar(byte))
                state.mode = .filtering(buffer: next)
                return true
            }
            return false
        }
    }

    /// Build the current `RenderFrame` from the guarded API. Cursor
    /// and filter are not yet rendered into the frame in V.15a-2 —
    /// the panes-table region rebuild already reflects the filter.
    public func buildFrame() throws -> RenderFrame {
        let snapshot = try guardedAPI.snapshot()
        let savings = try guardedAPI.featureSavings()
        var rows = try guardedAPI.projectRows()
        if !state.filter.isEmpty {
            let needle = state.filter.lowercased()
            rows = rows.filter { row in
                row.name.lowercased().contains(needle) || row.path.lowercased().contains(needle)
            }
        }
        state.rowCount = rows.count
        let header = DashboardRender.renderHeader(appName: "senkani monitor", appVersion: appVersion)
        let tiles = DashboardRender.renderLiveTiles(snapshot: snapshot)
        let table = DashboardRender.renderPanesTable(projects: rows, savings: savings)
        let footer = renderFooter()
        return RenderFrame(regions: [header, tiles, table, footer])
    }

    private func renderFooter() -> Region {
        let baseHint = DashboardRender.footerHint
        let lines: [String]
        switch state.mode {
        case .normal:
            if guardedAPI.shouldAbortKeystrokeLoop {
                lines = [guardedAPI.diagnostic, baseHint]
            } else {
                lines = [baseHint]
            }
        case .filtering(let buffer):
            lines = ["/" + buffer + " (Enter commits, Esc cancels)", baseHint]
        }
        return Region(id: DashboardRender.footerRegionId, lines: lines)
    }

    /// Production entry point — drives the poll+key event loop until
    /// exit. Builds a `PollEventSource` over the real stdin fd (poll(2)
    /// timeout = `pollInterval`, signal self-pipe for SIGWINCH /
    /// SIGINT / SIGTERM) and runs the injectable core loop.
    ///
    /// Assumes the caller has already entered raw mode via
    /// `Termios.withRawMode`.
    public func run(stdin: FileHandle = FileHandle.standardInput, stdout: FileHandle = FileHandle.standardOutput) throws {
        #if canImport(Darwin)
        let source = PollEventSource(stdinFD: stdin.fileDescriptor, pollInterval: pollInterval)
        try runLoop(source: source, stdout: stdout)
        #else
        // Non-Darwin fallback: original blocking byte loop (no poll(2)).
        let initialFrame = try buildFrame()
        try paint(initialFrame, to: stdout)
        while !state.shouldExit {
            let data = stdin.availableData
            if data.isEmpty { break }
            for byte in data {
                if handleKey(byte) { try paint(try buildFrame(), to: stdout) }
                if state.shouldExit { break }
            }
        }
        #endif
    }

    /// Injectable, TTY-free core loop. Tests drive it with a
    /// `ScriptedEventSource` (no real fds, no sleeps) so poll ticks,
    /// keys, resize, signals, and EOF are fully deterministic.
    ///
    /// Painting policy:
    ///   • First paint (lastPaintedFrame == nil) → full clear+paint.
    ///   • `r` / SIGWINCH / guard-abort recovery → full clear+paint.
    ///   • Every other re-render → `RenderFrame.diff` delta payload.
    public func runLoop(source: TUIEventSource, stdout: FileHandle) throws {
        // Initial full paint.
        let initialFrame = try buildFrame()
        try paint(initialFrame, to: stdout)

        loop: while !state.shouldExit {
            guard let event = source.nextEvent() else { break }
            switch event {
            case .eof:
                break loop

            case .signal:
                // SIGINT/SIGTERM under poll: flush a final delta of the
                // current state, then exit 0. Termios restoration is
                // owned by withRawMode's handler chain / the defer.
                let frame = try buildFrame()
                try paint(frame, to: stdout)
                state.shouldExit = true
                break loop

            case .resize:
                // SIGWINCH: discard any in-flight delta assumption and
                // emit a FULL repaint at the (new) size.
                forceFullRepaint = true
                let frame = try buildFrame()
                try paint(frame, to: stdout)

            case .tick:
                // Poll tick: re-run buildFrame (re-applies the persisted
                // filter) and emit a delta against the last paint.
                let frame = try buildFrame()
                try paint(frame, to: stdout)

            case .key(let byte):
                let changed = handleKey(byte)
                if state.shouldExit {
                    // Honor q / guard-abort exit; no trailing paint.
                    break loop
                }
                if changed {
                    let frame = try buildFrame()
                    try paint(frame, to: stdout)
                }
            }
        }
    }

    /// Paint a frame. Full clear+paint on the first frame or when a
    /// full-repaint trigger fired; otherwise emit the delta against the
    /// previously painted frame. Updates `lastPaintedFrame`.
    public func paint(_ frame: RenderFrame, to fh: FileHandle) throws {
        // Guard-abort recovery edge → force full repaint.
        let aborted = guardedAPI.shouldAbortKeystrokeLoop
        if sawGuardAbort && !aborted {
            forceFullRepaint = true
        }
        sawGuardAbort = aborted

        let payload: String
        if lastPaintedFrame == nil || forceFullRepaint {
            payload = frame.toANSI()
        } else {
            payload = RenderFrame.diff(prior: lastPaintedFrame!, next: frame).payload
        }
        forceFullRepaint = false
        lastPaintedFrame = frame
        if !payload.isEmpty, let data = payload.data(using: .utf8) {
            try fh.write(contentsOf: data)
        }
    }
}
