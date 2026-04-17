import ArgumentParser
import Foundation
import Core
import Filter

struct Compare: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Run a command across all feature permutations and compare token savings."
    )

    @Argument(parsing: .captureForPassthrough, help: "The command to compare.")
    var command: [String] = []

    func run() throws {
        let cleanCommand = command.first == "--" ? Array(command.dropFirst()) : command
        guard !cleanCommand.isEmpty else {
            throw ValidationError("No command specified. Usage: senkani compare -- git status")
        }

        let commandStr = cleanCommand.joined(separator: " ")

        // Run the actual command once and capture raw output
        let rawOutput = try runCommand(cleanCommand)
        let rawBytes = rawOutput.utf8.count

        guard rawBytes > 0 else {
            print("Command produced no output. Nothing to compare.")
            return
        }

        // Define permutations
        struct Permutation {
            let name: String
            let filter: Bool
            let secrets: Bool
        }

        let permutations: [Permutation] = [
            Permutation(name: "passthrough", filter: false, secrets: false),
            Permutation(name: "filter only", filter: true, secrets: false),
            Permutation(name: "secrets only", filter: false, secrets: true),
            Permutation(name: "all features", filter: true, secrets: true),
        ]

        // Run each permutation
        struct Result {
            let name: String
            let filteredBytes: Int
            let savedPct: Double
            let secretsFound: Int
        }

        var results: [Result] = []

        for perm in permutations {
            let config = FeatureConfig(filter: perm.filter, secrets: perm.secrets, indexer: false)
            let pipeline = FilterPipeline(config: config)
            let pipeResult = pipeline.process(command: commandStr, output: rawOutput)

            let filteredBytes = pipeResult.filteredBytes
            let savedPct = rawBytes > 0 ? Double(rawBytes - filteredBytes) / Double(rawBytes) * 100 : 0

            results.append(Result(
                name: perm.name,
                filteredBytes: filteredBytes,
                savedPct: savedPct,
                secretsFound: pipeResult.secretsFound.count
            ))
        }

        // Print the comparison table
        let maxBar = 20
        let maxSaved = results.map(\.savedPct).max() ?? 1

        print("")
        print("┌──────────────────────────────────────────────────────────────────┐")
        print("│  senkani compare: \(commandStr.prefix(46).padding(toLength: 46, withPad: " ", startingAt: 0)) │")
        print("├──────────────┬──────────┬──────────┬─────────┬──────────────────────┤")
        print("│ Mode         │ Raw      │ Filtered │ Saved   │ Savings              │")
        print("├──────────────┼──────────┼──────────┼─────────┼──────────────────────┤")

        for r in results {
            let name = r.name.padding(toLength: 12, withPad: " ", startingAt: 0)
            let raw = formatBytes(rawBytes).padding(toLength: 8, withPad: " ", startingAt: 0)
            let filtered = formatBytes(r.filteredBytes).padding(toLength: 8, withPad: " ", startingAt: 0)
            let pct = String(format: "%4.0f%%", r.savedPct).padding(toLength: 7, withPad: " ", startingAt: 0)

            let barLen = maxSaved > 0 ? Int(r.savedPct / maxSaved * Double(maxBar)) : 0
            let bar = String(repeating: "█", count: barLen).padding(toLength: maxBar, withPad: " ", startingAt: 0)

            print("│ \(name) │ \(raw) │ \(filtered) │ \(pct) │ \(bar) │")
        }

        print("└──────────────┴──────────┴──────────┴─────────┴──────────────────────┘")

        // Summary
        let best = results.max(by: { $0.savedPct < $1.savedPct })!
        let savedBytes = rawBytes - results.last!.filteredBytes  // "all features"
        let estTokens = savedBytes / 4

        print("")
        print("  Raw output: \(formatBytes(rawBytes))")
        print("  Best mode:  \(best.name) (\(String(format: "%.0f", best.savedPct))% reduction)")
        print("  Est. tokens saved per call: ~\(estTokens)")

        if results.last!.secretsFound > 0 {
            print("  Secrets detected: \(results.last!.secretsFound)")
        }

        // Show what was filtered (first 5 lines of diff)
        let allConfig = FeatureConfig(filter: true, secrets: true, indexer: false)
        let allPipeline = FilterPipeline(config: allConfig)
        let allResult = allPipeline.process(command: commandStr, output: rawOutput)

        let rawLines = rawOutput.components(separatedBy: "\n")
        let filteredLines = allResult.output.components(separatedBy: "\n")

        if rawLines.count != filteredLines.count {
            print("")
            print("  Lines: \(rawLines.count) raw → \(filteredLines.count) filtered (\(rawLines.count - filteredLines.count) removed)")
        }

        print("")
    }

    private func runCommand(_ args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = Pipe()  // discard stderr
        process.environment = ProcessInfo.processInfo.environment

        try process.run()

        // Read data BEFORE waitUntilExit to avoid pipe buffer deadlock.
        // If the process writes >64KB, waitUntilExit blocks because the pipe
        // is full, and we never drain it. Reading first prevents this.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }
}
