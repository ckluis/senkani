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

    public init(api: MonitorReadOnlyAPI, appVersion: String = "0.4.0", initialRowCount: Int = 0) {
        self.guardedAPI = TUIReadOnlyGuard(api: api)
        self.appVersion = appVersion
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

    /// Production entry point — drives the event loop until exit.
    /// Each iteration reads one byte from stdin (already in raw mode
    /// by the caller's `Termios.withRawMode`), dispatches, re-renders.
    public func run(stdin: FileHandle = FileHandle.standardInput, stdout: FileHandle = FileHandle.standardOutput) throws {
        let initialFrame = try buildFrame()
        try writeFrameANSI(initialFrame, to: stdout)
        while !state.shouldExit {
            let data = stdin.availableData
            if data.isEmpty { break } // EOF
            for byte in data {
                let changed = handleKey(byte)
                if changed {
                    let frame = try buildFrame()
                    try writeFrameANSI(frame, to: stdout)
                }
                if state.shouldExit { break }
            }
        }
    }

    private func writeFrameANSI(_ frame: RenderFrame, to fh: FileHandle) throws {
        if let data = frame.toANSI().data(using: .utf8) {
            try fh.write(contentsOf: data)
        }
    }
}
