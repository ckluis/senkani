import ArgumentParser
import Bench
import Core
import Foundation

/// `senkani replay run --session ID --policy outline-first-strict|budget-tight`
///
/// Replays a recorded session under an alternate policy and reports
/// the delta as text or JSON. Read-only — never writes to the DB,
/// never re-executes tool calls, never modifies the project.
struct Replay: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replay",
        abstract: "Counterfactual replay of a recorded session under an alternate policy.",
        subcommands: [Run.self]
    )

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a replay against a recorded session."
        )

        @Option(name: .long, help: "Session id. Omit to use the most recent session.")
        var session: String?

        @Option(name: .long, help: "Replay preset. One of: \(ReplayPreset.allCases.map { $0.rawValue }.joined(separator: ", ")).")
        var policy: String

        @Option(name: .long, help: "For `budget-tight`: alternate session cap in cents.")
        var budgetCents: Int?

        @Option(name: .long, help: "Write the report as JSON to this path. Otherwise emits text to stdout.")
        var json: String?

        func run() throws {
            guard let preset = ReplayPreset(rawValue: policy) else {
                throw ValidationError("Unknown --policy \(policy). Valid: \(ReplayPreset.allCases.map { $0.rawValue }.joined(separator: ", ")).")
            }

            let db = SessionDatabase.shared
            let sessionId = try resolvedSessionId(db: db)
            let project = sessionProjectRoot(db: db, sessionId: sessionId)
            let since = sessionStartedAt(db: db, sessionId: sessionId)
            let rows = db.agentTraceRowsInWindow(project: project, since: since)

            let report = CounterfactualReplay.evaluate(
                sessionId: sessionId,
                rows: rows,
                preset: preset,
                budgetCapCents: budgetCents
            )

            if let path = json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(report)
                try data.write(to: URL(fileURLWithPath: path))
                FileHandle.standardError.write(Data("Report written to \(path)\n".utf8))
            } else {
                print(renderText(report))
            }
        }

        private func resolvedSessionId(db: SessionDatabase) throws -> String {
            if let session { return session }
            let recent = db.loadSessions(limit: 1)
            guard let latest = recent.first else {
                throw ValidationError("No sessions in DB. Run an MCP session first or pass --session.")
            }
            return latest.id
        }

        private func sessionProjectRoot(db: SessionDatabase, sessionId: String) -> String? {
            // The current SessionSummaryRow shape doesn't surface project
            // root; fall back to nil (= replay across all projects in the
            // window). A future round can plumb project_root through.
            return nil
        }

        private func sessionStartedAt(db: SessionDatabase, sessionId: String) -> Date? {
            let recent = db.loadSessions(limit: 100)
            return recent.first(where: { $0.id == sessionId })?.timestamp
        }

        private func renderText(_ r: ReplayReport) -> String {
            let savedTokens = r.savedTokens
            let savedPct = r.savedTokensPercent
            let savedDollars = Double(r.savedCostCents) / 100.0
            let baseDollars = Double(r.baseline.totalCostCents) / 100.0
            let cfDollars = Double(r.counterfactual.totalCostCents) / 100.0

            var out = ""
            out += "Replay: \(r.preset.rawValue)\n"
            out += "Session: \(r.sessionId)\n"
            out += "\n"
            out += String(format: "Tokens: %d → %d  (-%.1f%%)\n",
                          r.baseline.totalTokens,
                          r.counterfactual.totalTokens,
                          savedPct)
            out += String(format: "Cost:   $%.2f → $%.2f  (-$%.2f)\n",
                          baseDollars, cfDollars, savedDollars)
            out += "Rows:   \(r.baseline.rowCount) total, \(r.affectedRowCount) affected\n"
            out += "\n"
            out += "Confidence: \(r.confidence.rawValue)\n"
            if !r.notes.isEmpty {
                out += "\nNotes:\n"
                for note in r.notes {
                    out += "  - \(note)\n"
                }
            }
            _ = savedTokens
            return out
        }
    }
}
