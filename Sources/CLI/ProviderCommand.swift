import ArgumentParser
import Core
import Foundation

/// V.17b-1 — `senkani provider <refresh|list>`. Operator-facing surface
/// for the provider-health snapshot core. Populated from LOCAL signals
/// only (the provider's own `--version` CLI subcommand + local auth
/// state); NO network call is made (Russell no-network invariant).
struct Provider: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provider",
        abstract: "Inspect and refresh provider health snapshots (V.17b-1).",
        subcommands: [Refresh.self, List.self]
    )

    /// `senkani provider refresh <provider_id>` — re-probe the provider's
    /// LOCAL CLI (`<binary> --version`, no shell, no network) and upsert
    /// the snapshot.
    struct Refresh: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Re-probe a provider's local CLI and upsert its health snapshot (no network)."
        )

        @Argument(help: "Provider id (codex / claude_code / gemini / opencode).")
        var providerID: String

        func run() async throws {
            let db = SessionDatabase.shared
            let probe = ProviderHealthProbe.production()
            let snapshot = probe.snapshot(providerID: providerID)
            db.providerHealthSnapshotStore.upsert(snapshot)

            let staleness = snapshot.staleness()
            let installed = snapshot.cliInstalled ? "installed" : "not-installed"
            var line = "provider '\(providerID)': \(installed)"
            if let v = snapshot.version { line += ", version=\(v)" }
            line += ", auth=\(snapshot.authState.rawValue), staleness=\(staleness.rawValue)"
            print(line)
            if let hint = snapshot.remediationHint {
                FileHandle.standardError.write(Data("hint: \(hint)\n".utf8))
            }
        }
    }

    /// `senkani provider list` — print every snapshot, most-stale first.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List all provider health snapshots (oldest-refresh first)."
        )

        func run() async throws {
            let db = SessionDatabase.shared
            let snapshots = db.providerHealthSnapshotStore.readAll()
            print("provider_id | cli | version | auth | staleness | last_refresh")
            if snapshots.isEmpty {
                print("(no snapshots — run `senkani provider refresh <id>`)")
                return
            }
            let now = Date()
            let fmt = ISO8601DateFormatter()
            for s in snapshots {
                let cli = s.cliInstalled ? "yes" : "no"
                let version = s.version ?? "-"
                print("\(s.providerID) | \(cli) | \(version) | \(s.authState.rawValue) | \(s.staleness(now: now).rawValue) | \(fmt.string(from: s.lastRefresh))")
            }
        }
    }
}
