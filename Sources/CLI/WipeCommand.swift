import ArgumentParser
import Foundation

/// C4 (Cavoukian privacy pass 2026-04-16): user-facing data wipe. Without
/// this, deleting the session DB required knowing the obscure Application
/// Support path — not a discoverable affordance for a privacy-conscious
/// user. `senkani wipe --yes` removes:
///   - The session DB (~/Library/Application Support/Senkani/senkani.db),
///     plus its -wal / -shm sidecars.
///   - Any stale schema lockfile from a failed migration.
///   - The socket-auth token file at ~/.senkani/.token.
///
/// Safety rails (per Jobs): the destructive action requires an explicit
/// `--yes` flag. Running `senkani wipe` without it prints what would be
/// deleted and exits. Running with `--yes` deletes and reports.
struct Wipe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wipe",
        abstract: "Delete session DB + auth token. Destructive — requires --yes."
    )

    @Flag(name: .long, help: "Confirm the destructive action. Required for actual deletion.")
    var yes: Bool = false

    @Flag(name: .long, help: "Also delete the ~/.senkani directory (skill files, pane state).")
    var includeConfig: Bool = false

    mutating func run() throws {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let senkaniAppSupport = appSupport.appendingPathComponent("Senkani", isDirectory: true)
        let home = NSHomeDirectory()

        // Collect everything we'd delete, in deterministic order.
        var victims: [String] = []
        let dbRoot = senkaniAppSupport.appendingPathComponent("senkani.db").path
        for suffix in ["", "-wal", "-shm", ".schema.lock", ".migrating"] {
            let p = dbRoot + suffix
            if fm.fileExists(atPath: p) { victims.append(p) }
        }
        let tokenPath = home + "/.senkani/.token"
        if fm.fileExists(atPath: tokenPath) { victims.append(tokenPath) }
        if includeConfig {
            let cfgDir = home + "/.senkani"
            if fm.fileExists(atPath: cfgDir) { victims.append(cfgDir) }
        }

        print("senkani wipe — will delete \(victims.count) item\(victims.count == 1 ? "" : "s"):")
        for v in victims {
            print("  \(v)")
        }

        guard yes else {
            print("")
            print("DRY RUN — nothing deleted. Re-run with --yes to confirm.")
            return
        }

        var deleted = 0
        var failures: [String] = []
        for v in victims {
            do {
                try fm.removeItem(atPath: v)
                deleted += 1
            } catch {
                failures.append("\(v): \(error.localizedDescription)")
            }
        }

        print("")
        print("Deleted \(deleted) / \(victims.count).")
        if !failures.isEmpty {
            print("Failures:")
            for f in failures { print("  \(f)") }
            throw ExitCode.failure
        }
    }
}
