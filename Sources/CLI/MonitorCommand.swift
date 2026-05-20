import ArgumentParser
import Foundation
import Core
import MonitorTUI

/// `senkani monitor [--tui]` — operator dashboard in a terminal.
///
/// V.15a-1 substrate: `--tui` prints a single full-frame ANSI render
/// to stdout and exits. No raw mode, no event loop, no signal
/// handlers — those land in V.15a-2.
///
/// Non-`--tui` invocation prints `"use --tui"` and exits 0.
struct Monitor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Read-only operator dashboard. Pass --tui for a single ANSI render."
    )

    @Flag(name: .long, help: "Render the dashboard as ANSI text to stdout and exit.")
    var tui = false

    @Option(name: .long, help: "App version string shown in the header bar.")
    var appVersion: String = "0.3.0"

    func run() throws {
        guard tui else {
            print("use --tui")
            return
        }

        let database = SessionDatabase.shared
        let adapter = MonitorReadOnlyAdapter(
            database: database,
            paneStateStore: nil,
            paneStateProjectRoot: FileManager.default.currentDirectoryPath,
            projects: []
        )
        let frame = try DashboardRender.buildFrame(
            appVersion: appVersion,
            api: adapter
        )
        print(frame.toANSI())
    }
}
