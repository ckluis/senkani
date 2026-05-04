import ArgumentParser
import Core
import Foundation

/// `senkani policy show` — surface the captured policy snapshot for a
/// session as JSON, or report which sessions have snapshots when
/// invoked with `--list`.
///
/// Read-only. Never mutates DB state. See `spec/architecture.md` →
/// "Policy Snapshots".
struct Policy: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "policy",
        abstract: "Inspect captured policy snapshots.",
        subcommands: [Show.self]
    )

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show the policy snapshot for a session as JSON."
        )

        @Option(name: .long, help: "Session id. Omit to use the most recent session.")
        var session: String?

        @Flag(name: .long, help: "Emit only the JSON body — no header line.")
        var raw = false

        func run() throws {
            let sessionId = try resolvedSessionId()
            guard let row = SessionDatabase.shared.latestPolicySnapshot(sessionId: sessionId) else {
                throw ValidationError("No policy snapshot found for session \(sessionId).")
            }

            if !raw {
                let when = ISO8601DateFormatter().string(from: row.capturedAt)
                FileHandle.standardError.write(Data("Session: \(sessionId)\nCaptured: \(when)\nHash: \(row.policyHash)\n---\n".utf8))
            }
            print(row.policyJSON)
        }

        private func resolvedSessionId() throws -> String {
            if let session { return session }
            let recent = SessionDatabase.shared.loadSessions(limit: 1)
            guard let latest = recent.first else {
                throw ValidationError("No sessions in DB. Run an MCP session first or pass --session.")
            }
            return latest.id
        }
    }
}
