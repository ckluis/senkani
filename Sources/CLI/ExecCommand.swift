import ArgumentParser
import Foundation
import Core
import Filter

struct Exec: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command through the filter pipeline."
    )

    @Flag(name: .long, help: "Measure savings without actually filtering output.")
    var statsOnly = false

    @Flag(name: .long, help: "Disable output filtering.")
    var noFilter = false

    @Flag(name: .long, help: "Disable secret detection.")
    var noSecrets = false

    @Flag(name: .long, help: "Disable symbol indexer integration.")
    var noIndexer = false

    @Argument(parsing: .captureForPassthrough, help: "The command and arguments to run.")
    var command: [String] = []

    func run() throws {
        guard !command.isEmpty else {
            throw ValidationError("No command specified. Usage: senkani exec -- git status")
        }

        let mode = ProcessInfo.processInfo.environment["SENKANI_MODE"] ?? "filter"
        let metricsPath = ProcessInfo.processInfo.environment["SENKANI_METRICS_FILE"]
        let isStatsOnly = statsOnly || mode == "stats"
        let isPassthrough = mode == "passthrough"

        // Resolve feature config: CLI flags override env vars override config file
        let config = FeatureConfig.resolve(
            filterFlag: noFilter ? false : nil,
            secretsFlag: noSecrets ? false : nil,
            indexerFlag: noIndexer ? false : nil
        )

        // Run the actual command
        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardOutput = pipe
        process.standardError = errPipe
        process.environment = ProcessInfo.processInfo.environment

        try process.run()

        // Read BEFORE waitUntilExit to avoid pipe buffer deadlock on large output
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let rawOutput = String(data: outputData, encoding: .utf8) ?? ""

        // Strip leading "--" that ArgumentParser captures
        let cleanCommand = command.first == "--" ? Array(command.dropFirst()) : command
        let commandStr = cleanCommand.joined(separator: " ")

        if isPassthrough {
            FileHandle.standardOutput.write(outputData)
            FileHandle.standardError.write(stderrData)
        } else {
            let pipeline = FilterPipeline(config: config)
            let result = pipeline.process(command: commandStr, output: rawOutput)

            if isStatsOnly {
                FileHandle.standardOutput.write(outputData)
            } else {
                if let filteredData = result.output.data(using: .utf8) {
                    FileHandle.standardOutput.write(filteredData)
                }
            }

            FileHandle.standardError.write(stderrData)

            if let metricsPath = metricsPath {
                let metrics = SessionMetrics(mode: mode, metricsPath: metricsPath)
                metrics.record(result)
            }

            for secret in result.secretsFound {
                FileHandle.standardError.write(
                    "senkani: \(secret) pattern detected and filtered\n".data(using: .utf8) ?? Data()
                )
            }
        }

        throw ExitCode(process.terminationStatus)
    }
}
