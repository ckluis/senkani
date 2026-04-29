import Foundation

/// Checks whether a preset's declared prerequisites (companion MCP
/// tools, hook presets, CLI shims, daemons) are ready on the current
/// machine. Results are always **warnings** — missing prerequisites
/// NEVER block `preset install` (Podmajersky gate: operator should be
/// able to install now and wire the companion surfaces later).
///
/// Each prerequisite identifier is matched to a specific probe. Known
/// ids (day-1):
///   - `ollama`                      — TCP reachability on 127.0.0.1:11434
///   - `senkani_search_web`          — ships with this binary (W.1); always ready
///   - `guard-research`              — ships with this binary (W.1) at the
///                                     senkani_search_web tool boundary; always ready
///   - `guard-autoimprove`           — hook preset not yet shipped; always warn
///   - `senkani-brief-cli`           — `senkani brief` CLI; shell-probe
///   - `senkani-improve-cli`         — `senkani improve` CLI; shell-probe
///   - `pushover-notification-sink`  — NotificationSink not yet shipped; always warn
///
/// Unknown ids warn with a generic "prerequisite `<id>` has no probe
/// registered" message so a hand-edited preset's unknown dep doesn't
/// silently pass.
public enum PresetPrerequisiteCheck {

    public struct CheckResult: Sendable, Equatable {
        /// The preset name this result belongs to.
        public let preset: String
        /// Prerequisites that passed.
        public let ready: [String]
        /// Prerequisites that warn (not yet shipped or probe failed).
        public let warnings: [Warning]

        public struct Warning: Sendable, Equatable {
            public let prerequisite: String
            public let message: String
        }

        /// Empty `warnings` means the preset is fully ready.
        public var fullyReady: Bool { warnings.isEmpty }
    }

    // MARK: - Test-only probe override

    /// Test hook: map prerequisite id → predetermined `isReady` value.
    /// When set, bypasses the real probe. `nil` (default) means use
    /// the real probes.
    nonisolated(unsafe) private static var _probeOverride: [String: Bool]?
    private static let testLock = NSLock()

    /// TEST ONLY: run `body` with `probes` substituting real checks so
    /// the suite never touches the network.
    public static func withProbes<T>(
        _ probes: [String: Bool],
        _ body: () throws -> T
    ) rethrows -> T {
        testLock.lock()
        let prior = _probeOverride
        _probeOverride = probes
        defer {
            _probeOverride = prior
            testLock.unlock()
        }
        return try body()
    }

    // MARK: - Public API

    /// Check a preset against its declared `prerequisites` list.
    public static func check(_ preset: ScheduledPreset) -> CheckResult {
        var ready: [String] = []
        var warnings: [CheckResult.Warning] = []
        for prereq in preset.prerequisites {
            if let ok = _probeOverride?[prereq] {
                if ok {
                    ready.append(prereq)
                } else {
                    warnings.append(CheckResult.Warning(
                        prerequisite: prereq,
                        message: testWarningCopy(prereq)
                    ))
                }
                continue
            }

            if let warning = probe(prereq) {
                warnings.append(warning)
            } else {
                ready.append(prereq)
            }
        }
        return CheckResult(preset: preset.name, ready: ready, warnings: warnings)
    }

    /// One-line summary message for use by CLI / pane-sheet. Returns
    /// `nil` when no warnings fired (caller prints nothing in that
    /// case).
    public static func summaryMessage(_ result: CheckResult) -> String? {
        guard !result.warnings.isEmpty else { return nil }
        let missing = result.warnings.map { "`\($0.prerequisite)`" }.joined(separator: ", ")
        return "Install succeeded. `\(result.preset)` needs \(missing) before it can run at full capability; see `senkani doctor` for status."
    }

    // MARK: - Probes

    private static func probe(_ prereq: String) -> CheckResult.Warning? {
        switch prereq {
        case "ollama":
            return probeOllama()
        case "senkani-brief-cli":
            return probeShellCommand("senkani brief --help", prereq: prereq)
        case "senkani-improve-cli":
            return probeShellCommand("senkani improve --help", prereq: prereq)
        case "senkani_search_web",
             "guard-research":
            // Ship with this binary as of W.1: search_web MCP tool +
            // guard-research query filter at the tool boundary. Probe is
            // a no-op here because the binary that runs `senkani doctor`
            // is the same one that registers the tool.
            return nil
        case "guard-autoimprove",
             "pushover-notification-sink":
            return CheckResult.Warning(
                prerequisite: prereq,
                message: "`\(prereq)` is not yet shipped — preset will run in degraded mode until it lands."
            )
        default:
            return CheckResult.Warning(
                prerequisite: prereq,
                message: "Prerequisite `\(prereq)` has no probe registered; treat as unverified."
            )
        }
    }

    private static func testWarningCopy(_ prereq: String) -> String {
        "`\(prereq)` is unavailable (probe returned false)."
    }

    private static func probeOllama() -> CheckResult.Warning? {
        // Small HTTP GET against ollama's `/api/version` with a 300 ms
        // timeout so a wedged daemon doesn't stall `senkani doctor`.
        guard let url = URL(string: "http://127.0.0.1:11434/api/version") else {
            return warning("ollama", "Could not construct ollama probe URL.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.3
        request.httpMethod = "GET"

        final class Flag: @unchecked Sendable {
            var value = false
        }
        let flag = Flag()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                flag.value = true
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 0.5)
        task.cancel()

        if flag.value { return nil }
        return warning("ollama", "Ollama daemon not reachable at 127.0.0.1:11434 — install / start it or remove the prerequisite.")
    }

    private static func probeShellCommand(_ command: String, prereq: String) -> CheckResult.Warning? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "command -v \(command.split(separator: " ").first ?? "") >/dev/null 2>&1"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return nil }
        } catch {
            return warning(prereq, "Could not spawn shell to probe `\(prereq)`.")
        }
        return warning(prereq, "`\(prereq)` is not on PATH — install the shim or skip this preset.")
    }

    private static func warning(_ prereq: String, _ message: String) -> CheckResult.Warning {
        CheckResult.Warning(prerequisite: prereq, message: message)
    }

}
