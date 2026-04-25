import Foundation
import MCP
import Core

/// Runs local validators from the registry. Config-driven, auto-detected.
enum ValidateTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let filePath = arguments?["file"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'file' is required", annotations: nil, _meta: nil)], isError: true)
        }

        let absPath: String
        do {
            absPath = try ProjectSecurity.resolveProjectFile(filePath, projectRoot: session.projectRoot)
        } catch {
            return .init(
                content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        guard FileManager.default.fileExists(atPath: absPath) else {
            return .init(content: [.text(text: "Error: file not found: \(filePath)", annotations: nil, _meta: nil)], isError: true)
        }

        let ext = (absPath as NSString).pathExtension.lowercased()
        let categoryFilter = arguments?["category"]?.stringValue
        // P2-10: canonical `full: bool` read. Any legacy `detail:"full"` was translated
        // upstream by ArgumentShim.normalize in ToolRouter before this handler ran.
        let full = arguments?["full"]?.boolValue ?? false

        var validators = session.validatorRegistry.validatorsFor(extension: ext)
        if let cat = categoryFilter {
            validators = validators.filter { $0.category == cat }
        }

        guard !validators.isEmpty else {
            let available = session.validatorRegistry.availableByLanguage()
            let langs = available.keys.sorted().joined(separator: ", ")
            return .init(content: [.text(text: "No validators for .\(ext). Available languages: \(langs)\nRun senkani_session(action: 'validators') to see all.", annotations: nil, _meta: nil)])
        }

        // Run each validator and collect results
        struct ValidatorResult {
            let validator: ValidatorDef
            let output: String
            let exitCode: Int32
            var passed: Bool { exitCode == 0 }
        }
        var validatorResults: [ValidatorResult] = []
        for v in validators {
            let (output, exitCode) = runValidator(v, file: absPath, projectRoot: session.projectRoot)
            validatorResults.append(ValidatorResult(validator: v, output: output, exitCode: exitCode))
        }

        let passCount = validatorResults.filter(\.passed).count
        let failCount = validatorResults.count - passCount
        let anyErrors = failCount > 0

        var lines: [String] = []
        let header = "// senkani_validate: \(validators.count) validator\(validators.count == 1 ? "" : "s") · \(passCount) passed · \(failCount) failed"
        lines.append(header)
        lines.append("")

        if full {
            // Full mode: show all validators with complete output (original behaviour)
            for r in validatorResults {
                let status = r.passed ? "✓" : "✗"
                lines.append("[\(r.validator.category)] \(r.validator.name): \(status)")
                if !r.passed && !r.output.isEmpty {
                    let outputLines = r.output.components(separatedBy: "\n")
                    let indented = outputLines.prefix(15).map { "  \($0)" }.joined(separator: "\n")
                    lines.append(indented)
                    if outputLines.count > 15 {
                        lines.append("  ... (\(outputLines.count - 15) more lines)")
                    }
                }
            }
        } else {
            // Summary mode (default): failing validators with first 5 lines, then passing as one-liner
            for r in validatorResults where !r.passed {
                let outputLines = r.output.components(separatedBy: "\n").filter { !$0.isEmpty }
                let errorCount = outputLines.filter { $0.contains("error:") }.count
                let warnCount  = outputLines.filter { $0.contains("warning:") }.count
                var badge = ""
                if errorCount > 0 || warnCount > 0 {
                    var parts: [String] = []
                    if errorCount > 0 { parts.append("\(errorCount) error\(errorCount == 1 ? "" : "s")") }
                    if warnCount  > 0 { parts.append("\(warnCount) warning\(warnCount == 1 ? "" : "s")") }
                    badge = " — " + parts.joined(separator: ", ")
                } else if !outputLines.isEmpty {
                    badge = " — \(outputLines.count) line\(outputLines.count == 1 ? "" : "s")"
                }
                lines.append("✗ [\(r.validator.category)] \(r.validator.name)\(badge)")
                let shown = outputLines.prefix(5)
                for line in shown { lines.append("  \(line)") }
                if outputLines.count > 5 {
                    lines.append("  ... (\(outputLines.count - 5) more lines)")
                }
            }
            if passCount > 0 {
                let names = validatorResults.filter(\.passed)
                    .map { "\($0.validator.name) (\($0.validator.category))" }
                    .joined(separator: ", ")
                lines.append("")
                lines.append("✓ \(passCount) passed: \(names)")
            }
            if anyErrors {
                lines.append("")
                lines.append("Use validate(file:'\(filePath)', full:true) for complete error output.")
            }
        }

        let output = lines.joined(separator: "\n")
        let rawBytes = validatorResults.map(\.output).joined().utf8.count + 200

        session.recordMetrics(
            rawBytes: rawBytes,
            compressedBytes: output.utf8.count,
            feature: "validate",
            command: filePath,
            outputPreview: String(output.prefix(200))
        )

        return .init(
            content: [.text(text: output, annotations: nil, _meta: nil)],
            isError: anyErrors
        )
    }

    /// List all validators and their status.
    static func listAll(session: MCPSession) -> String {
        session.validatorRegistry.summaryString()
    }

    private static func runValidator(_ v: ValidatorDef, file: String, projectRoot: String) -> (output: String, exitCode: Int32) {
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

            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let output = (stderr + stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            return (output, process.terminationStatus)
        } catch {
            return ("Failed to run \(v.command): \(error)", 1)
        }
    }
}
