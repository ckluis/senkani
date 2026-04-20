import ArgumentParser
import Foundation
import Core

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove all Senkani configuration, hooks, and data."
    )

    @Flag(name: .long, help: "Skip confirmation prompt.")
    var yes = false

    @Flag(name: .long, help: "Keep session data (SQLite database and metrics). Only remove config and hooks.")
    var keepData = false

    func run() throws {
        let items = scanForArtifacts()

        if items.isEmpty {
            print("Nothing to uninstall — no Senkani artifacts found.")
            return
        }

        print("")
        print("Senkani Uninstall")
        print("=================")
        print("")
        print("The following will be removed:")
        print("")
        for item in items {
            print("  \(item.icon) \(item.description)")
        }

        if keepData {
            print("")
            print("  (--keep-data: session database and metrics will be preserved)")
        }

        print("")

        if !yes {
            print("Proceed? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Cancelled.")
                return
            }
        }

        print("")

        var removed = 0
        var failed = 0

        for item in items {
            do {
                try item.remove()
                print("  \u{2713} \(item.description)")
                removed += 1
            } catch {
                print("  \u{2717} \(item.description) — \(error.localizedDescription)")
                failed += 1
            }
        }

        print("")
        if failed == 0 {
            print("Senkani uninstalled (\(removed) items removed).")
        } else {
            print("Partially uninstalled: \(removed) removed, \(failed) failed.")
        }
        print("Restart Claude Code to complete.")
        print("")
    }

    private func scanForArtifacts() -> [UninstallArtifactScanner.Artifact] {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Senkani").path
        return UninstallArtifactScanner(
            homeDir: NSHomeDirectory(),
            appSupportDir: appSupport,
            keepData: keepData
        ).scan()
    }
}
