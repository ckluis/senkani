import ArgumentParser
import Core
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Operator-facing surface for the EgressProxy daemon (Phase T.1).
///
/// T.1a shipped the deterministic rule + decision audit core. T.1a.2
/// wires the live TCP listener: `start` daemonizes (foreground for
/// the simple case, the operator wraps with launchd if they want
/// background), writes the bound port to `~/.senkani/egress.port`,
/// and pipes HTTP_PROXY traffic through the rule engine; `stop`
/// reads `~/.senkani/egress.pid` and sends SIGTERM.
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
            abstract: "Start the EgressProxy listener in the foreground."
        )

        @Option(name: .long, help: "Bind to this port (0 = kernel-assigned).")
        var port: Int = 0

        func run() throws {
            // Refuse to start if a port file already exists and the listed
            // pid is still alive — otherwise we clobber the running
            // daemon's port file.
            if EgressPaths.readPort(portPath: EgressPaths.portFile) != nil,
               let existingPid = EgressPaths.readPid(),
               kill(existingPid, 0) == 0 {
                FileHandle.standardError.write(
                    Data("egress: already running (pid \(existingPid)). Run `senkani egress stop` first.\n".utf8))
                throw ExitCode(1)
            }

            // Default policy: deny everything. Operators add allow rules
            // by editing `~/.senkani/egress-rules.json` (T.1c surface);
            // until that lands, a deny-by-default daemon is intentional.
            let rules = EgressRulesLoader.load()
            let listener = EgressListener(
                rules: rules,
                database: SessionDatabase.shared,
                config: .init(port: port)
            )
            do {
                try listener.start()
            } catch {
                FileHandle.standardError.write(Data("egress: start failed: \(error)\n".utf8))
                throw ExitCode(1)
            }

            EgressPaths.writePid(getpid())

            print("egress: listening on :\(listener.port)")

            // Install SIGTERM/SIGINT handlers — clean shutdown unlinks
            // both the port file and the pid file.
            let terminate: @Sendable () -> Void = {
                listener.stop()
                EgressPaths.unlinkPid()
                Foundation.exit(0)
            }
            installSignal(SIGTERM, handler: terminate)
            installSignal(SIGINT, handler: terminate)

            dispatchMain()
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop a running EgressProxy listener (reads pid file, sends SIGTERM)."
        )

        func run() throws {
            guard let pid = EgressPaths.readPid() else {
                FileHandle.standardError.write(Data("egress: not running (no pid file)\n".utf8))
                throw ExitCode(1)
            }
            if kill(pid, SIGTERM) != 0 {
                FileHandle.standardError.write(
                    Data("egress: kill(\(pid), SIGTERM) failed: \(String(cString: strerror(errno)))\n".utf8))
                throw ExitCode(1)
            }
            print("egress: SIGTERM sent to pid \(pid)")
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

    static var pidFile: String {
        NSHomeDirectory() + "/.senkani/egress.pid"
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

    static func readPid() -> Int32? {
        guard let raw = try? String(contentsOfFile: pidFile, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 0 else { return nil }
        return pid
    }

    static func writePid(_ pid: Int32) {
        let dir = (pidFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "\(pid)\n".write(toFile: pidFile, atomically: true, encoding: .utf8)
    }

    static func unlinkPid() {
        unlink(pidFile)
    }
}

/// Loads operator-supplied rules from `~/.senkani/egress-rules.json`.
/// File format: `[{"id": "...", "pattern": "...", "mode": "exact|prefix|suffix|glob", "decision": "allow|deny"}, ...]`.
/// Missing file → empty rule set → deny-by-default for every host.
enum EgressRulesLoader {
    private struct WireRule: Decodable {
        let id: String
        let pattern: String
        let mode: String
        let decision: String
    }

    static var rulesPath: String {
        NSHomeDirectory() + "/.senkani/egress-rules.json"
    }

    static func load() -> EgressRuleEngine {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: rulesPath)),
              let wire = try? JSONDecoder().decode([WireRule].self, from: data) else {
            return EgressRuleEngine(rules: [])
        }
        let parsed: [EgressRule] = wire.compactMap { w in
            guard let mode = EgressRule.Mode(rawValue: w.mode),
                  let decision = EgressRule.Decision(rawValue: w.decision) else {
                return nil
            }
            return EgressRule(id: w.id, pattern: w.pattern, mode: mode, decision: decision)
        }
        return EgressRuleEngine(rules: parsed)
    }
}

private func installSignal(_ sig: Int32, handler: @escaping @Sendable () -> Void) {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
    src.setEventHandler { handler() }
    src.resume()
    // Disable default disposition so the signal source receives the
    // event instead of the default action terminating the process.
    signal(sig, SIG_IGN)
    // Keep a strong reference for the lifetime of the process — losing
    // the source would cancel it.
    EgressSignalSourceRetainer.shared.retain(src)
}

private final class EgressSignalSourceRetainer: @unchecked Sendable {
    static let shared = EgressSignalSourceRetainer()
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    func retain(_ src: DispatchSourceSignal) {
        lock.lock(); defer { lock.unlock() }
        sources.append(src)
    }
}
