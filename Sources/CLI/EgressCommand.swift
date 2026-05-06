import ArgumentParser
import Core
import Foundation

/// Operator-facing surface for the EgressProxy daemon (Phase T.1).
///
/// T.1a ships the deterministic rule + decision audit core (no live
/// listener); `status` reports against the audit log + port file, and
/// `start`/`stop` print a clear pointer to the follow-up T.1a.2 round
/// that wires the actual TCP socket. Once T.1a.2 lands, `start` will
/// daemonize the listener, write `~/.senkani/egress.port`, and pipe
/// HTTP_PROXY traffic; `stop` will read the pid file and signal it.
struct Egress: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "egress",
        abstract: "Inspect / control the EgressProxy daemon (Phase T.1).",
        subcommands: [Status.self, Start.self, Stop.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show whether the EgressProxy is listening and how many decisions have been logged."
        )

        @Option(name: .long, help: "Show the N most recent decisions.")
        var recent: Int = 0

        func run() throws {
            let portPath = EgressPaths.portFile
            let db = SessionDatabase.shared
            let count = db.egressDecisionCount()

            if let port = EgressPaths.readPort(portPath: portPath) {
                print("egress proxy: running on :\(port) (decisions: \(count))")
            } else {
                print("egress proxy: down (decisions: \(count))")
            }

            if recent > 0 {
                let rows = db.recentEgressDecisions(limit: recent)
                if rows.isEmpty {
                    print("(no decisions logged)")
                } else {
                    print("recent decisions:")
                    for row in rows {
                        let ts = ISO8601DateFormatter().string(from: row.timestamp)
                        print("  \(ts) \(row.decision.rawValue) \(row.method) \(row.host) rule=\(row.ruleId) lat=\(row.latencyUs)us")
                    }
                }
            }
        }
    }

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start the EgressProxy listener (T.1a.2 follow-up; not yet wired)."
        )

        func run() throws {
            FileHandle.standardError.write(Data("""
                egress: live listener is not yet wired in T.1a — see
                  spec/autonomous/backlog/phase-t1a2-egress-proxy-listener-and-pipe.md
                T.1a ships the deterministic rule + decision + chain core;
                T.1a.2 will daemonize the TCP listener and pipe traffic.

                """.utf8))
            throw ExitCode(2)
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop the EgressProxy listener (T.1a.2 follow-up; not yet wired)."
        )

        func run() throws {
            FileHandle.standardError.write(Data("""
                egress: live listener is not yet wired in T.1a — see
                  spec/autonomous/backlog/phase-t1a2-egress-proxy-listener-and-pipe.md

                """.utf8))
            throw ExitCode(2)
        }
    }
}

/// File-system locations used by the EgressProxy daemon. Defined in CLI
/// (not Core) because Core's job is rule + decision evaluation, not
/// process lifecycle.
enum EgressPaths {
    static var portFile: String {
        NSHomeDirectory() + "/.senkani/egress.port"
    }

    /// Read a port number from the port file, or nil if the file is
    /// missing / empty / non-integer / out of range. Caller treats nil
    /// as "listener is down" and acts accordingly.
    static func readPort(portPath: String) -> Int? {
        guard let raw = try? String(contentsOfFile: portPath, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), port > 0, port < 65536 else { return nil }
        return port
    }
}
