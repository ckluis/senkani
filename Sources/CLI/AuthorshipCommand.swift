import ArgumentParser
import Foundation
import Core

/// Phase V.5c — operator-triggered bulk-tag CLI for legacy NULL rows.
///
/// `senkani authorship backfill --since YYYY-MM-DD --tag <enum>` walks
/// `knowledge_entities` rows whose `authorship` column is literally NULL
/// (legacy / pre-V.5 state) AND whose `created_at >= since`, and writes
/// the chosen tag. Cavoukian: bulk operations are operator-triggered,
/// never automatic — this CLI is the only path that bulk-writes a tag
/// without a per-row save-time choice (V.5b's prompt sheet).
///
/// The in-band `.unset` sentinel is **NEVER** overwritten — it represents
/// an explicit "I'll decide later" deferral by the operator. Backfill
/// only heals the legacy NULL state.
struct Authorship: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "authorship",
        abstract: "Manage knowledge-base authorship tags (Phase V.5).",
        subcommands: [AuthorshipBackfill.self]
    )
}

struct AuthorshipBackfill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backfill",
        abstract: "Bulk-tag legacy KB rows whose authorship column is NULL. Operator-triggered; never automatic."
    )

    @Option(name: .long, help: "Lower bound on created_at (ISO YYYY-MM-DD, UTC). Required.")
    var since: String

    @Option(name: .long, help: "Tag to write: aiAuthored | humanAuthored | mixed. The `unset` sentinel is rejected — backfill exists to record an explicit decision.")
    var tag: String

    @Flag(name: .long, help: "Confirm the write. Without --yes, prints a dry-run preview and exits.")
    var yes: Bool = false

    @Option(name: .long, help: "Project root directory (default: current).")
    var root: String?

    func run() throws {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let sinceDate = fmt.date(from: since) else {
            fputs("Invalid --since date: '\(since)'. Expected YYYY-MM-DD.\n", stderr)
            throw ExitCode(2)
        }

        guard let chosen = parseExplicitTag(tag) else {
            fputs("Invalid --tag: '\(tag)'. Expected one of: aiAuthored, humanAuthored, mixed.\n", stderr)
            throw ExitCode(2)
        }

        guard let projectRoot = resolveAuthorshipKBRoot(root) else {
            fputs("No Senkani KB found at <root>/.senkani/vault.db. Has the MCP server run in this project?\n", stderr)
            throw ExitCode(2)
        }

        let store = KnowledgeStore(projectRoot: projectRoot)
        let count = store.countNullAuthorship(since: sinceDate)

        guard count > 0 else {
            print("0 legacy rows match (created_at >= \(since), authorship IS NULL). Nothing to do.")
            return
        }

        guard yes else {
            print("Project: \(projectRoot)")
            print("Found \(count) legacy row(s) with NULL authorship created on/after \(since).")
            print("Would tag as: \(chosen.displayLabel) (\(chosen.rawValue)).")
            print("")
            print("DRY RUN — nothing written. Re-run with --yes to apply.")
            return
        }

        let result = AuthorshipBackfillRunner.run(
            store: store,
            sessionDatabase: SessionDatabase.shared,
            since: sinceDate,
            sinceLabel: since,
            tag: chosen,
            projectRoot: projectRoot
        )

        print("Tagged \(result.updated) row(s) as \(chosen.displayLabel) (\(chosen.rawValue)).")
        if let sid = result.auditSessionId {
            print("Audit-chain row recorded (commands table, session=\(sid.prefix(8))…).")
        }
    }

    /// Parse the operator-facing `--tag` string. The `unset` sentinel is
    /// deliberately not exposed — backfilling to `.unset` would defeat
    /// the point of the CLI (the operator is being asked to record an
    /// explicit decision).
    private func parseExplicitTag(_ raw: String) -> AuthorshipTag? {
        switch raw {
        case "aiAuthored":    return .aiAuthored
        case "humanAuthored": return .humanAuthored
        case "mixed":         return .mixed
        default:              return nil
        }
    }
}

/// Probe `<root>/.senkani/vault.db` and return the root only if the DB
/// file already exists. We don't want a typo'd `--root /tmp/foo` to
/// silently auto-create an empty KB just because `KnowledgeStore.init`
/// always opens (and creates) the file.
private func resolveAuthorshipKBRoot(_ explicit: String?) -> String? {
    let root = explicit ?? FileManager.default.currentDirectoryPath
    let dbPath = root + "/.senkani/vault.db"
    guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
    return root
}
