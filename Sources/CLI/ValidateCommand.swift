import ArgumentParser
import Foundation
import Core

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a source file using local compilers/linters."
    )

    @Argument(help: "File to validate.")
    var file: String

    @Option(name: .long, help: "Filter by category: syntax, type, lint, security, format.")
    var category: String?

    @Flag(name: .long, help: "List all available validators and exit.")
    var list = false

    @Option(name: .long, help: "Project root directory.")
    var root: String?

    func run() throws {
        let projectRoot = root ?? FileManager.default.currentDirectoryPath
        let registry = ValidatorRegistry.load(projectRoot: projectRoot)

        if list {
            print(registry.summaryString())
            return
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
