import Foundation

/// Result returned by `PlaywrightSubprocessRunner.run`. Mirrors the JSON
/// shape the TS driver under `Resources/playwright-runner/runner.ts`
/// writes to stdout. `screenshotPath` is set when the runner captured a
/// PNG (per-step or final); `advisory` carries human-readable
/// remediation text from the per-axis assertion libraries (wired in
/// U.2a-2).
public struct PlaywrightResult: Codable, Sendable, Equatable {
    public let resultStatus: String
    public let axesRun: [String]
    public let assertionsPassed: Int
    public let assertionsFailed: Int
    public let screenshotPath: String?
    public let advisory: String?

    public init(
        resultStatus: String,
        axesRun: [String],
        assertionsPassed: Int,
        assertionsFailed: Int,
        screenshotPath: String? = nil,
        advisory: String? = nil
    ) {
        self.resultStatus = resultStatus
        self.axesRun = axesRun
        self.assertionsPassed = assertionsPassed
        self.assertionsFailed = assertionsFailed
        self.screenshotPath = screenshotPath
        self.advisory = advisory
    }

    enum CodingKeys: String, CodingKey {
        case resultStatus = "result_status"
        case axesRun = "axes_run"
        case assertionsPassed = "assertions_passed"
        case assertionsFailed = "assertions_failed"
        case screenshotPath = "screenshot_path"
        case advisory
    }
}

/// Errors raised by `PlaywrightSubprocessRunner.run`. The `validation
/// _browser_missing` code is the structured refusal the senkani CLI +
/// MCP tool surface to operators when Chromium isn't installed — the
/// `install_hint` is the operator-runnable command pointed at by
/// `senkani doctor --install-validation-browser`.
public enum PlaywrightRunnerError: Error, Equatable {
    case validationBrowserMissing(installHint: String)
    case subprocessFailed(exitCode: Int32, stderr: String)
    case decodingFailed(String)
}

extension PlaywrightRunnerError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .validationBrowserMissing(let hint):
            return "validation_browser_missing — \(hint)"
        case .subprocessFailed(let code, let stderr):
            return "subprocess failed (exit \(code)): \(stderr)"
        case .decodingFailed(let detail):
            return "decoding failed: \(detail)"
        }
    }
}

/// Spawns the TS driver under `Resources/playwright-runner/runner.ts`
/// as a `node` subprocess. The driver reads `{plan, target_url}` from
/// stdin (one JSON object), writes a `PlaywrightResult` JSON object to
/// stdout, and exits 0 on success / non-zero on plan parse error.
///
/// Refuses to spawn when the Playwright Chromium cache is absent —
/// `~/Library/Caches/ms-playwright/chromium-*` is the install marker
/// `npx playwright install chromium` writes. The refusal is structured
/// (`PlaywrightRunnerError.validationBrowserMissing`) so CLI + MCP
/// surfaces can translate it into the install-hint string without
/// stringly parsing exception messages.
///
/// U.2a-1 ships the contract + refusal-path + JSON framing scaffold.
/// U.2a-2 layers the per-axis assertion libraries (perf.swift +
/// completeness.swift) the TS driver dispatches to, and the MCP tool
/// + CLI subcommand that drive this runner.
public final class PlaywrightSubprocessRunner: @unchecked Sendable {
    /// Absolute path to the Playwright Chromium cache the install
    /// detector probes. Resolves `~` against the current user's home.
    public static var defaultChromiumCachePath: String {
        let home = NSString(string: "~/Library/Caches/ms-playwright").expandingTildeInPath
        return home
    }

    /// Absolute path to `Resources/playwright-runner/runner.ts` shipped
    /// alongside the senkani repo. Defaults to a path relative to the
    /// repo root; callers can override for tests.
    public static var defaultRunnerPath: String {
        // Walk up from CWD looking for a Resources/playwright-runner/
        // sibling. The senkani repo always has one at root; install
        // bundles ship it under the embedded resources tree (resolved
        // by U.2a-2's bundle-aware lookup).
        return "\(FileManager.default.currentDirectoryPath)/Resources/playwright-runner/runner.ts"
    }

    private let chromiumCachePath: String
    private let runnerPath: String
    private let nodePath: String

    public init(
        chromiumCachePath: String = PlaywrightSubprocessRunner.defaultChromiumCachePath,
        runnerPath: String = PlaywrightSubprocessRunner.defaultRunnerPath,
        nodePath: String = "/usr/bin/env"
    ) {
        self.chromiumCachePath = chromiumCachePath
        self.runnerPath = runnerPath
        self.nodePath = nodePath
    }

    /// True when the Playwright Chromium cache directory exists. The
    /// directory has `chromium-<version>/` subdirectories after
    /// `npx playwright install chromium` runs; we only check the
    /// parent's existence (sufficient for refusal-path detection).
    public func chromiumCacheInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: chromiumCachePath)
    }

    /// Run the plan against `targetUrl`. Refuses with
    /// `validationBrowserMissing` when Chromium cache is absent — the
    /// CLI/MCP layer translates this into the install-hint advisory.
    ///
    /// U.2a-1 ships the refusal path + JSON framing scaffold. The
    /// subprocess spawn itself is wired here for U.2a-2 to test
    /// against; production callers route through it once the per-axis
    /// assertion libraries are in place.
    public func run(plan: [ValidationStep], targetUrl: String) throws -> PlaywrightResult {
        guard chromiumCacheInstalled() else {
            throw PlaywrightRunnerError.validationBrowserMissing(
                installHint: "senkani doctor --install-validation-browser"
            )
        }

        let requestJSON = try Self.encodeRequest(plan: plan, targetUrl: targetUrl)
        return try spawnAndDecode(requestJSON: requestJSON)
    }

    /// Encode the `{plan, target_url}` request the TS driver reads from
    /// stdin. Pure; testable without spawning anything.
    public static func encodeRequest(plan: [ValidationStep], targetUrl: String) throws -> Data {
        struct Request: Encodable {
            let plan: [ValidationStep]
            let targetUrl: String
            enum CodingKeys: String, CodingKey {
                case plan
                case targetUrl = "target_url"
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Request(plan: plan, targetUrl: targetUrl))
    }

    private func spawnAndDecode(requestJSON: Data) throws -> PlaywrightResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = ["node", runnerPath]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw PlaywrightRunnerError.subprocessFailed(
                exitCode: -1, stderr: "spawn failed: \(error)")
        }

        stdinPipe.fileHandleForWriting.write(requestJSON)
        try? stdinPipe.fileHandleForWriting.close()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw PlaywrightRunnerError.subprocessFailed(
                exitCode: process.terminationStatus, stderr: stderr)
        }

        do {
            return try JSONDecoder().decode(PlaywrightResult.self, from: stdoutData)
        } catch {
            throw PlaywrightRunnerError.decodingFailed("\(error)")
        }
    }
}
