import ArgumentParser
import Foundation
import Core

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a source file (default) or a live URL across the four ValidationAxes (--browser; U.2a-2b)."
    )

    @Argument(help: "File to validate. Omit when --browser is set; --url supplies the target instead.")
    var file: String?

    @Option(name: .long, help: "Filter by category: syntax, type, lint, security, format. (file mode only)")
    var category: String?

    @Flag(name: .long, help: "List all available validators and exit.")
    var list = false

    @Option(name: .long, help: "Project root directory.")
    var root: String?

    @Flag(name: .long, help: "U.2a-2b — drive Playwright Chromium against --url across the four ValidationAxes (perf, completeness, security, design).")
    var browser = false

    @Option(name: .long, help: "[--browser] URL to validate. HTTP/HTTPS only.")
    var url: String?

    @Option(name: .long, help: "[--browser] Comma-separated axes (default: all four). Values: perf, completeness, security, design.")
    var axes: String?

    @Option(name: .long, help: "[--browser] Diff selector: 'unstaged', 'staged', 'branch:<ref>', or 'range:<a>..<b>'. Empty → one step per axis keyed on --url.")
    var diffTarget: String?

    @Flag(name: .long, help: "[--browser] Override the HookRouter hard-block. Emits a chained validation.fail.allow audit row.")
    var allowFailed = false

    @Flag(name: .long, inversion: .prefixedNo, help: "[--browser] Capture a screenshot via Playwright. Default: --screenshot.")
    var screenshot: Bool = true

    @Option(name: .long, help: "[--browser] Output format. 'json' produces byte-identical output to the senkani_validate_browser MCP response.")
    var format: String?

    func run() throws {
        let projectRoot = root ?? FileManager.default.currentDirectoryPath
        if browser {
            try runBrowser(projectRoot: projectRoot)
            return
        }
        try runFile(projectRoot: projectRoot)
    }

    private func runFile(projectRoot: String) throws {
        let registry = ValidatorRegistry.load(projectRoot: projectRoot)

        if list {
            print(registry.summaryString())
            return
        }

        guard let file else {
            print("Error: 'file' argument is required in file mode (omit --browser, or pass --url with --browser).")
            throw ExitCode.failure
        }

        let absPath = file.hasPrefix("/") ? file : projectRoot + "/" + file
        guard FileManager.default.fileExists(atPath: absPath) else {
            print("File not found: \(file)")
            throw ExitCode.failure
        }

        let ext = (absPath as NSString).pathExtension.lowercased()
        var validators = registry.validatorsFor(extension: ext)
        if let cat = category {
            validators = validators.filter { $0.category == cat }
        }

        guard !validators.isEmpty else {
            print("No validators for .\(ext)")
            print("")
            print("Installed validators:")
            print(registry.summaryString())
            throw ExitCode.failure
        }

        var anyErrors = false
        for v in validators {
            let (output, exitCode) = runValidator(v, file: absPath, projectRoot: projectRoot)
            if exitCode == 0 {
                print("✓ [\(v.category)] \(v.name)")
            } else {
                anyErrors = true
                print("✗ [\(v.category)] \(v.name)")
                if !output.isEmpty {
                    for line in output.components(separatedBy: "\n").prefix(15) {
                        print("  \(line)")
                    }
                }
            }
        }

        if anyErrors {
            throw ExitCode.failure
        }
    }

    private func runBrowser(projectRoot: String) throws {
        guard let url, !url.isEmpty else {
            print("Error: --url is required with --browser.")
            throw ExitCode.failure
        }
        let resolvedAxes: [ValidationAxes] = {
            guard let axes else { return ValidationAxes.allCases }
            let names = axes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let parsed = names.compactMap { ValidationAxes(rawValue: $0) }
            return parsed.isEmpty ? ValidationAxes.allCases : parsed
        }()
        let diff: DiffRequest? = {
            guard let diffTarget, !diffTarget.isEmpty,
                  let selector = DiffSelector(rawValue: diffTarget) else { return nil }
            return DiffRequest(selector: selector, perFileDiff: [:])
        }()

        let sessionId = ProcessInfo.processInfo.environment["SENKANI_SESSION_ID"] ?? "cli-validate-browser"
        let request = BrowserValidationDispatcher.Request(
            targetURL: url,
            axes: resolvedAxes,
            diff: diff,
            allowFailed: allowFailed,
            screenshot: screenshot,
            sessionId: sessionId,
            projectRoot: projectRoot
        )

        let runner = PlaywrightSubprocessRunner()
        let runnerClosure: BrowserValidationDispatcher.Runner = { plan, target, _ in
            try runner.run(plan: plan, targetUrl: target)
        }
        let db = SessionDatabase.shared
        let resultSink: BrowserValidationDispatcher.ResultSink = { row in
            let planJSON = Self.encodePlanSteps(row.planSteps)
            db.insertBrowserValidationResult(
                sessionId: row.sessionId,
                targetURL: row.targetURL,
                axes: row.axes,
                planStepsJSON: planJSON,
                resultStatus: row.resultStatus,
                assertionsPassed: row.assertionsPassed,
                assertionsFailed: row.assertionsFailed,
                advisory: row.advisory,
                screenshotPath: row.screenshotPath
            )
        }
        let tokenEventSink: BrowserValidationDispatcher.TokenEventSink = { ev in
            db.recordTokenEvent(
                sessionId: ev.sessionId,
                paneId: nil,
                projectRoot: ev.projectRoot,
                source: "cli",
                toolName: "validate_browser",
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                savedTokens: 0,
                costCents: 0,
                feature: ev.feature,
                command: ev.command,
                modelTier: nil,
                connectionId: nil
            )
        }

        let response = try BrowserValidationDispatcher.dispatch(
            request: request,
            runner: runnerClosure,
            resultSink: resultSink,
            tokenEventSink: tokenEventSink
        )

        if format == "json" {
            let data = try BrowserValidationDispatcher.encode(response)
            if let s = String(data: data, encoding: .utf8) { print(s) }
        } else {
            print("result_status: \(response.resultStatus)")
            print("axes_run: \(response.axesRun.joined(separator: ","))")
            print("assertions_passed: \(response.assertionsPassed)")
            print("assertions_failed: \(response.assertionsFailed)")
            if let path = response.screenshotPath { print("screenshot_path: \(path)") }
            print("advisory: \(response.advisory)")
        }

        if response.resultStatus == "fail" && !response.allowFailed {
            throw ExitCode.failure
        }
    }

    private static func encodePlanSteps(_ steps: [ValidationStep]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(steps),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    private func runValidator(_ v: ValidatorDef, file: String, projectRoot: String) -> (String, Int32) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [v.command] + v.args + [file]
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)

        do {
            try process.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = (String(data: errData, encoding: .utf8) ?? "")
                + (String(data: outData, encoding: .utf8) ?? "")
            return (output.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
        } catch {
            return ("Failed to run \(v.command): \(error)", 1)
        }
    }
}
