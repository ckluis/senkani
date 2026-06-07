import ArgumentParser
import Foundation
import Core
import MonitorTUI

/// `senkani monitor [--tui]` — operator dashboard in a terminal.
///
/// V.15a-2: `--tui` enters termios raw mode, runs the event loop
/// (q quit / j-k cursor nav / r refresh / `/` filter), restores
/// cooked mode on exit (including SIGINT / SIGTERM paths).
///
/// `--single-frame` (V.15a-1 substrate behavior) prints one ANSI
/// frame and exits — useful for scripts and snapshot tests.
///
/// Non-`--tui` invocation prints `"use --tui"` and exits 0.
struct Monitor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Read-only operator dashboard. Pass --tui for the interactive loop."
    )

    @Flag(name: .long, help: "Run the interactive TUI event loop (raw mode + q/j/k/r/'/' keybindings).")
    var tui = false

    @Flag(name: .long, help: "Print a single ANSI render and exit (substrate behavior).")
    var singleFrame = false

    @Option(name: .long, help: "App version string shown in the header bar.")
    var appVersion: String = "0.4.0"

    @Option(
        name: .long,
        help: "TUI poll interval (ms/s/m/h suffix, e.g. 500ms, 1s, 5s, 30s, 5m, 10m). Must be ≥ 1s. Default 5s."
    )
    var pollInterval: String = "5s"

    func run() throws {
        guard tui || singleFrame else {
            print("use --tui")
            return
        }

        // Parse + validate the poll interval up front. PollInterval's
        // errors carry the operator-facing message (incl. the "≥ 1s"
        // documented string); surface them via ValidationError so
        // ArgumentParser writes to stderr and exits non-zero.
        let interval: Duration
        do {
            interval = try PollInterval.parse(pollInterval)
        } catch let error as PollInterval.ParseError {
            throw ValidationError(error.description)
        }

        let database = SessionDatabase.shared
        let adapter = MonitorReadOnlyAdapter(
            database: database,
            paneStateStore: nil,
            paneStateProjectRoot: FileManager.default.currentDirectoryPath,
            projects: []
        )

        if singleFrame {
            let frame = try DashboardRender.buildFrame(
                appVersion: appVersion,
                api: adapter
            )
            print(frame.toANSI())
            return
        }

        let runner = MonitorTUIRunner(api: adapter, appVersion: appVersion, pollInterval: interval)
        try Termios.withRawMode {
            try runner.run()
        }
    }
}
