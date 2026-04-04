import Foundation
import MCP
import Core

/// Runs local validators from the registry. Config-driven, auto-detected.
enum ValidateTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let filePath = arguments?["file"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'file' is required", annotations: nil, _meta: nil)], isError: true)
        }

        let absPath = filePath.hasPrefix("/") ? filePath : session.projectRoot + "/" + filePath
        guard FileManager.default.fileExists(atPath: absPath) else {
            return .init(content: [.text(text: "Error: file not found: \(filePath)", annotations: nil, _meta: nil)], isError: true)
        }

        let ext = (absPath as NSString).pathExtension.lowercased()
        let categoryFilter = arguments?["category"]?.stringValue  // optional: "syntax", "type", "lint", "security", "format"

        // Get validators for this file type
        var validators = session.validatorRegistry.validatorsFor(extension: ext)
        if let cat = categoryFilter {
            validators = validators.filter { $0.category == cat }
        }

        guard !validators.isEmpty else {
            let available = session.validatorRegistry.availableByLanguage()
            let langs = available.keys.sorted().joined(separator: ", ")
            return .init(content: [.text(text: "No validators for .\(ext). Available languages: \(langs)\nRun senkani_session(action: 'validators') to see all.", annotations: nil, _meta: nil)])
        }

        // Run each validator
        var results: [String] = []
        var anyErrors = false

        for v in validators {
            let (output, exitCode) = runValidator(v, file: absPath, projectRoot: session.projectRoot)
            let status = exitCode == 0 ? "✓" : "✗"
            if exitCode != 0 { anyErrors = true }

            results.append("[\(v.category)] \(v.name): \(status)")
            if exitCode != 0 && !output.isEmpty {
                // Indent error output
                let indented = output.components(separatedBy: "\n")
                    .prefix(15)
                    .map { "  \($0)" }
                    .joined(separator: "\n")
                results.append(indented)
                if output.components(separatedBy: "\n").count > 15 {
                    results.append("  ... (\(output.components(separatedBy: "\n").count - 15) more lines)")
                }
            }
        }

        session.recordMetrics(
            rawBytes: results.joined().utf8.count + 200,
            compressedBytes: results.joined().utf8.count,
            feature: "validate",
            command: filePath,
            outputPreview: String(results.joined(separator: "\n").prefix(200))
        )

        let header = "// senkani_validate: \(validators.count) validator(s) for .\(ext)\n"
        return .init(
            content: [.text(text: header + results.joined(separator: "\n"), annotations: nil, _meta: nil)],
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
